# Tarefas — Spec 001 Pseudonimização pesquisável de dados pessoais nos logs

Legenda: `[P]` pode rodar em paralelo · cada tarefa = 1 PR pequeno no repositório indicado · testes **sempre**
inclusos (Art. V.1) · `[GL]` graylog · `[LG]` legado · `[CD]` cadastro · `[KC]` keycloak.

Todos os repositórios trabalham na branch local `DEV-004` (já com `origin/master` integrada).

Pré-condição do graylog: o debugger termina as correções em `provision.sh`, `smoke-test.sh` e regras antes de G01.

## Graylog

- [x] **G01** [GL] — Modelos LGPD aceitam máscara/token prontos e não corrompem textos · `backend-developer`
  - Depende de: debugger concluído
  - Arquivos: `provisioning/rules/templates/lgpd-{cpf,cnpj,phone,login}.rule.tmpl`, `scripts/smoke-test.sh`
  - Regras: valor já no formato de máscara → inalterado e sem troca nos textos; campos `*_token` nunca alterados;
    troca nos textos só quando a máscara gerada é válida; login/e-mail < 4 caracteres = fora do formato (ADR-0003 §10)
  - Testes inclusos (smoke): `Cpf=***.456.789-**` + `Cpf_token` preservados (idem CNPJ, telefone, login, e-mail);
    `UserName=ab` com `message` "tabela abc" → campo `***`, texto intacto; CPF de 10 dígitos → `***`
  - Pronto quando: provisioner 2x sem diff; smoke verde

- [x] **G02** [GL] — `provision.sh`: campos de texto, comentário do Cadastro, erro 400 e stream de auditoria · `backend-developer`
  - Depende de: G01 (mesmo smoke)
  - Arquivos: `provisioning/provision.sh`, `provisioning/rules/20-nginx-json.rule`, `scripts/smoke-test.sh`, `README.md`,
    `CLAUDE.md`, ADR-0002/0003 e `plan.md` (iguais ao código; o restante do README/CLAUDE.md é a G03)
  - Itens: `LGPD_TEXT_FIELDS` += `ClientSource`, `RequestPath`, `case_reference` e os campos de URL do nginx
    (levantar os `http_*` que o extractor cria a partir do `json_access`); comentário/descrição do stream
    `Cadastro - API` conforme a realidade (Serilog/GELF TCP após C01); `ensure_rule` imprime status e corpo do erro 400
    do Graylog; access log do `cadastro-web` na regra 20; stream `Cadastro - Pesquisa em logs (LGPD)` (`service_name:cadastro-api`,
    `audit_event` `log_search_query_issued` ou `log_search_access_denied` (403), exclui `log_source:browser`;
    índice do Cadastro); alertas (todos com `NOT smoke_test:true`): "mais de 10 pesquisas do mesmo investigador em 10 min" e
    "mais de 2 acessos negados do mesmo usuário em 10 min"
  - Testes inclusos (smoke): e-mail em `ClientSource`/`RequestPath`/`http_path` → `ana***@gmail`; evento de
    auditoria sintético cai no stream; regra inválida injetada mostra o corpo do 400 (teste do script)
  - Pronto quando: smoke cobre **cada formato e cada campo** citado nos ADR-0002/0003; provisioner 2x sem diff

- [x] **G03** [GL] — README e CLAUDE.md iguais ao que o smoke comprova · `backend-developer`
  - Depende de: G02
  - Arquivos: `README.md`, `CLAUDE.md` (preservar a nota `MSYS_NO_PATHCONV`)
  - Conteúdo: ADR-0003 (token na origem, Graylog só máscara), `*_token`, stream de auditoria, celular sem DDD fora do
    escopo, busca salva "campo LGPD sem token"; remover qualquer promessa sem caso no smoke
  - Testes: n/a (documentação) — cada afirmação aponta para o caso do smoke que a prova
  - Pronto quando: revisão do code-reviewer sem divergência

## Legado

- [x] **L01** [LG] — Enricher de pseudonimização no Serilog · `backend-developer`
  - Depende de: —
  - Arquivos: `Legado.Api/Common/Pseudonymization/*` (novo), `Common/LoggingSetup.cs`, user-secrets/`.env.example`
    (`Logging__Pseudonymization__CurrentKeyId`, `Logging__Pseudonymization__Keys__k1`), `README.md`, `CLAUDE.md`
    (regra do campo estruturado + `*_token`), `docs/adr/0003-logs-centralizados-graylog.md` (referência ao ADR-0003 do graylog)
  - Testes inclusos: unitários com os **vetores do plano §2**, canônicos, inválidos (`***`, sem token), e-mail = login,
    duas chaves (token com `CurrentKeyId`); integração: evento com `{Cpf}`, `{Phone}`, `{UserName}`, `{Email}` e
    exceção — nenhum campo GELF contém os valores de entrada; subida sem chave falha (fail fast)
  - Pronto quando: `dotnet build -warnaserror`, `dotnet test` e Quality Gate verdes

