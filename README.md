# Graylog — logs centralizados do C:\Workspace

Graylog 7.2 + OpenSearch 3.7 + MongoDB 8.0 em Docker, **provisionado automaticamente**: inputs GELF, retenção,
pipeline de enriquecimento com mascaramento de dados pessoais, streams e alertas. Os projetos do workspace (a
começar pelo [legado](../legado)) enviam logs estruturados para cá. Decisões: [ADR-0001](docs/adr/0001-stack-graylog-opensearch.md).

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
| Inputs | **GELF TCP 12201** (aplicações, ex.: Serilog) e **GELF UDP 12201** (Docker logging driver) |
| Index set `Legado` | Prefixo `legado`, rotação otimizada por tempo, **retenção `LOG_RETENTION_DAYS` (30 dias)** |
| Pipeline `Legado - enriquecimento` | `service_name` a partir da `tag` do Docker; nível real de mensagens do stderr (o Docker marca todo stderr como erro) → campos `http_*` do access log JSON do nginx → 5xx = erro, 4xx = aviso → `level_name` legível e **mascaramento de e-mail e CPF** (LGPD) |
| Streams | `Legado - API`, `Legado - Web (nginx)`, `Legado - Infra`, `Legado - Erros` (level ≤ 3), `Legado - Navegador` (eventos do frontend), `Legado - Segurança` (login, logout, tokens recusados, rate limit) |
| Alertas | Erros na aplicação; erros no navegador; falhas de autenticação em massa (> 20 em 5 min); rate limit acionado; API lenta (> 10 requisições acima de 1 s); 5xx no nginx |

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
- Fora do Docker: GELF em `localhost:12201` (TCP ou UDP).

Veja a integração completa no `docker-compose.graylog.yml` do legado.

## Variáveis de ambiente (`.env`)

| Variável | Obrigatória | Para que serve |
|---|---|---|
| `GRAYLOG_PASSWORD_SECRET` | Sim | Segredo interno do Graylog (64+ caracteres aleatórios) |
| `GRAYLOG_ROOT_PASSWORD` | Sim | Senha do `admin` (UI/API e provisionamento) |
| `GRAYLOG_ROOT_PASSWORD_SHA2` | Sim | SHA-256 da senha acima (`printf '%s' "<senha>" \| sha256sum`) |
| `MONGODB_PASSWORD` | Sim | Senha do MongoDB (rede interna) |
| `GRAYLOG_TIMEZONE` | Não | Fuso da UI (padrão `America/Sao_Paulo`) |
| `LOG_RETENTION_DAYS` | Não | Retenção do index set do legado em dias (padrão 30) |
| `OPENSEARCH_HEAP` | Não | Heap da JVM do OpenSearch (padrão `1g`) |

O `scripts/generate-env.sh` preenche tudo. O `.env` está no `.gitignore`, e o [`.env.example`](.env.example) só
documenta as variáveis, sem nenhum valor.

## Teste (smoke test ponta a ponta)

```bash
docker compose run --rm -T -v "$PWD/scripts:/scripts:ro" --entrypoint /scripts/smoke-test.sh provisioner
```

Envia mensagens GELF reais (TCP como o Serilog, UDP como o Docker) e confere: ingestão, roteamento para os streams,
extração dos campos do nginx, `level_name` e **mascaramento de e-mail e CPF**.

## Segurança

- Portas publicadas só em `127.0.0.1` (UI 9000, GELF 12201). OpenSearch e MongoDB ficam só na rede interna.
- Segredos só no `.env`. A senha do admin chega ao Graylog apenas como SHA-256.
- Retenção limitada e mascaramento de dados pessoais no pipeline (LGPD), como defesa em profundidade. Os serviços
  continuam proibidos de logar dados pessoais (Art. IV.6).
- Uso **local/desenvolvimento**. Para produção, veja as ressalvas do ADR-0001 (TLS, Data Node/segurança do OpenSearch).
