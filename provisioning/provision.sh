#!/usr/bin/env bash
# Provisionamento idempotente do Graylog pela API REST: inputs GELF, index set com retenção, streams,
# pipeline de enriquecimento (com mascaramento de dados pessoais) e definições de alerta.
# Pode rodar a cada "docker compose up": o que já existe (mesmo título) é mantido; regras de pipeline são atualizadas.
set -euo pipefail

: "${GRAYLOG_URL:?GRAYLOG_URL is required}"
: "${GRAYLOG_ADMIN_USER:?GRAYLOG_ADMIN_USER is required}"
: "${GRAYLOG_ADMIN_PASSWORD:?GRAYLOG_ADMIN_PASSWORD is required}"
RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
DEFAULT_STREAM_ID="000000000000000000000001"
RULES_DIR="/provisioning/rules"

# ---------------------------------------------------------------- utilitários HTTP
api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS --fail-with-body -u "${GRAYLOG_ADMIN_USER}:${GRAYLOG_ADMIN_PASSWORD}"
    -H "X-Requested-By: provisioner" -H "Accept: application/json" -X "$method")
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi
  curl "${args[@]}" "${GRAYLOG_URL}/api${path}"
}

# Mensagens vão para o stderr: o stdout das funções é usado para devolver ids.
log() { echo "[provision] $*" >&2; }

wait_for_graylog() {
  for _ in $(seq 1 60); do
    # lbstatus responde text/plain (não JSON), por isso não usa o helper "api".
    if curl -fsS -u "${GRAYLOG_ADMIN_USER}:${GRAYLOG_ADMIN_PASSWORD}" "${GRAYLOG_URL}/api/system/lbstatus" 2>/dev/null | grep -q ALIVE; then
      return 0
    fi
    sleep 5
  done
  echo "Graylog API did not become available" >&2
  exit 1
}

# ---------------------------------------------------------------- inputs GELF
# Uso: ensure_input "Título" <tipo> [porta, padrão 12201]
ensure_input() {
  local title="$1" type="$2" port="${3:-12201}"
  local id created=false state
  id="$(api GET /system/inputs | jq -r --arg t "$title" '.inputs[] | select(.title == $t) | .id' | head -1)"
  if [[ -z "$id" ]]; then
    created=true
    id="$(api POST /system/inputs "$(jq -nc --arg t "$title" --arg type "$type" --argjson port "$port" '{
      title: $t, type: $type, global: true,
      configuration: { bind_address: "0.0.0.0", port: $port, recv_buffer_size: 1048576,
                       decompress_size_limit: 8388608, max_message_size: 2097152,
                       use_null_delimiter: true, tcp_keepalive: true, number_worker_threads: 4 } }')" | jq -r '.id')"
    log "input created: ${title}"
  fi
  # O Graylog sobe o input de forma assíncrona. Um segundo start no meio do caminho deixa o GELF TCP quebrado (aceita
  # a conexão e descarta a mensagem): espera o estado assentar e só inicia o input que estiver de fato parado.
  for _ in $(seq 1 15); do
    state="$(input_state "$id")"
    [[ "$state" == "RUNNING" ]] && return 0
    [[ "$state" == "STARTING" || ( "$created" == "true" && "$state" == "NONE" ) ]] || break
    sleep 2
  done
  api PUT "/system/inputstates/${id}" >/dev/null
  log "input started: ${title} (state was ${state})"
}

input_state() {
  api GET /system/inputstates | jq -r --arg id "$1" '[.states[] | select(.id == $id) | .state][0] // "NONE"'
}

# ---------------------------------------------------------------- index set
ensure_index_set() {
  local title="$1" prefix="$2" description="$3"
  local id
  id="$(api GET /system/indices/index_sets | jq -r --arg t "$title" '.index_sets[] | select(.title == $t) | .id' | head -1)"
  if [[ -z "$id" ]]; then
    # Parte do index set padrão e ajusta título, prefixo e retenção (rotação diária, apaga após N dias — LGPD).
    local body
    body="$(api GET /system/indices/index_sets | jq -c --arg t "$title" --arg p "$prefix" --arg d "$description" --arg min "P${RETENTION_DAYS}D" \
      --arg max "P$((RETENTION_DAYS + 5))D" '
      .index_sets[] | select(.default == true)
      | del(.id, .default, .can_be_default) | .title = $t | .index_prefix = $p
      | .description = $d
      | .creation_date = (now | todate)
      | .rotation_strategy.index_lifetime_min = $min | .rotation_strategy.index_lifetime_max = $max
      | .data_tiering.index_lifetime_min = $min | .data_tiering.index_lifetime_max = $max')"
    id="$(api POST /system/indices/index_sets "$body" | jq -r '.id')"
    log "index set created: ${title} (retention ${RETENTION_DAYS} days)"
  fi
  echo "$id"
}

