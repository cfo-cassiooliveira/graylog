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
      fields: ["message", "full_message", "ExceptionMessage", "StackTrace", "UserName", "Cpf", "Phone", "Cnpj", "Email", "Login", "Celular", "cpf", "cnpj", "email",
        "cpf_token", "email_token", "Obj_Cpf", "Obj_Cpf_token",
        "Cpf_token", "Cnpj_token", "Phone_token", "UserName_token", "Email_token", "service_name", "streams",
        "level_name", "http_status", "http_path", "http_request_time", "correlation_id", "smoke_test", "user_id", "logger", "type",
        "ClientSource", "ClientMessage", "ClientStack", "RequestPath", "case_reference", "phone", "mobilePhone", "mobile_phone", "celular", "telefone", "username", "user_name", "login", "preferred_username", "masked_login", "CPF", "CNPJ", "audit_event", "investigator_id", "data_type", "tokens", "trace_id"] }')")"
    if [[ "$(jq '.datarows | length' <<<"$result")" -gt 0 ]]; then
      jq -c '[.schema | map(.field)] as [$f] | .datarows[0] | [$f, .] | transpose | map({(.[0]): .[1]}) | add' <<<"$result"
      return 0
    fi
    sleep 2
  done
  echo "{}"
}

# Stack recém-criada (CI): logo após o provisionamento os inputs e o índice podem ainda não estar prontos e o que é
# enviado nesse intervalo se perde. As verificações só começam quando uma mensagem de cada input (TCP e UDP) é achada.
wait_for_ingestion() {
  local tcp_found=false udp_found=false
  for _ in $(seq 1 45); do
    [[ "$tcp_found" == "true" ]] || printf '%s\0' "$(jq -nc --arg id "$RUN_ID" \
      '{version: "1.1", _smoke_test: "true", host: "smoke-test", level: 6, short_message: ("warmuptcp " + $id)}')" \
      | nc -w 3 "$GELF_HOST" 12201 || true
    [[ "$udp_found" == "true" ]] || jq -nc --arg id "$RUN_ID" \
      '{version: "1.1", _smoke_test: "true", host: "smoke-test", level: 6, short_message: ("warmupudp " + $id)}' \
      | nc -u -w 1 "$GELF_HOST" 12201 || true
    sleep 2
    [[ "$(count_messages "warmuptcp AND \"${RUN_ID}\"")" -gt 0 ]] && tcp_found=true
    [[ "$(count_messages "warmupudp AND \"${RUN_ID}\"")" -gt 0 ]] && udp_found=true
    if [[ "$tcp_found" == "true" && "$udp_found" == "true" ]]; then return 0; fi
  done
  echo "❌ Graylog não indexou as mensagens de aquecimento em 90 s (TCP: ${tcp_found}, UDP: ${udp_found})"
  exit 1
}

count_messages() {
  api -X POST "${GRAYLOG_URL}/api/search/messages" --data "$(jq -nc --arg q "$1" \
    '{query: $q, timerange: {type: "relative", range: 600}, size: 1, fields: ["message"]}')" \
    | jq '.datarows | length' || echo 0
}

wait_for_ingestion

# 1) API via GELF TCP (como o Serilog), com dados pessoais no texto e nos campos que o sink Serilog envia além do
#    "message" (full_message e os da exceção) para testar o mascaramento LGPD (ADR-0002).
pii_text="ana.souza@exemplo.com cpf 123.456.789-09 cnpj 12.ABC.345/01DE-35 celular (11) 98765-4321"
pii_masked="ana***@exemplo cpf ***.456.789-** cnpj 12.A**.***/***E-35 celular 11*****4321"
printf '%s\0' "$(jq -nc --arg id "$RUN_ID" --arg pii "$pii_text" '{
  version: "1.1", _smoke_test: "true", host: "smoke-test", level: 3,
  short_message: ("api " + $id + " falhou para " + $pii), full_message: ("api " + $id + " falhou para " + $pii),
  _ExceptionMessage: "duplicate key value is (ana.souza@exemplo.com)", _StackTrace: "at Smoke.Test(12345678909)",
  _UserName: "Maria.Silva", _service_name: "legado-api", _correlation_id: $id }')" | nc -w 3 "$GELF_HOST" 12201

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

# 5b) Assinatura da API interna recusada (ADR-0005 do legado): vai para a trilha de segurança.
printf '%s\0' "$(jq -nc --arg id "$RUN_ID" '{
  version: "1.1", _smoke_test: "true", host: "smoke-test", level: 4, _service_name: "legado-api",
  short_message: "Internal API signature rejected (invalid) for key keycloak-1", _correlation_id: ($id + "-hmac") }')" \
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

