# Graylog — infraestrutura de logs

> Herda a Constituição (`C:\Workspace\CLAUDE.md`) e o steering (`C:\Workspace\.claude\rules\`), em especial
> `observability.md`. Projeto de infraestrutura (sem código de aplicação): aplicam-se Art. IV, VI, X e XI.

## Propósito

Graylog local em Docker para receber os logs GELF dos projetos do workspace, com configuração como código.

## Estrutura

```
docker-compose.yml        mongodb, opensearch, graylog, provisioner; rede externa "observability"
provisioning/provision.sh provisionamento idempotente via API REST (inputs, index set, pipeline, streams, alertas)
provisioning/rules/       regras de pipeline versionadas (*.rule)
provisioning/rules/templates/  modelos das regras LGPD (uma regra gerada por campo das listas LGPD_* do provision.sh)
scripts/generate-env.sh   gera o .env com segredos aleatórios
scripts/smoke-test.sh     teste ponta a ponta (ingestão, streams, pipeline, mascaramento LGPD)
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
- **Regra para quem envia log**: dado pessoal, quando inevitável, chega **só como campo estruturado** com o nome do
  tipo (`Cpf`, `Cnpj`, `Phone`/`MobilePhone`, `UserName`, `Email`; listas `LGPD_CPF_FIELDS`, `LGPD_CNPJ_FIELDS`,
  `LGPD_PHONE_FIELDS` e `LGPD_LOGIN_FIELDS`). O pipeline mascara pelo nome do campo e troca o mesmo valor nos textos,
  sem adivinhar. O reconhecimento por formato nos textos (`LGPD_TEXT_FIELDS`) é só rede de segurança. Nome de campo
  novo entra na lista do tipo; formato novo muda o modelo em `rules/templates/`. Os dois ganham caso no smoke test.
- API do Graylog 7: criação de stream e de alerta usa o corpo `{"entity": {...}}`; `lbstatus` responde text/plain.
- Novo sistema → novos streams e alertas no `provision.sh`, com `service_name` próprio e retenção definida (LGPD).
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
```
