> Índice de docs (specs, ADRs, comandos): [docs/INDEX.md](docs/INDEX.md)

# Graylog — infraestrutura de logs

> Herda a Constituição (`C:\Workspace\CLAUDE.md`) e o steering (`C:\Workspace\.claude\rules\`), em especial
> `observability.md`. Projeto de infraestrutura (sem código de aplicação): aplicam-se Art. IV, VI, X e XI.

## Propósito

Graylog local em Docker para receber os logs GELF dos projetos do workspace, com configuração como código.

## Estrutura

```
docker-compose.yml        mongodb, opensearch, graylog, provisioner; rede externa "observability"; rede "logs-read" (só OpenSearch + leitores)
provisioning/provision.sh provisionamento idempotente via API REST (inputs, index set, pipeline, streams, alertas)
provisioning/rules/       regras de pipeline versionadas (*.rule)
provisioning/rules/templates/  modelos das regras LGPD (uma regra gerada por campo das listas LGPD_* do provision.sh)
scripts/generate-env.sh   gera o .env com segredos aleatórios
scripts/smoke-test.sh     teste ponta a ponta (ingestão, streams, pipeline, mascaramento LGPD, auditoria; carrega o
                          provision.sh com "source", que só define as funções, para testar o próprio script)
scripts/smoke-network.sh   teste (no host) de que o OpenSearch só é alcançável por "logs-read"
docs/adr/                 decisões
```

## Regras deste projeto

- Imagens fixadas por **tag + digest**; respeite a matriz de compatibilidade do Graylog ao atualizar.
- Toda configuração do Graylog entra pelo `provision.sh` (nunca só pela UI): ele cria e **sincroniza** regras de
  pipeline, regras de streams e alertas. Cada mudança roda o smoke test.
- Eventos `log_source:browser` são forjáveis (endpoint anônimo): nunca na trilha de Segurança nem em alertas de backend.
- Inputs GELF (inclusive o HTTP 12202) não autenticam o remetente: no ambiente local qualquer container da rede
  `observability` poderia forjar auditoria. Em produção, input com TLS + autenticação de cliente (mTLS) e rede dedicada.
- Dados pessoais vindos de logs de terceiros são barrados no pipeline (ex.: logger `org.keycloak.events`), com caso no
  smoke test provando o descarte.
- Dados pessoais são mascarados **na gravação**, nunca só na exibição (ADR-0002): `ana***@gmail`, `mar***`,
  `***.456.789-**`, `12.3**.***/***1-90`, `11*****4321`.
- **Regra para quem envia log**: nenhum dado pessoal em log (Constituição, Art. IV.6). Exceção só com ADR aprovado,
  e o dado chega **pseudonimizado na origem** (máscara + `<Campo>_token`, ADR-0003) e **só como campo estruturado**
  com o nome do tipo (`Cpf`, `Cnpj`, `Phone`/`MobilePhone`, `UserName`, `Email`; listas `LGPD_CPF_FIELDS`, `LGPD_CNPJ_FIELDS`,
  `LGPD_PHONE_FIELDS` e `LGPD_LOGIN_FIELDS`). O pipeline mascara pelo nome do campo e troca o mesmo valor nos textos,
  sem adivinhar; valor fora do formato vira `***` no campo e nos textos, exceto o curto (login < 4 caracteres,
  CPF/telefone < 8 dígitos, CNPJ < 8 caracteres alfanuméricos no Graylog, 8 dígitos na origem), que não é trocado nos textos; na origem, login/e-mail inválido de qualquer tamanho também não é trocado no texto (ADR-0003 item 10); máscara pronta da origem e `<Campo>_token` ficam
  como estão (ADR-0003). O reconhecimento por formato nos textos (`LGPD_TEXT_FIELDS`) é só rede de segurança. Nome
  de campo novo entra na lista do tipo; formato novo muda o modelo em `rules/templates/`. Os dois ganham caso no
  smoke test.
- API do Graylog 7: criação de stream e de alerta usa o corpo `{"entity": {...}}`; `lbstatus` responde text/plain.
- Novo sistema → novos streams e alertas no `provision.sh`, com `service_name` próprio e retenção definida (LGPD).
- Token na origem (ADR-0003): `<Campo>_token` e `Obj_Campo_token` (aninhado: GELF `_Obj.Campo` é gravado `Obj_Campo`) passam
  intactos; a pesquisa é por `Cpf_token:"<token>"` (smoke: "campo aninhado gravado", "Pesquisa por token"). Não há busca
  salva "campo LGPD sem token" (não implementada nem coberta). Celular sem DDD: no texto só por troca do valor do campo (smoke "fora do formato"); sem campo, fora do escopo (ADR-0003
  item 9).
- Trilha de pesquisas em logs (ADR-0003): stream `Cadastro - Pesquisa em logs (LGPD)` só com `service_name:cadastro-api`
  e `audit_event` `log_search_query_issued`/`log_search_access_denied`, nunca `log_source:browser`.
- `masked_login` (Keycloak, ADR-0007 do keycloak, aceito): fica em `LGPD_LOGIN_FIELDS` e só os seis tipos do ADR-0007
  (`LEGACY_USER_NOT_FOUND`, `LEGACY_PASSWORD_MISMATCH`, `LEGACY_ACCOUNT_LOCKED`, `LEGACY_ALREADY_MIGRATED`,
  `RESET_UNKNOWN_USER`, `LEGACY_UNAVAILABLE`) o enviam, já mascarado (o valor passa intacto quando tem a forma `abc***`, `a***` (1 a 3 caracteres antes de `***`) ou `x***@dominio`; valor em claro é mascarado como qualquer login) e sem `_token`; o stream `Identidade - Migração` e seus 3 alertas dependem
  do campo `type`. Retirar o nome da lista ou aceitar outro campo de login do Keycloak exige ADR e caso no smoke.
- Rede `logs-read` (ADR-0001 do `../grafana`): o OpenSearch (sem security plugin) entra nela com alias `opensearch` e só leitores
  autorizados (hoje o `opensearch-proxy` somente leitura do Grafana, ADR-0004 do `../grafana`) se juntam com `external: true`. Nunca ponha o OpenSearch na `observability` nem publique a porta
  9200 no host; `scripts/smoke-network.sh` prova isso. Produção: security plugin + usuário somente leitura.
- Nível dos logs de texto (`16-text-level-from-content.rule`): o Docker marca todo stderr como level 3; para `sonarqube`, `sonarqube-db` e `keycloak-db` o nível real vem do texto (`LOG:`/`INFO` informativo, `WARNING` aviso, `ERROR`/`FATAL`/`PANIC` erro). Tag nova de PostgreSQL entra no regex da regra e ganha caso no smoke.
- Grafana (`../grafana`): logs JSON do stdout com `tag: grafana`; a regra `19-grafana-json.rule` extrai só `level`, `logger` e `msg`
  e descarta os demais pares (e-mail/login de operador não são indexados; o texto passa pelo mascaramento LGPD). Stream
  `Grafana - Infra` e index set `Grafana` (mesma retenção). Campo novo do JSON do Grafana nunca vira campo sem ADR.
- RabbitMQ (`../rabbitmq`, ADR-0004): Fluent Bit → GELF TCP com só `time`, `level` (numérico na origem), texto e
  `service_name`/`tag` `rabbitmq`; sem regra de pipeline própria. Stream `RabbitMQ - Infra`, index set `RabbitMQ` (mesma
  retenção) e alertas `RabbitMQ - Erros no broker` (5+ `level<=3` em 5 min, sem `invalid credentials`) e `RabbitMQ -
  Falhas de login em massa` (> 20 `failed to authenticate` em 5 min: 1 linha por tentativa; `invalid credentials` vem 2x).
  A regra 15 não age na tag `rabbitmq`. Usuário do broker no texto **não** é mascarado (risco residual aceito, ADR-0004) (e-mail/CPF no
  texto caem na rede de segurança do `message`). Campo novo do coletor exige revisão do ADR-0004 e caso no smoke.
- Não rode o provisioner/smoke daqui ao mesmo tempo que o do `../keycloak` (falha intermitente `Parent flow doesn't exist`
  no Keycloak, causa não comprovada). O Graylog sobe antes dos demais; os projetos que o usam entram com o
  `docker-compose.graylog.yml` deles (ordem no README do `../keycloak`).
- **Idioma (Art. I)**: títulos e descrições de streams, alertas, pipelines e regras são texto de interface → **PT-BR**
  (idioma do produto, Art. I.3), padrão `<Sistema> - <Assunto>` (ex.: `Legado - Segurança`). Nomes de campos
  (`service_name`, `log_source`, `http_*`), valores de `tag` e mensagens de log do provisionamento → **inglês**.
- Mensagens sintéticas de teste levam `_smoke_test: "true"` (texto: o GELF descarta booleanos) e todo alerta
  começa com `NOT smoke_test:true`.

## Comandos

```bash
./scripts/generate-env.sh && docker compose up -d --build
docker compose run --rm provisioner                       # reaplica o provisionamento
docker compose run --rm -T -v "$PWD/scripts:/scripts:ro" --entrypoint /scripts/smoke-test.sh provisioner
# Git Bash (Windows): prefixe com MSYS_NO_PATHCONV=1 (senão o entrypoint vira "C:/Program Files/Git/scripts/...")
```

## Grafana

O `../grafana` lê os logs daqui (rede `logs-read`, só pelo proxy somente leitura) e envia os seus por GELF; ordem de subida, testes e limitações em `../grafana/README.md`.