# 11) Dado pessoal como CAMPO ESTRUTURADO (regra do workspace), como o Serilog grava "{UserName} ... {Cpf} ... {Phone}":
#     o valor vai no campo e no texto. O tipo vem do nome do campo: "11987654321" é celular, não CPF.
printf '%s\0' "$(jq -nc --arg id "$RUN_ID" '{
  version: "1.1", _smoke_test: "true", host: "smoke-test", level: 6, _service_name: "legado-api",
  _correlation_id: ($id + "-typed"), _UserName: "Maria.Silva", _Cpf: "11223366699", _Phone: "11987654321",
  short_message: ("Cadastro " + $id + " de \"Maria.Silva\" com CPF \"11223366699\" e celular \"11987654321\"") }')" \
  | nc -w 3 "$GELF_HOST" 12201

# 12) Origem que já pseudonimiza (ADR-0003): máscara e <Campo>_token prontos chegam e ficam como estão (campo e texto).
#     Inclui CNPJ alfanumérico, e-mail curto (a***) e longo (ana***, formato do legado) e nomes em minúsculas.
premasked_text="CPF ***.456.789-** e ***.233.666-** CNPJ 12.3**.***/***1-90 e 12.A**.***/***E-35"
premasked_text+=" celular 11*****4321 login mar*** e jos*** e-mail a***@gmail e ana***@gmail"
printf '%s\0' "$(jq -nc --arg id "$RUN_ID" --arg t "$premasked_text" '{
  version: "1.1", _smoke_test: "true", host: "smoke-test", level: 6, _service_name: "legado-api",
  _correlation_id: ($id + "-premasked"), short_message: ("Pronto " + $id + " " + $t),
  _Cpf: "***.456.789-**", _Cpf_token: "k1-b81c27bb5f38080e6ca0ed38b828f262",
  _Cnpj: "12.3**.***/***1-90", _Cnpj_token: "k1-f528c9e51a504dbaf6a9f245ba2cea10",
  _Phone: "11*****4321", _Phone_token: "k1-412838d1c85d64c0ed202ae3b1546615",
  _UserName: "mar***", _UserName_token: "k1-c5b5c3feef6c408ecea5b17d95af9793",
  _Email: "a***@gmail", _Email_token: "k1-c362504bb56a3e35cc245073244c3da6",
  _cpf: "***.233.666-**", _cpf_token: "k1-b81c27bb5f38080e6ca0ed38b828f262", _cnpj: "12.A**.***/***E-35",
  _email: "ana***@gmail", _email_token: "k1-c362504bb56a3e35cc245073244c3da6", _Login: "jos***",
  _ClientSource: "/users/ana***@gmail", _ClientMessage: $t, _ClientStack: ("at save (" + $t + ")"),
  "_Obj.Cpf": "***.456.789-**", _Obj_Cpf_token: "k1-b81c27bb5f38080e6ca0ed38b828f262" }')" \
  | nc -w 3 "$GELF_HOST" 12201

# 13) Valor fora do formato: o campo vira ***. No texto, CPF/CNPJ/telefone com 8+ caracteres também viram *** (origem
#     não adaptada, ADR-0003 item 10); valor curto (login < 4, telefone "1") não é trocado (ADR-0003 item 10), para
#     UserName "api" não virar "Legado.***" nem "/***/v1" e login "ab" não corromper "tabela abc".
short_text="Legado.Api falhou em /api/v1/users na tabela abc para 1234567890 ramal 1 celular 98765-4321"
short_masked="Legado.Api falhou em /api/v1/users na tabela abc para *** ramal 1 celular ***"
printf '%s\0' "$(jq -nc --arg id "$RUN_ID" --arg t "$short_text" '{
  version: "1.1", _smoke_test: "true", host: "smoke-test", level: 6, _service_name: "legado-api",
  _correlation_id: ($id + "-short"), short_message: ("Curto " + $id + " " + $t),
  _StackTrace: "at Legado.Api.Users.Get()", _http_path: "/api/v1/users",
  _UserName: "api", _Login: "ab", _Cpf: "1234567890", _Phone: "1", _Celular: "98765-4321" }')" \
  | nc -w 3 "$GELF_HOST" 12201

