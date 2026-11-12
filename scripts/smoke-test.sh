#!/usr/bin/env bash
# Smoke test ponta a ponta do Graylog: envia mensagens GELF (TCP e UDP) como os serviços do legado fazem e
# confere ingestão, roteamento para streams, extração de campos do nginx e mascaramento de dados pessoais.
# Uso (na raiz do projeto, com o stack de pé):
#   docker compose run --rm -T -v "$PWD/scripts:/scripts:ro" --entrypoint /scripts/smoke-test.sh provisioner
set -euo pipefail

: "${GRAYLOG_URL:?}" "${GRAYLOG_ADMIN_USER:?}" "${GRAYLOG_ADMIN_PASSWORD:?}"
GELF_HOST="${GELF_HOST:-graylog}"
RUN_ID="smoke$(date +%s)$RANDOM"
failures=0

api() {
  curl -sS --fail-with-body -u "${GRAYLOG_ADMIN_USER}:${GRAYLOG_ADMIN_PASSWORD}" -H "X-Requested-By: smoke-test" \
    -H "Accept: application/json" -H "Content-Type: application/json" "$@"
}

check() {
  local description="$1" ok="$2"
  if [[ "$ok" == "true" ]]; then echo "✅ ${description}"; else echo "❌ ${description}"; failures=$((failures + 1)); fi
}

# A API de busca devolve em "streams" o título de cada stream (não o id).
stream_id() { echo "$1"; }

# Busca a mensagem do RUN_ID (até 60 s, o índice é near real-time) e devolve o primeiro resultado como JSON.
find_message() {
  local query="$1"
  for _ in $(seq 1 30); do
    local result
    result="$(api -X POST "${GRAYLOG_URL}/api/search/messages" --data "$(jq -nc --arg q "$query" '{
      query: $q, timerange: {type: "relative", range: 600}, size: 1,
      fields: ["message", "service_name", "streams", "level_name", "http_status", "http_path", "http_request_time", "correlation_id", "smoke_test", "user_id", "logger", "type"] }')")"
    if [[ "$(jq '.datarows | length' <<<"$result")" -gt 0 ]]; then
      jq -c '[.schema | map(.field)] as [$f] | .datarows[0] | [$f, .] | transpose | map({(.[0]): .[1]}) | add' <<<"$result"
      return 0
    fi
    sleep 2
  done
  echo "{}"
}

# 1) API via GELF TCP (como o Serilog), com e-mail e CPF no texto para testar o mascaramento LGPD.
printf '%s\0' "$(jq -nc --arg id "$RUN_ID" '{
  version: "1.1", _smoke_test: "true", host: "smoke-test", level: 3,
  short_message: ("api " + $id + " falhou para ana.souza@exemplo.com cpf 123.456.789-09"),
  _service_name: "legado-api", _correlation_id: $id }')" | nc -w 3 "$GELF_HOST" 12201

# 2) nginx via GELF UDP (como o Docker logging driver): JSON no "message" e a tag do compose.
nginx_json="$(jq -nc --arg id "$RUN_ID" '{time: "2026-11-09T00:00:00+00:00", request_id: $id, correlation_id: $id,
  method: "GET", path: "/api/v1/users/me", status: 200, bytes: 512, request_time: 0.012, upstream_time: "0.010",
  user_agent: "smoke-test"}')"
jq -nc --arg m "$nginx_json" '{version: "1.1", _smoke_test: "true", host: "legado-web", short_message: $m, level: 6, _tag: "legado-web"}' \
  | nc -u -w 1 "$GELF_HOST" 12201

# 3) stderr do nginx: o Docker marca level 3, mas "[notice]" não é erro.
jq -nc --arg id "$RUN_ID" '{version: "1.1", _smoke_test: "true", host: "legado-web", level: 3, _tag: "legado-web",
  short_message: ("2026/11/09 00:00:00 [notice] 1#1: start worker process " + $id)}' | nc -u -w 1 "$GELF_HOST" 12201

# 5) Evento do navegador forjado imitando falha de login: não pode entrar na trilha de segurança.
printf '%s\0' "$(jq -nc --arg id "$RUN_ID" '{
  version: "1.1", _smoke_test: "true", host: "smoke-test", level: 4, _service_name: "legado-api", _log_source: "browser",
  short_message: ("Browser auth.fake at login-page: Sign-in failed " + $id), _correlation_id: ($id + "-browser") }')" \
  | nc -w 3 "$GELF_HOST" 12201