# ---------------------------------------------------------------- streams
# Uso: ensure_stream "Título" "Descrição" <index_set_id> <remove_from_default:true|false> '<rules-json-array>'
ensure_stream() {
  local title="$1" description="$2" index_set="$3" remove="$4" rules="$5"
  local id
  id="$(api GET /streams | jq -r --arg t "$title" '.streams[] | select(.title == $t) | .id' | head -1)"
  if [[ -z "$id" ]]; then
    # Graylog 7: criação de entidades compartilháveis vai embrulhada em {"entity": ...}.
    id="$(api POST /streams "$(jq -nc --arg t "$title" --arg d "$description" --arg i "$index_set" \
      --argjson r "$remove" --argjson rules "$rules" '{ entity: {
        title: $t, description: $d, index_set_id: $i, matching_type: "AND",
        remove_matches_from_default_stream: $r, rules: $rules } }')" | jq -r '.stream_id')"
    log "stream created: ${title}"
  else
    sync_stream_rules "$id" "$title" "$rules"
  fi
  if api GET "/streams/${id}" | jq -e '.disabled == true' >/dev/null; then
    api POST "/streams/${id}/resume" >/dev/null
    log "stream resumed: ${title}"
  fi
  echo "$id"
}

# Mantém as regras de um stream existente iguais às do script (sem isso, mudanças aqui nunca chegariam ao Graylog).
sync_stream_rules() {
  local id="$1" title="$2" desired="$3"
  local normalize='map({field, type, value, inverted}) | sort_by(.field, .type, .value, .inverted)'
  local current
  current="$(api GET "/streams/${id}" | jq -c ".rules | ${normalize}")"
  if [[ "$current" == "$(jq -c "$normalize" <<<"$desired")" ]]; then
    return 0
  fi
  for rule_id in $(api GET "/streams/${id}" | jq -r '.rules[].id'); do
    api DELETE "/streams/${id}/rules/${rule_id}" >/dev/null
  done
  jq -c '.[]' <<<"$desired" | while read -r rule; do
    api POST "/streams/${id}/rules" "$rule" >/dev/null
  done
  log "stream rules updated: ${title}"
}

# Regra de stream: tipos do Graylog — 1 igual, 2 regex, 3 maior que, 4 menor que, 5 campo presente.
# 4º parâmetro opcional "true" inverte a regra (ex.: NÃO ser evento do navegador).
stream_rule() {
  jq -nc --arg f "$1" --argjson t "$2" --arg v "$3" --argjson i "${4:-false}" '{field: $f, type: $t, value: $v, inverted: $i}'
}

# ---------------------------------------------------------------- pipeline
ensure_rule() {
  local file="$1"
  local source title id
  source="$(cat "$file")"
  title="$(sed -n 's/^rule "\(.*\)"$/\1/p' "$file" | head -1)"
  id="$(api GET /system/pipelines/rule | jq -r --arg t "$title" '.[] | select(.title == $t) | .id' | head -1)"
  local body
  body="$(jq -nc --arg s "$source" --arg t "$title" '{title: $t, source: $s, description: $t}')"
  if [[ -z "$id" ]]; then
    api POST /system/pipelines/rule "$body" >/dev/null
    log "pipeline rule created: ${title}"
  else
    # Mantém a regra sincronizada com o arquivo versionado.
    api PUT "/system/pipelines/rule/${id}" "$(jq -c --arg id "$id" '. + {id: $id}' <<<"$body")" >/dev/null
  fi
}

