#!/bin/bash
# Tenta criar a VM Always Free (VM.Standard.A1.Flex) ate a Oracle ter capacidade.
# Roda no GitHub Actions (.github/workflows/criar-vm.yml), em rodadas de
# MAX_MINUTOS disparadas de hora em hora.
#
# Configuracao por variaveis de ambiente (ou em ~/criar-vm.env):
#   SUBNET_ID=ocid1.subnet.oc1.sa-saopaulo-1.xxxx   (obrigatorio)
#   NTFY_TOPIC=eduka-vm-<algo-aleatorio>            (opcional: aviso no celular)
#   MAX_MINUTOS=55                                  (opcional: encerra a rodada)
#   OCULTAR_IP=1                                    (opcional: IP so vai pelo ntfy)
#
# Pre-requisitos: OCI CLI configurado (~/.oci/config), chave SSH publica da A1
# em ~/eduka.pub e cloud-init.sh na mesma pasta deste script.

export TZ=America/Sao_Paulo
PASTA="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HOME/criar-vm.env" ] && source "$HOME/criar-vm.env"

NOME="${NOME:-eduka-demo}"
CHAVE_SSH="${CHAVE_SSH:-$HOME/eduka.pub}"
INTERVALO="${INTERVALO:-60}"
DISCO_GB="${DISCO_GB:-100}"
OCI="${OCI:-$HOME/bin/oci}"

# Tamanhos tentados em cada rodada, do maior para o menor (ocpus:memoria).
TAMANHOS="${TAMANHOS:-4:24 2:12 1:6}"

log() { echo "[$(date '+%d/%m %H:%M:%S')] $*"; }

avisar() {
    [ -n "$NTFY_TOPIC" ] && curl -s -d "$1" "https://ntfy.sh/$NTFY_TOPIC" > /dev/null
}

[ -z "$SUBNET_ID" ] && { log "SUBNET_ID nao definido em ~/criar-vm.env"; exit 2; }
[ -f "$CHAVE_SSH" ] || { log "Chave SSH publica nao encontrada em $CHAVE_SSH"; exit 2; }
[ -f "$PASTA/cloud-init.sh" ] || { log "cloud-init.sh nao encontrado em $PASTA"; exit 2; }

# Compartment = tenancy (root), lido do ~/.oci/config.
COMPARTMENT="$(grep -m1 '^tenancy' "$HOME/.oci/config" | cut -d= -f2 | tr -d ' ')"
[ -z "$COMPARTMENT" ] && { log "Nao achei 'tenancy=' em ~/.oci/config"; exit 2; }

AD="$("$OCI" iam availability-domain list --compartment-id "$COMPARTMENT" \
    --query 'data[0].name' --raw-output)"
IMAGEM="$("$OCI" compute image list --compartment-id "$COMPARTMENT" \
    --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
    --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC \
    --query 'data[0].id' --raw-output)"
[ -z "$AD" ] || [ -z "$IMAGEM" ] && { log "Nao consegui obter o AD ou a imagem"; exit 1; }
log "AD: $AD"
log "Imagem: $IMAGEM"

# Nao criar duplicata se uma tentativa anterior ja tiver dado certo.
EXISTENTE="$("$OCI" compute instance list --compartment-id "$COMPARTMENT" --display-name "$NOME" \
    --query "data[?\"lifecycle-state\"!='TERMINATED'] | [0].id" --raw-output 2>/dev/null)"
if [[ "$EXISTENTE" == ocid1.instance* ]]; then
    log "Ja existe uma instancia '$NOME': $EXISTENTE. Nada a fazer."
    exit 0
fi

FIM=$(( $(date +%s) + ${MAX_MINUTOS:-0} * 60 ))

tentativa=0
while true; do
    for t in $TAMANHOS; do
        if [ -n "$MAX_MINUTOS" ] && [ "$(date +%s)" -ge "$FIM" ]; then
            log "Fim da rodada ($MAX_MINUTOS min) sem capacidade. A proxima rodada continua."
            exit 0
        fi
        tentativa=$((tentativa + 1))
        ocpus="${t%%:*}"
        memoria="${t##*:}"

        saida="$("$OCI" compute instance launch \
            --compartment-id "$COMPARTMENT" \
            --availability-domain "$AD" \
            --display-name "$NOME" \
            --shape VM.Standard.A1.Flex \
            --shape-config "{\"ocpus\": $ocpus, \"memoryInGBs\": $memoria}" \
            --image-id "$IMAGEM" \
            --subnet-id "$SUBNET_ID" \
            --assign-public-ip true \
            --boot-volume-size-in-gbs "$DISCO_GB" \
            --ssh-authorized-keys-file "$CHAVE_SSH" \
            --user-data-file "$PASTA/cloud-init.sh" \
            --instance-options '{"areLegacyImdsEndpointsDisabled": true}' \
            --query 'data.id' --raw-output 2>&1)"
        rc=$?

        if [ $rc -eq 0 ]; then
            id="$saida"
            log "Tentativa $tentativa - $ocpus OCPU / $memoria GB: CRIADA! $id"
            "$OCI" compute instance get --instance-id "$id" --wait-for-state RUNNING > /dev/null
            ip="$("$OCI" compute instance list-vnics --instance-id "$id" \
                --query 'data[0]."public-ip"' --raw-output)"
            if [ -n "$OCULTAR_IP" ]; then
                log "IP publico enviado pelo ntfy (oculto no log)."
            else
                log "IP publico: $ip"
            fi
            avisar "VM A1 criada! $ocpus OCPU / $memoria GB, IP $ip"
            exit 0
        fi

        if grep -qiE "out of (host )?capacity" <<< "$saida"; then
            log "Tentativa $tentativa - $ocpus OCPU / $memoria GB: sem capacidade."
        elif grep -qE "TooManyRequests|\b429\b" <<< "$saida"; then
            log "Tentativa $tentativa: limite de requisicoes, esperando 5 min."
            sleep 300
        elif grep -q "LimitExceeded" <<< "$saida"; then
            log "Limite da conta excedido: provavelmente ja existe uma VM A1 usando a cota."
            log "$saida"
            avisar "Script da VM parou: limite da conta excedido. Veja o log."
            exit 2
        else
            # Erro de rede ou instabilidade da API: registra e segue tentando.
            log "Tentativa $tentativa: erro inesperado, tentando de novo:"
            log "$saida"
        fi
        sleep "$INTERVALO"
    done
done