# 14) Campos de texto além do message (ADR-0003, item 8), sem campo estruturado (rede de segurança, estágio 4): URL do
#     navegador (ClientSource, com e-mail em "%40"), caminho da requisição do Serilog (RequestPath), motivo da pesquisa
#     (case_reference) e celular com "+55" no message.
printf '%s\0' "$(jq -nc --arg id "$RUN_ID" '{
  version: "1.1", _smoke_test: "true", host: "smoke-test", level: 6, _service_name: "legado-api",
  _correlation_id: ($id + "-textfields"), short_message: ("Textos " + $id + " celular +55 (11) 98765-4321 e +5511987654321"),
  _ClientSource: "https://cadastro.local/usuarios/ana.souza%40gmail.com/editar",
  _RequestPath: "/api/v1/users/ana.souza@gmail.com", _case_reference: "INC-123.456.789-09" }')" \
  | nc -w 3 "$GELF_HOST" 12201

# 15) CNPJ e e-mail como CAMPO ESTRUTURADO em claro (origem não adaptada): mascarados pelo tipo e trocados no texto.
printf '%s\0' "$(jq -nc --arg id "$RUN_ID" '{
  version: "1.1", _smoke_test: "true", host: "smoke-test", level: 6, _service_name: "legado-api",
  _correlation_id: ($id + "-typed2"), _Cnpj: "12.345.678/0001-90", _Email: "Ana.Souza@Gmail.com",
  short_message: ("Empresa " + $id + " CNPJ 12.345.678/0001-90 contato Ana.Souza@Gmail.com") }')" \
  | nc -w 3 "$GELF_HOST" 12201

# 16) Auditoria da pesquisa em logs (ADR-0003, item 7), como o Serilog do Cadastro envia: concedida e negada (403).
#     A forjada pelo navegador (log_source:browser, endpoint anônimo) não pode entrar na trilha.
# O contrato com o Cadastro (C03): nomes snake_case e "tokens" como UM texto (tokens separados por vírgula), nunca lista:
# com ParseArrayValues=true o sink do Serilog dividiria a lista em tokens_0, tokens_1...
audit_event() { # <sufixo do correlation_id> <audit_event> <mensagem> [log_source]
  printf '%s\0' "$(jq -nc --arg id "$RUN_ID" --arg suffix "$1" --arg event "$2" --arg msg "$3" --arg source "${4:-}" '{
    version: "1.1", _smoke_test: "true", host: "cadastro-api", level: 6, _service_name: "cadastro-api",
    _correlation_id: ($id + $suffix), _audit_event: $event, _investigator_id: ("sub-" + $id), _trace_id: ($id + "-trace"),
    short_message: ($msg + " " + $id)}
    + (if $event == "log_search_query_issued"
        then {_data_type: "cpf", _case_reference: "INC-1234",
              _tokens: "k1-b81c27bb5f38080e6ca0ed38b828f262,k2-b81c27bb5f38080e6ca0ed38b828f262"} else {} end)
    + (if $source == "" then {} else {_log_source: $source} end)')" \
    | nc -w 3 "$GELF_HOST" 12201
}
audit_event "-audit" log_search_query_issued "Log search query issued"
audit_event "-audit-denied" log_search_access_denied "Log search access denied"
audit_event "-audit-forged" log_search_query_issued "Log search query issued" browser

# 17) Access log JSON do nginx do Cadastro (tag cadastro-web), com 503 e e-mail no caminho.
cadastro_web_json="$(jq -nc --arg id "${RUN_ID}-cadastro-web" '{request_id: $id, correlation_id: $id, method: "GET",
  path: "/api/v1/users/ana.souza@gmail.com", status: 503, bytes: 0, request_time: 0.002, upstream_time: "0.001"}')"
jq -nc --arg m "$cadastro_web_json" '{version: "1.1", _smoke_test: "true", host: "cadastro-web", short_message: $m, level: 6,
  _tag: "cadastro-web"}' | nc -u -w 1 "$GELF_HOST" 12201