ensure_pipeline() {
  local title="$1" source="$2"
  local id
  id="$(api GET /system/pipelines/pipeline | jq -r --arg t "$title" '.[] | select(.title == $t) | .id' | head -1)"
  local body
  body="$(jq -nc --arg t "$title" --arg s "$source" '{title: $t, description: $t, source: $s}')"
  if [[ -z "$id" ]]; then
    id="$(api POST /system/pipelines/pipeline "$body" | jq -r '.id')"
    log "pipeline created: ${title}"
  else
    api PUT "/system/pipelines/pipeline/${id}" "$(jq -c --arg id "$id" '. + {id: $id}' <<<"$body")" >/dev/null
  fi
  echo "$id"
}

# Por padrão o roteamento de streams (Message Filter Chain) roda antes do Pipeline Processor; invertemos para
# que os campos criados no pipeline (ex.: service_name do Docker) já estejam disponíveis para as regras dos streams.
ensure_pipeline_before_streams() {
  local config reordered
  config="$(api GET /system/messageprocessors/config)"
  reordered="$(jq -c '
    (.processor_order | map(select(.class_name | test("Pipeline")))) as $pipeline
    | (.processor_order | map(select(.class_name | test("Pipeline") | not))) as $others
    | ($others | map(.class_name) | index("org.graylog2.messageprocessors.MessageFilterChainProcessor")) as $filter
    | .processor_order = ($others[:$filter] + $pipeline + $others[$filter:])' <<<"$config")"
  if [[ "$(jq -c '.processor_order' <<<"$config")" != "$(jq -c '.processor_order' <<<"$reordered")" ]]; then
    api PUT /system/messageprocessors/config "$reordered" >/dev/null
    log "processing order: pipeline before stream routing"
  fi
}

# ---------------------------------------------------------------- alertas (event definitions)
# Uso: ensure_event "Título" "Descrição" <prioridade 1-3> <stream_id> "<query>" <limiar> <janela_min>
ensure_event() {
  local title="$1" description="$2" priority="$3" stream="$4" query="$5" threshold="$6" window_min="$7"
  local existing
  existing="$(api GET "/events/definitions?per_page=200" | jq -c --arg t "$title" '[.event_definitions[] | select(.title == $t)][0] // empty')"
  if [[ -n "$existing" ]]; then
    # Já existe com a mesma consulta/stream/limiar: nada a fazer. Se mudou no script, recria para sincronizar.
    if jq -e --arg q "$query" --arg s "$stream" --argjson th "$threshold" \
      '.config.query == $q and .config.streams == [$s] and .config.conditions.expression.right.value == $th' <<<"$existing" >/dev/null; then
      return 0
    fi
    api DELETE "/events/definitions/$(jq -r '.id' <<<"$existing")" >/dev/null
    log "alert outdated, recreating: ${title}"
  fi
  api POST "/events/definitions?schedule=true" "$(jq -nc --arg t "$title" --arg d "$description" \
    --argjson p "$priority" --arg s "$stream" --arg q "$query" --argjson th "$threshold" \
    --argjson w "$((window_min * 60000))" '{ entity: {
      title: $t, description: $d, priority: $p, alert: true,
      config: {
        type: "aggregation-v1", query: $q, query_parameters: [], filters: [], streams: [$s],
        group_by: [], series: [{id: "count-", type: "count"}],
        conditions: { expression: { expr: ">", left: { expr: "number-ref", ref: "count-" },
                                    right: { expr: "number", value: $th } } },
        search_within_ms: $w, execute_every_ms: 60000, use_cron_scheduling: false, event_limit: 100 },
      field_spec: {}, key_spec: [],
      notification_settings: { grace_period_ms: $w, backlog_size: 20 },
      notifications: [] } }')" >/dev/null
  log "alert created: ${title}"
}

# Uso: remove_event "Título" — apaga a definição de alerta com esse título, se existir (idempotente).
remove_event() {
  local title="$1" id
  for id in $(api GET "/events/definitions?per_page=200" | jq -r --arg t "$title" '.event_definitions[] | select(.title == $t) | .id'); do
    api DELETE "/events/definitions/${id}" >/dev/null
    log "legacy alert removed: ${title}"
  done
}

# ================================================================= execução
wait_for_graylog