- [x] **L02** [LG] — Client-logs: máscara do ADR-0002 e `ClientSource` · `backend-developer`
  - Depende de: L01 (usa o masker)
  - Arquivos: `Legado.Api/ClientLogs/ClientLogEndpoints.cs` e testes
  - Itens: `***@***` → `ana***@gmail`; `ClientSource` sem query string/fragmento e mascarado; CPF/telefone no
    `ClientMessage`/`ClientStack` pelo masker
  - Testes inclusos: integração do endpoint com e-mail, CPF e telefone em `message`, `stack` e `source`
  - Pronto quando: build/testes/Quality Gate verdes

## Keycloak

- [x] **K01** [KC] — Role `log-investigator` com OTP obrigatório · `backend-developer`
  - Depende de: —
  - Arquivos: `realm/realm-workspace.json`, `provisioning/provision.sh`, `README.md`, `CLAUDE.md` (alinhar texto
    sobre `masked_login` do ADR-0007 com o ADR-0002/0003: keycloak não gera token)
  - Itens: role sem atribuição padrão; disponível ao client `cadastro`; OTP condicional também para a role
    (confirmar mecanismo do Keycloak 26 via Context7)
  - Testes inclusos: `WorkspaceRealmIT` (role existe, não está em `default-roles-workspace`, login com a role exige
    OTP); provisioner 2x sem diff
  - Pronto quando: `./scripts/build.sh` e `./scripts/smoke-test.sh` verdes

## Cadastro

- [x] **C01** [CD] — Envio de logs ao Graylog (Serilog + GELF TCP) · `backend-developer`
  - Depende de: —
  - Arquivos: `Directory.Packages.props` (`Serilog.AspNetCore`, `Serilog.Sinks.Graylog` nas versões do legado),
    `Cadastro.Api/Common/LoggingSetup.cs` (novo, padrão do legado), `Program.cs`, `docker-compose.yml` (rede
    `observability`), `README.md`, `CLAUDE.md` (remover a pendência "ainda não envia ao Graylog")
  - Testes inclusos: integração de configuração (sink presente, `service_name=cadastro-api`, `trace_id` no evento),
    fallback para console sem Graylog
  - Pronto quando: evento real aparece no stream `Cadastro - API`; build/testes/Quality Gate verdes

- [x] **C02** [CD] — Pseudonimização (porta, HMAC, enricher) e chave local · `backend-developer`
  - Depende de: C01
  - Arquivos: `Cadastro.Application/LogSearch/ILogPseudonymizer.cs`, `Cadastro.Infrastructure/Logging/LogPseudonymizer.cs`
    e `PseudonymizationOptions.cs`, `Cadastro.Api/Common/PseudonymizationEnricher.cs`, `LoggingSetup.cs`,
    `scripts/generate-env.sh` (gera `k1`), `.env.example`
  - Testes inclusos: os mesmos **vetores do plano §2** (tokens idênticos aos do legado), canônicos, inválidos, duas
    chaves, fail fast; integração GELF sem valores de entrada; `ArchitectureTests` verdes
  - Pronto quando: build/testes/Quality Gate verdes

- [x] **C03** [CD] — Endpoint `POST /api/v1/log-search/queries` com auditoria · `backend-developer`
  - Depende de: C02, K01
  - Arquivos: `Cadastro.Application/LogSearch/GetLogSearchQuery*.cs`, `LogSearchFields.cs`,
    `Cadastro.Api/LogSearch/LogSearchEndpoints.cs`, `BffAuthenticationSetup.cs` (policy `logs:investigate`),
    `RateLimitPolicies.cs` (`log-search`, 30/h por `sub`), OpenAPI
  - Contrato do log de auditoria (o stream do Graylog depende dele): campos snake_case `audit_event`, `investigator_id`,
    `data_type`, `case_reference`, `trace_id` e `tokens` como **texto único** (tokens separados por vírgula, nunca lista: o
    Cadastro usa `ParseArrayValues=true` e o sink dividiria a lista em `tokens_0`, `tokens_1`...); 403 usa
    `audit_event=log_search_access_denied` com `investigator_id`, mensagem própria e **sem** `tokens`, `data_type` nem `case_reference`
  - Testes inclusos: unitários do handler (validação por tipo, `caseReference`, OR de chaves e campos, e-mail e login
    com a mesma lista); integração: 200 com vetores, 400 sem eco do valor, 401, 403 registrado, 429, antiforgery;
    log de auditoria capturado sem o valor nem a máscara; teste que compara `LogSearchFields` com as listas do ADR-0002
  - Pronto quando: build/testes/Quality Gate verdes