# 18) Variações de nome de campo (cada grafia das listas LGPD_*_FIELDS) e client-logs em CLARO (origem não adaptada):
#     ClientMessage/ClientStack com e-mail, CPF e celular. CPF/CNPJ curtos (< 14 caracteres) vão para ***.
printf '%s\0' "$(jq -nc --arg id "$RUN_ID" '{
  version: "1.1", _smoke_test: "true", host: "smoke-test", level: 6, _service_name: "legado-api",
  _correlation_id: ($id + "-fieldnames"),
  short_message: ("Nomes " + $id + " fone 11987654321 cnpj curto 1234567890123 cpf curto 123456789 user maria.silva"),
  _phone: "11987654321", _mobilePhone: "11987654321", _mobile_phone: "11987654321", _celular: "11987654321",
  _telefone: "1133334444", _username: "maria.silva", _user_name: "maria.silva", _login: "maria.silva",
  _preferred_username: "maria.silva", _masked_login: "ana***@gmail", _CPF: "123.456.789-09", _CNPJ: "12.345.678/0001-90",
  _Cpf: "123456789", _Cnpj: "1234567890123",
  _ClientMessage: "falha ana.souza@gmail.com cpf 123.456.789-09 cel 11987654321",
  _ClientStack: "at save(ana.souza@gmail.com 12345678909)" }')" \
  | nc -w 3 "$GELF_HOST" 12201

api_message="$(find_message "correlation_id:${RUN_ID} AND service_name:legado-api")"
check "GELF TCP ingerido (legado-api)" "$(jq 'has("message")' <<<"$api_message")"
check "Marca smoke_test gravada (alertas ignoram mensagens sintéticas)" "$(jq '.smoke_test == "true"' <<<"$api_message")"
check "Roteado para o stream 'Legado - API'" "$(jq --arg s "$(stream_id 'Legado - API')" '(.streams // []) | index($s) != null' <<<"$api_message")"
check "Erro (level 3) também no stream 'Legado - Erros'" "$(jq --arg s "$(stream_id 'Legado - Erros')" '(.streams // []) | index($s) != null' <<<"$api_message")"
check "Nível legível (level_name=error)" "$(jq '.level_name == "error"' <<<"$api_message")"
check "LGPD: e-mail, CPF, CNPJ e celular gravados mascarados no message" \
  "$(jq --arg m "$pii_masked" '.message | endswith($m)' <<<"$api_message")"
check "LGPD: mesmos dados mascarados no full_message" "$(jq --arg m "$pii_masked" '.full_message | endswith($m)' <<<"$api_message")"
check "LGPD: exceção mascarada (ExceptionMessage e StackTrace)" \
  "$(jq '.ExceptionMessage == "duplicate key value is (ana***@exemplo)" and .StackTrace == "at Smoke.Test(***.456.789-**)"' <<<"$api_message")"
check "LGPD: campo de login mascarado (UserName=mar***)" "$(jq '.UserName == "mar***"' <<<"$api_message")"
check "LGPD: nenhum valor original gravado" \
  "$(jq 'tostring | (contains("ana.souza") or contains("123.456.789-09") or contains("12345678909")
    or contains("12.ABC.345/01DE-35") or contains("98765-4321") or contains("Maria.Silva")) | not' <<<"$api_message")"

typed_message="$(find_message "correlation_id:${RUN_ID}-typed")"
check "LGPD (campo estruturado): campos mascarados pelo tipo (UserName, Cpf, Phone)" \
  "$(jq '.UserName == "mar***" and .Cpf == "***.233.666-**" and .Phone == "11*****4321"' <<<"$typed_message")"
check "LGPD (campo estruturado): mesmo valor trocado no texto, celular como celular" \
  "$(jq '.message | endswith("de \"mar***\" com CPF \"***.233.666-**\" e celular \"11*****4321\"")' <<<"$typed_message")"

premasked_message="$(find_message "correlation_id:${RUN_ID}-premasked")"
check "LGPD (origem pseudonimizada): máscara pronta preservada (Cpf, Cnpj, Phone, UserName, Email)" \
  "$(jq '.Cpf == "***.456.789-**" and .Cnpj == "12.3**.***/***1-90" and .Phone == "11*****4321"
    and .UserName == "mar***" and .Email == "a***@gmail" and .Login == "jos***" and .cpf == "***.233.666-**"
    and .cnpj == "12.A**.***/***E-35" and .email == "ana***@gmail"' <<<"$premasked_message")"
check "LGPD (origem pseudonimizada): campos *_token preservados" \
  "$(jq '.Cpf_token == "k1-b81c27bb5f38080e6ca0ed38b828f262" and .Cnpj_token == "k1-f528c9e51a504dbaf6a9f245ba2cea10"
    and .Phone_token == "k1-412838d1c85d64c0ed202ae3b1546615" and .UserName_token == "k1-c5b5c3feef6c408ecea5b17d95af9793"
    and .Email_token == "k1-c362504bb56a3e35cc245073244c3da6" and .cpf_token == "k1-b81c27bb5f38080e6ca0ed38b828f262"
    and .email_token == "k1-c362504bb56a3e35cc245073244c3da6"' <<<"$premasked_message")"
