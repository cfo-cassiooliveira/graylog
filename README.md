# Graylog — logs centralizados

Graylog 7.2 + OpenSearch 3.7 + MongoDB 8.0 em Docker, **provisionado automaticamente**: inputs GELF, retenção,
pipeline de enriquecimento com mascaramento de dados pessoais, streams e alertas. Os projetos do workspace (a
começar pelo [legado](../legado), o [sonarqube](../sonarqube) e o [keycloak](../keycloak)) enviam logs estruturados para cá. Decisões: [ADR-0001](docs/adr/0001-stack-graylog-opensearch.md).

## Como subir

Pré-requisito: Docker Desktop (≥ 4 GB de memória para o Docker).

```bash
./scripts/generate-env.sh      # cria o .env com segredos aleatórios (nunca versionado)
docker compose up -d --build   # sobe mongodb, opensearch, graylog e roda o provisionamento
```

Acesse **http://localhost:9000** com o usuário `admin` e a senha `GRAYLOG_ROOT_PASSWORD` do `.env`.
A primeira subida leva cerca de 1 a 2 minutos (o OpenSearch e o Graylog inicializam os índices).

## O que é provisionado (`provisioning/provision.sh`, idempotente)

| Item | Detalhe |
|---|---|
| Inputs | **GELF TCP 12201** (aplicações, ex.: Serilog), **GELF UDP 12201** (Docker logging driver) e **GELF HTTP 12202** (aplicações que precisam de confirmação: responde 202 ao gravar, ex.: auditoria do Keycloak com fallback) |
| Index set `Legado` | Prefixo `legado`, rotação otimizada por tempo, **retenção `LOG_RETENTION_DAYS` (30 dias)** |
| Index set `SonarQube` | Prefixo `sonarqube`, mesma retenção `LOG_RETENTION_DAYS` |
| Index set `Keycloak` | Prefixo `keycloak`, mesma retenção `LOG_RETENTION_DAYS` |
| Pipeline `Legado - enriquecimento` | `service_name` a partir da `tag` do Docker; nível real de mensagens do stderr (o Docker marca todo stderr como erro) e dos logs do SonarQube/PostgreSQL (nível lido do texto); JSON do servidor Keycloak vira `level`, `logger`, `thread` e texto; mensagens do listener padrão do Keycloak (`org.keycloak.events`, com username e IP) são descartadas (LGPD) → campos `http_*` do access log JSON do nginx → 5xx = erro, 4xx = aviso → `level_name` legível e **mascaramento parcial de dados pessoais** (LGPD, [ADR-0002](docs/adr/0002-mascaramento-parcial-lgpd.md)) |
| Streams | `Legado - API`, `Legado - Web (nginx)`, `Legado - Infra`, `Legado - Erros` (level ≤ 3), `Legado - Navegador` (eventos do frontend), `Legado - Segurança` (login, logout, tokens recusados, rate limit), `SonarQube - Infra` (servidor e PostgreSQL do SonarQube), `Keycloak - Auditoria` (logins, falhas e ações administrativas, com id técnico do usuário e sem dados pessoais), `Keycloak - Servidor` (servidor e PostgreSQL do Keycloak) |
| Alertas | Erros na aplicação; erros no navegador; falhas de autenticação em massa (> 20 em 5 min); rate limit acionado; API lenta (> 10 requisições acima de 1 s); 5xx no nginx; erros no SonarQube; Keycloak: falhas de login em massa (> 20 em 5 min), auditoria salva no fallback (Graylog ficou indisponível) e erros no servidor |

### Mascaramento de dados pessoais (LGPD)

Os dados são mascarados **na gravação**: o valor original nunca chega ao índice. Decisão e alternativas no
[ADR-0002](docs/adr/0002-mascaramento-parcial-lgpd.md).

| Dado | Exemplo | Gravado como |
|---|---|---|
| E-mail | `ana.souza@gmail.com` | `ana***@gmail` |
| Login (campos de login) | `Maria.Silva` | `mar***` |
| CPF | `123.456.789-09` | `***.456.789-**` |
| CNPJ (inclusive alfanumérico) | `12.345.678/0001-90` | `12.3**.***/***1-90` |
| Celular | `(11) 98765-4321` | `11*****4321` |

**Regra para quem envia log:** dado pessoal, quando inevitável, vai **só como campo estruturado** com o nome do tipo.
No Serilog é o message template, nunca o texto concatenado:

```csharp
// Certo: o valor vai no campo Cpf/Phone e no texto; o Graylog mascara os dois pelo tipo do campo.
logger.LogWarning("Cadastro recusado para CPF {Cpf} e celular {Phone}", cpf, phone);
// Errado: o Graylog só vê texto e precisa adivinhar ("11987654321" viraria CPF).
logger.LogWarning($"Cadastro recusado para CPF {cpf} e celular {phone}");
```

