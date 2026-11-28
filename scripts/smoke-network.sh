#!/usr/bin/env bash
# Teste da rede "logs-read" (executa NO HOST, com o stack de pé): o OpenSearch (sem security plugin) é alcançado por
# "logs-read" e pela rede interna, nunca pela rede "observability" nem por uma porta do host.
# Importância: sem autenticação no OpenSearch, a segmentação de rede é o controle de acesso aos logs neste ambiente.
# Uso: ./scripts/smoke-network.sh     (Git Bash no Windows: MSYS_NO_PATHCONV=1 ./scripts/smoke-network.sh)
set -euo pipefail
failures=0
check() { if [[ "$2" == "true" ]]; then echo "OK   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }

opensearch_container="$(docker compose ps -q opensearch)"
[[ -n "$opensearch_container" ]] || { echo "opensearch is not running (docker compose up -d first)"; exit 1; }
# Reusa a imagem do próprio OpenSearch (já local e com curl) como cliente descartável.
image="$(docker inspect -f '{{.Config.Image}}' "$opensearch_container")"
probe() { docker run --rm --network "$1" --entrypoint curl "$image" -s -o /dev/null -m 5 -w '%{http_code}' "http://opensearch:9200/_cluster/health" || true; }

networks="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$opensearch_container")"
check "OpenSearch participa de logs-read e graylog-internal" \
  "$([[ "$networks" == *logs-read* && "$networks" == *graylog-internal* ]] && echo true || echo false)"
check "OpenSearch NÃO participa da rede observability" "$([[ "$networks" != *observability* ]] && echo true || echo false)"
published="$(docker port "$opensearch_container" 2>/dev/null || true)"
check "OpenSearch não publica porta no host" "$([[ -z "$published" ]] && echo true || echo false)"
check "alias 'opensearch' responde de logs-read (200)" "$([[ "$(probe logs-read)" == "200" ]] && echo true || echo false)"
check "alias 'opensearch' inacessível da rede observability" "$([[ "$(probe observability)" != "200" ]] && echo true || echo false)"

[[ "$failures" -eq 0 ]] || { echo "${failures} verificação(ões) falharam."; exit 1; }
echo "Smoke de rede OK."