check "LGPD (origem pseudonimizada): campo aninhado gravado como Obj_Cpf (máscara) e Obj_Cpf_token (token) ficam como estão" \
  "$(jq '.Obj_Cpf == "***.456.789-**" and .Obj_Cpf_token == "k1-b81c27bb5f38080e6ca0ed38b828f262"' <<<"$premasked_message")"
token_search="$(find_message "Cpf_token:\"k1-b81c27bb5f38080e6ca0ed38b828f262\" AND correlation_id:${RUN_ID}-premasked")"
nested_token_search="$(find_message "Obj_Cpf_token:\"k1-b81c27bb5f38080e6ca0ed38b828f262\" AND correlation_id:${RUN_ID}-premasked")"
check "Pesquisa por token: Cpf_token:\"<token>\" e Obj_Cpf_token:\"<token>\" (aninhado) acham o evento" \
  "$(jq -n --arg id "${RUN_ID}-premasked" --argjson a "$token_search" --argjson b "$nested_token_search" \
    '$a.correlation_id == $id and $b.correlation_id == $id')"
check "LGPD (origem pseudonimizada): texto com as máscaras prontas fica inalterado" \
  "$(jq --arg t "Pronto ${RUN_ID} ${premasked_text}" '.message == $t' <<<"$premasked_message")"
check "LGPD (origem pseudonimizada): client-logs já mascarados (ClientSource, ClientMessage, ClientStack) ficam inalterados" \
  "$(jq --arg t "$premasked_text" '.ClientSource == "/users/ana***@gmail" and .ClientMessage == $t
    and .ClientStack == ("at save (" + $t + ")")' <<<"$premasked_message")"

short_message="$(find_message "correlation_id:${RUN_ID}-short")"
check "LGPD (fora do formato): UserName e Login curtos, CPF de 10 dígitos, telefone curto e sem DDD viram ***" \
  "$(jq '.UserName == "***" and .Login == "***" and .Cpf == "***" and .Phone == "***" and .Celular == "***"' <<<"$short_message")"
check "LGPD (fora do formato): CPF de 10 dígitos e celular sem DDD trocados por *** no texto" \
  "$(jq --arg t "Curto ${RUN_ID} ${short_masked}" '.message == $t' <<<"$short_message")"
check "LGPD (fora do formato): valor curto não corrompe os textos (message, StackTrace, http_path)" \
  "$(jq --arg t "Curto ${RUN_ID} ${short_masked}" '.message == $t and .StackTrace == "at Legado.Api.Users.Get()"
    and .http_path == "/api/v1/users"' <<<"$short_message")"

# As regras pelo campo gravam todos os campos de texto: o ausente não pode passar a existir vazio (Graylog ignora "").
empty_text_fields="$(count_messages "correlation_id:${RUN_ID}-typed AND (_exists_:full_message OR _exists_:ExceptionMessage
  OR _exists_:StackTrace OR _exists_:ClientMessage OR _exists_:ClientStack OR _exists_:ClientSource OR _exists_:RequestPath
  OR _exists_:case_reference OR _exists_:http_path)")"
check "LGPD (campo estruturado): campos de texto ausentes continuam ausentes (nenhum campo vazio criado)" \
  "$([[ "$typed_message" != "{}" && "$empty_text_fields" == "0" ]] && echo true || echo false)"

typed2_message="$(find_message "correlation_id:${RUN_ID}-typed2")"
check "LGPD (campo estruturado): CNPJ e e-mail em claro mascarados pelo tipo (Cnpj, Email)" \
  "$(jq '.Cnpj == "12.3**.***/***1-90" and .Email == "ana***@gmail"' <<<"$typed2_message")"
check "LGPD (campo estruturado): CNPJ e e-mail trocados no texto" \
  "$(jq --arg t "Empresa ${RUN_ID} CNPJ 12.3**.***/***1-90 contato ana***@gmail" '.message == $t' <<<"$typed2_message")"

text_fields_message="$(find_message "correlation_id:${RUN_ID}-textfields")"
check "LGPD (texto): ClientSource com e-mail em %40 mascarado" \
  "$(jq '.ClientSource == "https://cadastro.local/usuarios/ana***@gmail/editar"' <<<"$text_fields_message")"
check "LGPD (texto): RequestPath e case_reference mascarados" \
  "$(jq '.RequestPath == "/api/v1/users/ana***@gmail" and .case_reference == "INC-***.456.789-**"' <<<"$text_fields_message")"