- [x] **C04** [CD] — Tela "Pesquisa em logs" (`/log-search`) · `frontend-developer`
  - Depende de: C03
  - Arquivos: `cadastro-frontend/src/app/log-search/*`, `app.routes.ts` (guard de role), menu do usuário
  - Testes inclusos: Vitest (4 estados, validações, valor limpo após sucesso, nada em URL/`localStorage`/`AppLogger`);
    Playwright + axe nos 3 dispositivos; 403 para usuário sem a role
  - Pronto quando: **4 estados e microtextos da spec §3b**, verificação visual com zero defeitos na matriz
    mobile/tablet/desktop + varredura de redimensionamento (`frontend.md` §0/§3); lint/test/build verdes

- [x] **C05** [CD] — Client-logs: máscara do ADR-0002 e `ClientSource` · `backend-developer`
  - Depende de: C02
  - Arquivos: `Cadastro.Api/ClientLogs/ClientLogEndpoints.cs` e testes (não toca arquivos de C04/C06)
  - Mesmo escopo e testes de L02
  - Pronto quando: build/testes/Quality Gate verdes

- [x] **C06** [CD] — Script local `scripts/log-search-token.sh` (só dev) · `backend-developer`
  - Depende de: C02
  - Arquivos: `scripts/log-search-token.sh`, seção no `README.md` (inclui copiar a chave `k1` para o user-secrets do legado)
  - Testes inclusos: o script reproduz os vetores do plano §2 (`--self-test`); recusa rodar sem `.env`
  - Pronto quando: consulta gerada encontra no Graylog local um evento real do legado e um do cadastro para o mesmo CPF

## Fechamento

- [ ] **X01** [GL][LG][CD][KC] — Auditoria cruzada documentação × código · `code-reviewer` + `qa-engineer`
  - Depende de: todas as anteriores
  - Escopo: README, CLAUDE.md, ADRs (graylog docs/adr 0002/0003, legado 0003, keycloak doc/adr 0002/0007) e comentários nos 4 repos ×
    código, regras, smoke e testes. Cada afirmação sobre formato, campo, stream, fluxo ou garantia precisa de teste
    ou smoke que a prove; o resto é corrigido ou removido
  - QA: E2E ponta a ponta — mesmo CPF registrado no legado e no cadastro, consulta pela tela, os dois eventos
    encontrados; trilha de auditoria no stream; nenhum valor em claro (busca pelos valores de teste no Graylog = 0)
  - Pronto quando: relatório sem achado crítico/alto; divergências corrigidas em até 2 rodadas
  - Estado (2026-11-18): rodada documental concluída (commits 7806282 e 8c38ab5: README, CLAUDE.md, ADRs e smoke alinhados ao código).
    QA E2E executado na stack real e relatório em [x01-report.md](x01-report.md): consulta pela tela, trilha de auditoria e valores em claro = 0
    comprovados; sem achado crítico/alto. Pendente: o cenário "mesmo CPF nos dois sistemas" só foi feito com eventos GELF simulados, porque nenhum
    ponto de log de produção grava campo `{Cpf}`/telefone/login com token (achado M1); decidir o ponto de log real antes de marcar `[x]`

## Ondas (máx. 4 simultâneas; no máximo 1 tarefa por repositório por onda, salvo arquivos disjuntos declarados)

| Onda | Tarefas | Observação |
|---|---|---|
| 0 | (debugger no graylog) | G01 espera |
| 1 | **L01** [LG] · **C01** [CD] · **K01** [KC] · **G01** [GL] | Repositórios distintos |
| 2 | **L02** [LG] · **C02** [CD] · **G02** [GL] | |
| 3 | **C03** [CD] · **G03** [GL] | C03 precisa de K01 (onda 1) e C02 |
| 4 | **C04** (frontend) · **C05** (`ClientLogs/`) · **C06** (`scripts/`, README) | Mesmo repo, arquivos disjuntos; se preferir serializar: C04 → C05 → C06 |
| 5 | **X01** | code-reviewer + qa-engineer em paralelo |

Revisão (code-reviewer) e QA ao fim de cada onda, conforme `/dev-team`.