| Tipo | Nomes de campo (listas do `provision.sh`) |
|---|---|
| CPF | `Cpf`, `cpf`, `CPF` (`LGPD_CPF_FIELDS`) |
| CNPJ | `Cnpj`, `cnpj`, `CNPJ` (`LGPD_CNPJ_FIELDS`) |
| Telefone | `Phone`, `MobilePhone`, `phone`, `mobilePhone`, `celular`, `telefone`... (`LGPD_PHONE_FIELDS`) |
| Login ou e-mail | `UserName`, `Email`, `username`, `login`, `email`, `preferred_username`... (`LGPD_LOGIN_FIELDS`) |

O pipeline trabalha em duas camadas, com regras geradas uma por campo dos modelos em
[`provisioning/rules/templates/`](provisioning/rules/templates):
1. **Pelo campo (estágio 3).** Mascara o campo pelo tipo e troca o mesmo valor em todos os textos, sem adivinhar.
2. **Pelo formato (estágio 4, rede de segurança).** Reconhece o que vazou sem campo nos textos (`LGPD_TEXT_FIELDS`:
   `message`, `full_message`, `ExceptionMessage`, `StackTrace`, `http_path`...).

Nome de campo novo entra na lista do seu tipo.

As regras de pipeline ficam em [`provisioning/rules/`](provisioning/rules). Para alterar, edite o `.rule` e rode
`docker compose run --rm provisioner`; a regra é atualizada no Graylog. Regras de **streams** e consultas/limiares de
**alertas** também são sincronizadas com o script a cada execução (o script é a fonte da verdade).
Eventos vindos do navegador (`log_source:browser`, endpoint anônimo e forjável) nunca entram no stream de Segurança
nem nos alertas de backend.

## Como um projeto envia logs

- **Aplicação (.NET/Serilog)**: GELF **TCP** para `graylog:12201`, entrando na rede Docker externa `observability`.
  Envie o campo `service_name` (ex.: `legado-api`).
- **Containers (stdout)**: Docker logging driver `gelf` com `gelf-address: udp://127.0.0.1:12201` (não `localhost`, que o daemon resolve para IPv6) e `tag: <serviço>`.
  O pipeline transforma a `tag` em `service_name`.
- **Com confirmação de gravação**: GELF **HTTP** em `http://graylog:12202/gelf` (status 202). Veja o `docker-compose.graylog.yml` do keycloak.
- Fora do Docker: GELF em `localhost:12201` (TCP ou UDP) ou `http://localhost:12202/gelf` (HTTP).

Veja a integração completa no `docker-compose.graylog.yml` do legado.

## Variáveis de ambiente (`.env`)

| Variável | Obrigatória | Para que serve |
|---|---|---|
| `GRAYLOG_PASSWORD_SECRET` | Sim | Segredo interno do Graylog (64+ caracteres aleatórios) |
| `GRAYLOG_ROOT_PASSWORD` | Sim | Senha do `admin` (UI/API e provisionamento) |
| `GRAYLOG_ROOT_PASSWORD_SHA2` | Sim | SHA-256 da senha acima (`printf '%s' "<senha>" \| sha256sum`) |
| `MONGODB_PASSWORD` | Sim | Senha do MongoDB (rede interna) |
| `GRAYLOG_TIMEZONE` | Não | Fuso da UI (padrão `America/Sao_Paulo`) |
| `LOG_RETENTION_DAYS` | Não | Retenção dos index sets (legado, SonarQube e Keycloak) em dias (padrão 30) |
| `OPENSEARCH_HEAP` | Não | Heap da JVM do OpenSearch (padrão `1g`) |

O `scripts/generate-env.sh` preenche tudo. O `.env` está no `.gitignore`, e o [`.env.example`](.env.example) só
documenta as variáveis, sem nenhum valor.

## Teste (smoke test ponta a ponta)

```bash
docker compose run --rm -T -v "$PWD/scripts:/scripts:ro" --entrypoint /scripts/smoke-test.sh provisioner
```

Envia mensagens GELF reais (TCP como o Serilog, UDP como o Docker) e confere: ingestão, roteamento para os streams,
extração dos campos do nginx, `level_name` e o **mascaramento LGPD** de cada formato (e-mail, login, CPF, CNPJ e
celular) no `message`, no `full_message` e nos campos da exceção.

## Segurança

- Portas publicadas só em `127.0.0.1` (UI 9000, GELF 12201 e 12202). OpenSearch e MongoDB ficam só na rede interna.
- Segredos só no `.env`. A senha do admin chega ao Graylog apenas como SHA-256.
- Retenção limitada e mascaramento parcial de dados pessoais na gravação (LGPD), como defesa em profundidade. Dado
  mascarado parcialmente ainda é dado pessoal: o acesso ao Graylog continua restrito. Os serviços
  continuam proibidos de logar dados pessoais (Art. IV.6).
- Uso **local/desenvolvimento**. Para produção, veja as ressalvas do ADR-0001 (TLS, Data Node/segurança do OpenSearch).