check "LGPD (texto): celular com +55 (formatado e sem pontuação) mascarado no message" \
  "$(jq --arg t "Textos ${RUN_ID} celular 11*****4321 e 11*****4321" '.message == $t' <<<"$text_fields_message")"

cadastro_web_message="$(find_message "http_correlation_id:${RUN_ID}-cadastro-web")"
check "Cadastro: access log do nginx (cadastro-web) extraído, 503 vira erro em 'Cadastro - Web (nginx)' e 'Cadastro - Erros'" \
  "$(jq '.service_name == "cadastro-web" and .http_status == 503 and .level_name == "error"
    and ((.streams // []) | index("Cadastro - Web (nginx)") != null) and ((.streams // []) | index("Cadastro - Erros") != null)
    and ((.streams // []) | index("Legado - Erros") == null)' <<<"$cadastro_web_message")"
check "LGPD (texto): http_path do nginx e message derivado dele mascarados" \
  "$(jq '.http_path == "/api/v1/users/ana***@gmail" and .message == "GET /api/v1/users/ana***@gmail -> 503"' <<<"$cadastro_web_message")"

fieldnames_message="$(find_message "correlation_id:${RUN_ID}-fieldnames")"
check "LGPD (nomes de campo): phone, mobilePhone, mobile_phone, celular e telefone mascarados como telefone" \
  "$(jq '.phone == "11*****4321" and .mobilePhone == "11*****4321" and .mobile_phone == "11*****4321"
    and .celular == "11*****4321" and .telefone == "11*****4444"' <<<"$fieldnames_message")"
check "LGPD (nomes de campo): username, user_name, login e preferred_username mascarados como login (mar***)" \
  "$(jq '.username == "mar***" and .user_name == "mar***" and .login == "mar***" and .preferred_username == "mar***"' <<<"$fieldnames_message")"
check "LGPD (nomes de campo): masked_login do Keycloak (ADR-0007) já mascarado passa intacto" \
  "$(jq '.masked_login == "ana***@gmail"' <<<"$fieldnames_message")"
check "LGPD (nomes de campo): CPF e CNPJ em maiúsculas mascarados pelo tipo" \
  "$(jq '.CPF == "***.456.789-**" and .CNPJ == "12.3**.***/***1-90"' <<<"$fieldnames_message")"
check "LGPD (fora do formato): CPF de 9 e CNPJ de 13 dígitos viram *** no campo e no texto" \
  "$(jq --arg t "Nomes ${RUN_ID} fone 11*****4321 cnpj curto *** cpf curto *** user mar***" \
    '.Cpf == "***" and .Cnpj == "***" and .message == $t' <<<"$fieldnames_message")"
check "LGPD (client-logs em claro): ClientMessage e ClientStack mascarados, sem e-mail, CPF nem celular originais" \
  "$(jq '.ClientMessage == "falha ana***@gmail cpf ***.456.789-** cel 11*****4321"
    and .ClientStack == "at save(ana***@gmail ***.456.789-**)"
    and (tostring | (contains("ana.souza") or contains("123.456.789-09") or contains("12345678909")
      or contains("11987654321") or contains("maria.silva")) | not)' <<<"$fieldnames_message")"

# Retenção (LGPD, ADR-0002): os index sets criados pelo provisioner apagam entre 30 e 35 dias.
retention_ok="$(api "${GRAYLOG_URL}/api/system/indices/index_sets" | jq '[.index_sets[] | select(.title | IN("Legado", "Cadastro", "Keycloak", "SonarQube"))]
  | length == 4 and all(.rotation_strategy.index_lifetime_min == "P30D" and .rotation_strategy.index_lifetime_max == "P35D"
    and .data_tiering.index_lifetime_min == "P30D" and .data_tiering.index_lifetime_max == "P35D")')"
check "Retenção: index sets Legado, Cadastro, Keycloak e SonarQube guardam de 30 a 35 dias (P30D–P35D)" "$retention_ok"

audit_stream="Cadastro - Pesquisa em logs (LGPD)"
audit_message="$(find_message "correlation_id:${RUN_ID}-audit")"
check "Auditoria: pesquisa em logs vai para '${audit_stream}' com investigador, tipo, motivo e tokens" \
  "$(jq --arg s "$audit_stream" --arg u "sub-${RUN_ID}" '.audit_event == "log_search_query_issued" and .investigator_id == $u
    and .data_type == "cpf" and .case_reference == "INC-1234" and .trace_id == ($u | sub("^sub-"; "") + "-trace")
    and .tokens == "k1-b81c27bb5f38080e6ca0ed38b828f262,k2-b81c27bb5f38080e6ca0ed38b828f262"
    and ((.streams // []) | index($s) != null)' <<<"$audit_message")"
denied_message="$(find_message "correlation_id:${RUN_ID}-audit-denied")"
check "Auditoria: pesquisa negada (403) vai para '${audit_stream}' com o investigador e SEM tokens, tipo nem motivo" \
  "$(jq --arg s "$audit_stream" --arg u "sub-${RUN_ID}" '.audit_event == "log_search_access_denied" and .investigator_id == $u
    and (.message | startswith("Log search access denied"))
    and (.tokens | IN(null, "-")) and (.data_type | IN(null, "-")) and (.case_reference | IN(null, "-"))
    and ((.streams // []) | index($s) != null)' <<<"$denied_message")"
forged_message="$(find_message "correlation_id:${RUN_ID}-audit-forged")"
check "Auditoria: evento do navegador (forjável) fora de '${audit_stream}'" \
  "$(jq --arg s "$audit_stream" '. != {} and ((.streams // []) | index($s) == null)' <<<"$forged_message")"

web_message="$(find_message "http_correlation_id:${RUN_ID}")"
check "GELF UDP ingerido e service_name vindo da tag (legado-web)" "$(jq '.service_name == "legado-web"' <<<"$web_message")"
check "Campos do access log extraídos (http_status=200, http_path)" "$(jq '.http_status == 200 and .http_path == "/api/v1/users/me"' <<<"$web_message")"
check "Roteado para o stream 'Legado - Web (nginx)'" "$(jq --arg s "$(stream_id 'Legado - Web (nginx)')" '(.streams // []) | index($s) != null' <<<"$web_message")"

notice_message="$(find_message "service_name:legado-web AND message:\"start worker process ${RUN_ID}\"")"
check "stderr '[notice]' recebe nível real (notice), não erro" "$(jq '.level_name == "notice"' <<<"$notice_message")"
check "'[notice]' fora do stream 'Legado - Erros'" "$(jq '(.streams // []) | index("Legado - Erros") == null' <<<"$notice_message")"

browser_message="$(find_message "correlation_id:${RUN_ID}-browser")"
check "Evento do navegador vai para 'Legado - Navegador'" "$(jq '(.streams // []) | index("Legado - Navegador") != null' <<<"$browser_message")"
signature_message="$(find_message "correlation_id:${RUN_ID}-hmac AND service_name:legado-api")"
check "Assinatura interna recusada vai para 'Legado - Segurança'" \
  "$(jq '(.streams // []) | index("Legado - Segurança") != null' <<<"$signature_message")"
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
  "$(jq '(.message | contains("ana.souza@exemplo.com") | not) and (.message | contains("ana***@exemplo"))' <<<"$keycloak_server_message")"
check "Keycloak fora dos streams do legado" "$(jq '(.streams // []) | index("Legado - Erros") == null' <<<"$keycloak_server_message")"
# Enviada junto com a mensagem acima: se aquela já foi indexada, esta já passou pelo pipeline (e foi descartada).
dropped_count="$(api -X POST "${GRAYLOG_URL}/api/search/messages" --data "$(jq -nc --arg q "\"usuario.${RUN_ID}\"" \
  '{query: $q, timerange: {type: "relative", range: 600}, size: 1}')" | jq '.datarows | length')"
check "Keycloak: eventos do listener padrão (com username) são descartados (LGPD)" \
  "$([[ "$keycloak_server_message" != "{}" && "$dropped_count" == "0" ]] && echo true || echo false)"

# Cadastro.Api (Serilog/GELF TCP, como o legado) e migração do Legado (auditoria do Keycloak com login mascarado,
# pelo input GELF HTTP).
send_gelf_http() { curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- "http://${GELF_HOST}:12202/gelf"; }
printf '%s\0' "$(jq -nc --arg id "$RUN_ID" '{version: "1.1", _smoke_test: "true", host: "cadastro-api", level: 3,
  _service_name: "cadastro-api", short_message: ("Cadastro smoke failure " + $id)}')" | nc -w 3 "$GELF_HOST" 12201
jq -nc --arg id "$RUN_ID" '{version: "1.1", _smoke_test: "true", host: "keycloak", level: 4, _service_name: "keycloak",
  _log_source: "audit", _kind: "migration", _type: "LEGACY_USER_NOT_FOUND", _masked_login: "ana***@gmail",
  _event_id: ("migration-" + $id), short_message: ("Legacy user not found " + $id)}' | send_gelf_http >/dev/null

cadastro_message="$(find_message "service_name:cadastro-api AND message:\"Cadastro smoke failure ${RUN_ID}\"")"
check "Cadastro: log da API vai para 'Cadastro - API' e, sendo erro, para 'Cadastro - Erros'" \
  "$(jq '((.streams // []) | index("Cadastro - API") != null) and ((.streams // []) | index("Cadastro - Erros") != null)' <<<"$cadastro_message")"
check "Cadastro fora dos streams do legado" "$(jq '(.streams // []) | index("Legado - Erros") == null' <<<"$cadastro_message")"
migration_message="$(find_message "service_name:keycloak AND event_id:migration-${RUN_ID}")"
check "Migração: evento LEGACY_* vai para 'Identidade - Migração' e continua em 'Keycloak - Auditoria'" \
  "$(jq '.type == "LEGACY_USER_NOT_FOUND" and ((.streams // []) | index("Identidade - Migração") != null)
    and ((.streams // []) | index("Keycloak - Auditoria") != null)' <<<"$migration_message")"
check "Migração: login de auditoria comum (LOGIN_ERROR) fora de 'Identidade - Migração'" \
  "$(jq '(.streams // []) | index("Identidade - Migração") == null' <<<"$keycloak_audit_message")"

# Alertas: padrão de nome do projeto e nenhum alarme disparado por mensagem sintética.
event_definitions="$(api "${GRAYLOG_URL}/api/events/definitions?per_page=200")"
check "alertas seguem o padrão '<Sistema> - <Assunto>' (sem títulos antigos 'Sistema: assunto')" \
  "$(jq '[.event_definitions[] | select(.config.type == "aggregation-v1") | .title]
    | length > 0 and all(test("^[A-Z][A-Za-z]+ - [A-Z0-9]")) and all(contains(":") | not)' <<<"$event_definitions")"
check "todo alerta ignora as mensagens do smoke test (NOT smoke_test:true)" \
  "$(jq '[.event_definitions[] | select(.config.type == "aggregation-v1") | .config.query | startswith("NOT smoke_test:true")]
    | length > 0 and all' <<<"$event_definitions")"
check "alerta de excesso de pesquisas em logs: mais de 10 do mesmo investigador em 10 min" \
  "$(jq '[.event_definitions[] | select(.title == "Cadastro - Excesso de pesquisas em logs")
    | select(.config.query == "NOT smoke_test:true AND audit_event:log_search_query_issued"
      and .config.group_by == ["investigator_id"] and .config.conditions.expression.right.value == 10
      and .config.search_within_ms == 600000)] | length == 1' <<<"$event_definitions")"
check "alerta de acessos negados à pesquisa em logs: mais de 2 do mesmo usuário em 10 min" \
  "$(jq '[.event_definitions[] | select(.title == "Cadastro - Acessos negados à pesquisa em logs")
    | select(.config.query == "NOT smoke_test:true AND audit_event:log_search_access_denied"
      and .config.group_by == ["investigator_id"] and .config.conditions.expression.right.value == 2
      and .config.search_within_ms == 600000)] | length == 1' <<<"$event_definitions")"

# Provisionamento (funções do provision.sh, carregado sem executar): erro do Graylog visível e nomes de campo validados.
invalid_rule="$(printf 'rule "smoke: regra inválida %s"\nwhen\n  true\nthen\n  set_field(\nend' "$RUN_ID")"
rule_error="$( (source /provisioning/provision.sh && ensure_rule "$invalid_rule") 2>&1 >/dev/null || true)"
check "provision: regra inválida mostra a resposta 400 do Graylog (corpo do erro)" \
  "$([[ "$rule_error" == *"POST /system/pipelines/rule failed"* && "$rule_error" == *"{"* ]] && echo true || echo false)"
field_error="$( (source /provisioning/provision.sh && LGPD_TEXT_FIELDS=(message 'bad-field') \
  && render_rule /provisioning/rules/templates/lgpd-cpf.rule.tmpl Cpf) 2>&1 >/dev/null || true)"
check "provision: nome inválido em LGPD_TEXT_FIELDS é recusado" \
  "$([[ "$field_error" == *"invalid field name for LGPD rule: bad-field"* ]] && echo true || echo false)"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} verificação(ões) falharam (run ${RUN_ID})."
  echo "API: ${api_message}"
  echo "Web: ${web_message}"
  exit 1
fi
echo "Smoke test OK (run ${RUN_ID})."