# 4) 502 no access log: deve virar erro.
bad_json="$(jq -nc --arg id "${RUN_ID}-502" '{request_id: $id, correlation_id: $id, method: "GET", path: "/api/v1/users", status: 502}')"
jq -nc --arg m "$bad_json" '{version: "1.1", _smoke_test: "true", host: "legado-web", short_message: $m, level: 6, _tag: "legado-web"}' \
  | nc -u -w 1 "$GELF_HOST" 12201

# 6) SonarQube: tudo sai no stdout (level 6); o nível real vem do texto.
jq -nc --arg id "$RUN_ID" '{version: "1.1", _smoke_test: "true", host: "sonarqube", level: 6, _tag: "sonarqube",
  short_message: ("2026.11.09 00:00:00 ERROR web[][o.s.s.SmokeTest] failure " + $id)}' | nc -u -w 1 "$GELF_HOST" 12201

# 7) PostgreSQL do SonarQube: tudo sai no stderr (level 3), mas "LOG:" é informativo.
jq -nc --arg id "$RUN_ID" '{version: "1.1", _smoke_test: "true", host: "sonarqube-db", level: 3, _tag: "sonarqube-db",
  short_message: ("2026-11-09 00:00:00.000 UTC [63] LOG:  checkpoint starting: " + $id)}' | nc -u -w 1 "$GELF_HOST" 12201

# 8) Keycloak: auditoria via GELF HTTP (como o listener workspace-audit), que precisa de 202 para não usar o fallback.
keycloak_http_status="$(jq -nc --arg id "$RUN_ID" '{
  version: "1.1", _smoke_test: "true", host: "keycloak", level: 4, _service_name: "keycloak", _log_source: "audit",
  short_message: ("Keycloak user event LOGIN_ERROR failed: invalid_user_credentials " + $id), _kind: "user",
  _type: "LOGIN_ERROR", _user_id: ("user-" + $id), _error: "invalid_user_credentials", _event_id: $id }' \
  | curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- "http://${GELF_HOST}:12202/gelf")"

# 9) Servidor Keycloak: JSON no stdout (KC_LOG_CONSOLE_OUTPUT=json) pelo Docker GELF driver, com e-mail no texto.
keycloak_json="$(jq -nc --arg id "$RUN_ID" '{timestamp: "2026-11-12T00:00:00Z", loggerName: "org.keycloak.services",
  level: "ERROR", message: ("smoke failure " + $id + " for ana.souza@exemplo.com"), threadName: "executor-thread-1"}')"
jq -nc --arg m "$keycloak_json" '{version: "1.1", _smoke_test: "true", host: "keycloak", short_message: $m, level: 6, _tag: "keycloak-server"}' \
  | nc -u -w 1 "$GELF_HOST" 12201

# 10) Listener padrão do Keycloak (org.keycloak.events) com username: tem de ser descartado (LGPD).
default_events_json="$(jq -nc --arg id "$RUN_ID" '{loggerName: "org.keycloak.events", level: "WARN",
  message: ("type=\"LOGIN_ERROR\", realmName=\"master\", username=\"usuario." + $id + "\", error=\"user_not_found\"")}')"
jq -nc --arg m "$default_events_json" '{version: "1.1", _smoke_test: "true", host: "keycloak", short_message: $m, level: 6, _tag: "keycloak-server"}' \
  | nc -u -w 1 "$GELF_HOST" 12201

api_message="$(find_message "correlation_id:${RUN_ID} AND service_name:legado-api")"
check "GELF TCP ingerido (legado-api)" "$(jq 'has("message")' <<<"$api_message")"
check "Marca smoke_test gravada (alertas ignoram mensagens sintéticas)" "$(jq '.smoke_test == "true"' <<<"$api_message")"
check "Roteado para o stream 'Legado - API'" "$(jq --arg s "$(stream_id 'Legado - API')" '(.streams // []) | index($s) != null' <<<"$api_message")"
check "Erro (level 3) também no stream 'Legado - Erros'" "$(jq --arg s "$(stream_id 'Legado - Erros')" '(.streams // []) | index($s) != null' <<<"$api_message")"
check "Nível legível (level_name=error)" "$(jq '.level_name == "error"' <<<"$api_message")"
check "LGPD: e-mail mascarado" "$(jq '(.message | contains("ana.souza@exemplo.com") | not) and (.message | contains("***@***"))' <<<"$api_message")"
check "LGPD: CPF mascarado" "$(jq '(.message | contains("123.456.789-09") | not)' <<<"$api_message")"