ensure_input "GELF TCP (aplicações)" "org.graylog2.inputs.gelf.tcp.GELFTCPInput"
ensure_input "GELF UDP (Docker logging driver)" "org.graylog2.inputs.gelf.udp.GELFUDPInput"
# HTTP responde 202 ao gravar: para quem precisa saber se o log chegou (ex.: auditoria do Keycloak com fallback).
ensure_input "GELF HTTP (aplicações com confirmação)" "org.graylog2.inputs.gelf.http.GELFHttpInput" 12202

legado_index="$(ensure_index_set "Legado" "legado" "Logs do sistema legado (retenção limitada por LGPD).")"
sonarqube_index="$(ensure_index_set "SonarQube" "sonarqube" "Logs do SonarQube e do seu PostgreSQL (retenção limitada).")"
keycloak_index="$(ensure_index_set "Keycloak" "keycloak" "Auditoria e logs do Keycloak (retenção limitada por LGPD).")"
cadastro_index="$(ensure_index_set "Cadastro" "cadastro" "Logs do Cadastro (retenção limitada por LGPD).")"

for rule in "$RULES_DIR"/*.rule; do ensure_rule "$rule"; done
pipeline_id="$(ensure_pipeline "Legado - enriquecimento" "$(cat <<'EOF'
pipeline "Legado - enriquecimento"
stage 0 match pass
rule "docker: service_name a partir da tag"
rule "docker: nível real pelo conteúdo"
rule "sonarqube: nível real pelo conteúdo"
rule "keycloak: campos do log JSON do servidor"
stage 1 match pass
rule "nginx: campos do access log JSON"
rule "keycloak: descartar eventos do listener padrão (LGPD)"
stage 2 match pass
rule "nginx: 5xx é erro"
rule "nginx: 4xx é aviso"
stage 3 match pass
rule "nível: nome legível"
rule "LGPD: mascarar e-mail e CPF"
end
EOF
)")"
# "match pass": cada estágio segue para o próximo mesmo sem regra aplicável (senão o mascaramento LGPD seria pulado).
# Conectado ao stream padrão e executado antes do roteamento: os campos criados aqui já servem às regras dos streams.
api POST /system/pipelines/connections/to_pipeline "$(jq -nc --arg p "$pipeline_id" --arg s "$DEFAULT_STREAM_ID" \
  '{pipeline_id: $p, stream_ids: [$s]}')" >/dev/null
ensure_pipeline_before_streams

api_stream="$(ensure_stream "Legado - API" "Logs estruturados da Legado.Api (Serilog/GELF TCP)." "$legado_index" true \
  "[$(stream_rule service_name 1 legado-api)]")"
web_stream="$(ensure_stream "Legado - Web (nginx)" "Access log JSON do nginx do frontend." "$legado_index" true \
  "[$(stream_rule service_name 1 legado-web)]")"
infra_stream="$(ensure_stream "Legado - Infra" "SQL Server e migrator." "$legado_index" true \
  "[$(stream_rule service_name 2 '^legado-(sqlserver|migrator)$')]")"
errors_stream="$(ensure_stream "Legado - Erros" "Erros e falhas críticas de qualquer serviço do legado." "$legado_index" false \
  "[$(stream_rule service_name 2 '^legado-'),$(stream_rule level 4 4)]")"
browser_stream="$(ensure_stream "Legado - Navegador" "Eventos do frontend (erros JS, falhas e operações), enviados via API." "$legado_index" false \
  "[$(stream_rule service_name 1 legado-api),$(stream_rule log_source 1 browser)]")"
# Eventos do navegador chegam por endpoint anônimo e podem ser forjados: nunca entram na trilha de segurança.
security_stream="$(ensure_stream "Legado - Segurança" "Auditoria: login, logout, tokens recusados, rate limit (OWASP A09)." "$legado_index" false \
  "[$(stream_rule service_name 1 legado-api),$(stream_rule message 2 '(Sign-in|signed (in|out)|Access token rejected|Rate limit exceeded|registered)'),$(stream_rule log_source 1 browser true)]")"

# SonarQube (projeto ../sonarqube): servidor e PostgreSQL pelo Docker GELF driver.
sonarqube_stream="$(ensure_stream "SonarQube - Infra" "Servidor SonarQube e seu PostgreSQL." "$sonarqube_index" true \
  "[$(stream_rule service_name 2 '^sonarqube(-db)?$')]")"
# Keycloak (projeto ../keycloak): auditoria via GELF HTTP (listener workspace-audit, sem dados pessoais) e
# servidor/PostgreSQL pelo Docker GELF driver.
keycloak_audit_stream="$(ensure_stream "Keycloak - Auditoria" "Logins, falhas e ações administrativas (id técnico do usuário, sem dados pessoais)." "$keycloak_index" true \
  "[$(stream_rule service_name 1 keycloak)]")"
keycloak_server_stream="$(ensure_stream "Keycloak - Servidor" "Logs do servidor Keycloak e do seu PostgreSQL." "$keycloak_index" true \
  "[$(stream_rule service_name 2 '^keycloak-(server|db)$')]")"
# Migração sob demanda do Legado (spec 001 do cadastro): eventos LEGACY_* e RESET_UNKNOWN_USER da auditoria do
# Keycloak, com o identificador mascarado (ADR-0007 do keycloak). Também ficam em "Keycloak - Auditoria".
migration_stream="$(ensure_stream "Identidade - Migração" "Migração do Legado para o Keycloak e tentativas inválidas (login mascarado)." "$keycloak_index" false \
  "[$(stream_rule service_name 1 keycloak),$(stream_rule type 2 '^(LEGACY_.+|RESET_UNKNOWN_USER)$')]")"

# Cadastro (projeto ../cadastro): BFF (Serilog/GELF TCP) e nginx (Docker GELF driver), mesmo padrão do legado.
cadastro_api_stream="$(ensure_stream "Cadastro - API" "Logs estruturados da Cadastro.Api (BFF, Serilog/GELF TCP)." "$cadastro_index" true \
  "[$(stream_rule service_name 1 cadastro-api)]")"
cadastro_web_stream="$(ensure_stream "Cadastro - Web (nginx)" "Access log JSON do nginx do frontend do Cadastro." "$cadastro_index" true \
  "[$(stream_rule service_name 1 cadastro-web)]")"
cadastro_errors_stream="$(ensure_stream "Cadastro - Erros" "Erros e falhas críticas de qualquer serviço do Cadastro." "$cadastro_index" false \
  "[$(stream_rule service_name 2 '^cadastro-'),$(stream_rule level 4 4)]")"
cadastro_browser_stream="$(ensure_stream "Cadastro - Navegador" "Eventos do frontend do Cadastro, enviados via API." "$cadastro_index" false \
  "[$(stream_rule service_name 1 cadastro-api),$(stream_rule log_source 1 browser)]")"
# Eventos do navegador chegam por endpoint anônimo e podem ser forjados: nunca entram na trilha de segurança.
cadastro_security_stream="$(ensure_stream "Cadastro - Segurança" "Login, logout, acesso negado, rate limit e cadastro (OWASP A09)." "$cadastro_index" false \
  "[$(stream_rule service_name 1 cadastro-api),$(stream_rule message 2 '(Sign-in|signed (in|out)|Access denied|Rate limit exceeded|registered)'),$(stream_rule log_source 1 browser true)]")"

# Títulos antigos ("Sistema: assunto") de antes do padrão "<Sistema> - <Assunto>": remove para não duplicar alertas.
LEGACY_EVENT_TITLES=(
  "Legado: erros na aplicação"
  "Legado: erros no navegador"
  "Legado: falhas de autenticação em massa"
  "Legado: rate limit acionado"
  "Legado: API lenta"
  "Legado: erros 5xx no nginx"
  "SonarQube: erros no servidor"
  "Keycloak: falhas de login em massa"
  "Keycloak: auditoria salva no fallback"
  "Keycloak: erros no servidor"
)
for legacy_title in "${LEGACY_EVENT_TITLES[@]}"; do remove_event "$legacy_title"; done

# Todos os alertas ignoram as mensagens sintéticas do smoke test (campo smoke_test="true"; o GELF descarta
# campos booleanos, por isso o valor é texto), para não gerar alarme falso.
REAL="NOT smoke_test:true"
# Alertas de backend ignoram eventos do navegador (forjáveis); esses têm alerta próprio e de menor prioridade.
ensure_event "Legado - Erros na aplicação" "Qualquer Error/Critical em serviços do legado nos últimos 5 minutos." 3 \
  "$errors_stream" "${REAL} AND NOT log_source:browser" 0 5
ensure_event "Legado - Erros no navegador" "Erros JavaScript ou falhas inesperadas reportadas pelo frontend." 2 \
  "$browser_stream" "${REAL} AND level:<=3" 0 5
ensure_event "Legado - Falhas de autenticação em massa" "Mais de 20 logins falhos ou tokens recusados em 5 minutos (força bruta / roubo de token)." 3 \
  "$security_stream" "${REAL} AND (message:\"Sign-in failed\" OR message:\"Sign-in rejected\" OR message:\"Access token rejected\") AND NOT log_source:browser" 20 5
ensure_event "Legado - Rate limit acionado" "Algum cliente excedeu o limite de requisições." 2 \
  "$security_stream" "${REAL} AND message:\"Rate limit exceeded\" AND NOT log_source:browser" 0 5
ensure_event "Legado - API lenta" "Mais de 10 requisições acima de 1 s em 5 minutos." 2 \
  "$api_stream" "${REAL} AND Elapsed:>1000" 10 5
ensure_event "Legado - Erros 5xx no nginx" "Respostas 5xx servidas pelo frontend/proxy." 2 \
  "$web_stream" "${REAL} AND http_status:>=500" 0 5
ensure_event "SonarQube - Erros no servidor" "Qualquer Error/Critical no SonarQube ou no seu PostgreSQL nos últimos 5 minutos." 2 \
  "$sonarqube_stream" "${REAL} AND level:<=3" 0 5
ensure_event "Keycloak - Falhas de login em massa" "Mais de 20 logins falhos em 5 minutos (força bruta / credential stuffing)." 3 \
  "$keycloak_audit_stream" "${REAL} AND type:LOGIN_ERROR" 20 5
ensure_event "Keycloak - Auditoria salva no fallback" "O Graylog ficou indisponível e registros de auditoria foram salvos no arquivo local do Keycloak." 3 \
  "$keycloak_audit_stream" "${REAL} AND type:AUDIT_FALLBACK_USED" 0 5
ensure_event "Keycloak - Erros no servidor" "Qualquer Error/Critical no Keycloak ou no seu PostgreSQL nos últimos 5 minutos." 2 \
  "$keycloak_server_stream" "${REAL} AND level:<=3" 0 5

ensure_event "Identidade - Tentativas de migração inválidas" "Mais de 30 logins/resets inválidos de usuários fora do Keycloak em 5 minutos (enumeração / credential stuffing)." 3 \
  "$migration_stream" "${REAL} AND (type:LEGACY_USER_NOT_FOUND OR type:LEGACY_PASSWORD_MISMATCH OR type:LEGACY_ACCOUNT_LOCKED OR type:RESET_UNKNOWN_USER)" 30 5
ensure_event "Identidade - Legado indisponível" "5 ou mais falhas ao consultar o Legado em 5 minutos: quem ainda não migrou não consegue entrar." 3 \
  "$migration_stream" "${REAL} AND type:LEGACY_UNAVAILABLE" 4 5
ensure_event "Identidade - Falha ao marcar migração" "O Legado não registrou uma migração concluída: a conta continua ativa no Legado (reprocessar o PUT)." 2 \
  "$migration_stream" "${REAL} AND type:LEGACY_MIGRATION_MARK_FAILED" 0 5
ensure_event "Cadastro - Erros na aplicação" "Qualquer Error/Critical em serviços do Cadastro nos últimos 5 minutos." 3 \
  "$cadastro_errors_stream" "${REAL} AND NOT log_source:browser" 0 5
ensure_event "Cadastro - Erros no navegador" "Erros JavaScript ou falhas inesperadas reportadas pelo frontend do Cadastro." 2 \
  "$cadastro_browser_stream" "${REAL} AND level:<=3" 0 5
ensure_event "Cadastro - Erros 5xx no nginx" "Respostas 5xx servidas pelo frontend/proxy do Cadastro." 2 \
  "$cadastro_web_stream" "${REAL} AND http_status:>=500" 0 5

log "done (streams: cadastro-api=${cadastro_api_stream} cadastro-security=${cadastro_security_stream} migration=${migration_stream} api=${api_stream} web=${web_stream} infra=${infra_stream} errors=${errors_stream} browser=${browser_stream} security=${security_stream} sonarqube=${sonarqube_stream} keycloak-audit=${keycloak_audit_stream} keycloak-server=${keycloak_server_stream})"