web_message="$(find_message "http_correlation_id:${RUN_ID}")"
check "GELF UDP ingerido e service_name vindo da tag (legado-web)" "$(jq '.service_name == "legado-web"' <<<"$web_message")"
check "Campos do access log extraídos (http_status=200, http_path)" "$(jq '.http_status == 200 and .http_path == "/api/v1/users/me"' <<<"$web_message")"
check "Roteado para o stream 'Legado - Web (nginx)'" "$(jq --arg s "$(stream_id 'Legado - Web (nginx)')" '(.streams // []) | index($s) != null' <<<"$web_message")"

notice_message="$(find_message "service_name:legado-web AND message:\"start worker process ${RUN_ID}\"")"
check "stderr '[notice]' recebe nível real (notice), não erro" "$(jq '.level_name == "notice"' <<<"$notice_message")"
check "'[notice]' fora do stream 'Legado - Erros'" "$(jq '(.streams // []) | index("Legado - Erros") == null' <<<"$notice_message")"

browser_message="$(find_message "correlation_id:${RUN_ID}-browser")"
check "Evento do navegador vai para 'Legado - Navegador'" "$(jq '(.streams // []) | index("Legado - Navegador") != null' <<<"$browser_message")"
check "Evento do navegador (forjável) fora de 'Legado - Segurança'" "$(jq '(.streams // []) | index("Legado - Segurança") == null' <<<"$browser_message")"

error_message="$(find_message "http_correlation_id:${RUN_ID}-502")"
check "nginx 502 vira erro e entra em 'Legado - Erros'" "$(jq '.level_name == "error" and ((.streams // []) | index("Legado - Erros") != null)' <<<"$error_message")"

sonarqube_message="$(find_message "service_name:sonarqube AND message:\"failure ${RUN_ID}\"")"
check "SonarQube: 'ERROR' no stdout vira erro e vai para 'SonarQube - Infra'" \
  "$(jq '.level_name == "error" and ((.streams // []) | index("SonarQube - Infra") != null)' <<<"$sonarqube_message")"
check "SonarQube fora dos streams do legado" "$(jq '(.streams // []) | index("Legado - Erros") == null' <<<"$sonarqube_message")"

postgres_message="$(find_message "service_name:sonarqube-db AND message:\"checkpoint starting: ${RUN_ID}\"")"
check "PostgreSQL do SonarQube: 'LOG:' no stderr vira information em 'SonarQube - Infra'" \
  "$(jq '.level_name == "information" and ((.streams // []) | index("SonarQube - Infra") != null)' <<<"$postgres_message")"

check "Keycloak: input GELF HTTP confirma a gravação (202)" "$([[ "$keycloak_http_status" == "202" ]] && echo true || echo false)"
keycloak_audit_message="$(find_message "service_name:keycloak AND event_id:${RUN_ID}")"
check "Keycloak: auditoria vai para 'Keycloak - Auditoria' com o id técnico do usuário" \
  "$(jq --arg u "user-${RUN_ID}" '.user_id == $u and .type == "LOGIN_ERROR" and .level_name == "warning"
    and ((.streams // []) | index("Keycloak - Auditoria") != null)' <<<"$keycloak_audit_message")"

keycloak_server_message="$(find_message "service_name:keycloak-server AND message:\"smoke failure ${RUN_ID}\"")"
check "Keycloak: log JSON do servidor tem nível real (error) e logger extraídos, em 'Keycloak - Servidor'" \
  "$(jq '.level_name == "error" and .logger == "org.keycloak.services"
    and ((.streams // []) | index("Keycloak - Servidor") != null)' <<<"$keycloak_server_message")"
check "Keycloak: LGPD mascara e-mail no texto extraído do JSON" \
  "$(jq '(.message | contains("ana.souza@exemplo.com") | not) and (.message | contains("***@***"))' <<<"$keycloak_server_message")"
check "Keycloak fora dos streams do legado" "$(jq '(.streams // []) | index("Legado - Erros") == null' <<<"$keycloak_server_message")"
# Enviada junto com a mensagem acima: se aquela já foi indexada, esta já passou pelo pipeline (e foi descartada).
dropped_count="$(api -X POST "${GRAYLOG_URL}/api/search/messages" --data "$(jq -nc --arg q "\"usuario.${RUN_ID}\"" \
  '{query: $q, timerange: {type: "relative", range: 600}, size: 1}')" | jq '.datarows | length')"
check "Keycloak: eventos do listener padrão (com username) são descartados (LGPD)" \
  "$([[ "$keycloak_server_message" != "{}" && "$dropped_count" == "0" ]] && echo true || echo false)"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} verificação(ões) falharam (run ${RUN_ID})."
  echo "API: ${api_message}"
  echo "Web: ${web_message}"
  exit 1
fi
echo "Smoke test OK (run ${RUN_ID})."
