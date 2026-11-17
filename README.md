# Graylog — logs centralizados

Graylog 7.2 + OpenSearch 3.7 + MongoDB 8.0 em Docker, **provisionado automaticamente**: inputs GELF, retenção,
pipeline de enriquecimento com mascaramento de dados pessoais, streams e alertas. Os projetos do workspace (a
começar pelo [legado](../legado), o [cadastro](../cadastro), o [sonarqube](../sonarqube) e o [keycloak](../keycloak)) enviam logs estruturados para cá. Decisões: [ADR-0001](docs/adr/0001-stack-graylog-opensearch.md).

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
| Index set `Legado` | Prefixo `legado`, rotação otimizada por tempo, **retenção `LOG_RETENTION_DAYS`: no mínimo 30 dias, apagado até 5 dias depois (30 a 35 dias)** |
| Index set `SonarQube` | Prefixo `sonarqube`, mesma retenção `LOG_RETENTION_DAYS` |
| Index set `Keycloak` | Prefixo `keycloak`, mesma retenção `LOG_RETENTION_DAYS` |
| Index set `Cadastro` | Prefixo `cadastro`, mesma retenção `LOG_RETENTION_DAYS` (inclui a trilha de pesquisas em logs) |
| Pipeline `Legado - enriquecimento` | `service_name` a partir da `tag` do Docker; nível real de mensagens do stderr (o Docker marca todo stderr como erro) e dos logs do SonarQube/PostgreSQL (nível lido do texto); JSON do servidor Keycloak vira `level`, `logger`, `thread` e texto; mensagens do listener padrão do Keycloak (`org.keycloak.events`, com username e IP) são descartadas (LGPD) → campos `http_*` do access log JSON do nginx (`legado-web` e `cadastro-web`) → 5xx = erro, 4xx = aviso → `level_name` legível e **mascaramento parcial de dados pessoais** (LGPD, [ADR-0002](docs/adr/0002-mascaramento-parcial-lgpd.md)) |
| Streams | `Legado - API`, `Legado - Web (nginx)`, `Legado - Infra`, `Legado - Erros` (level ≤ 3), `Legado - Navegador` (eventos do frontend), `Legado - Segurança` (login, logout, tokens recusados, rate limit), `SonarQube - Infra` (servidor e PostgreSQL do SonarQube), `Keycloak - Auditoria` (logins, falhas e ações administrativas, com id técnico do usuário e sem dados pessoais), `Keycloak - Servidor` (servidor e PostgreSQL do Keycloak), `Identidade - Migração`, `Cadastro - API`, `Cadastro - Web (nginx)`, `Cadastro - Erros`, `Cadastro - Navegador`, `Cadastro - Segurança` e `Cadastro - Pesquisa em logs (LGPD)` (trilha de auditoria da pesquisa por token, [ADR-0003](docs/adr/0003-pseudonimizacao-hmac-pesquisavel.md): `audit_event` `log_search_query_issued` ou `log_search_access_denied` (403), com `investigator_id`, `data_type`, `case_reference` e `tokens` (texto único), nunca o valor pesquisado; eventos do navegador ficam fora) |
| Alertas | Erros na aplicação; erros no navegador; falhas de autenticação em massa (> 20 em 5 min); rate limit acionado; `Legado - Assinatura interna recusada`; API lenta (> 10 requisições acima de 1 s); 5xx no nginx (legado e Cadastro); erros no SonarQube; Keycloak: falhas de login em massa (> 20 em 5 min), auditoria salva no fallback (Graylog ficou indisponível) e erros no servidor; `Identidade - Tentativas de migração inválidas`, `Identidade - Legado indisponível` e `Identidade - Falha ao marcar migração`; Cadastro: erros na aplicação e no navegador, excesso de pesquisas em logs (> 10 do mesmo investigador em 10 min) e acessos negados à pesquisa (> 2 do mesmo usuário em 10 min) |

### Mascaramento de dados pessoais (LGPD)

Os dados são mascarados **na gravação**, nos campos tratados (os das listas `LGPD_*` e os textos de
`LGPD_TEXT_FIELDS`): campo fora das listas ou formato não previsto passa como chegou. Decisão e alternativas no
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
| Login ou e-mail | `UserName`, `Email`, `username`, `login`, `email`, `preferred_username`, `masked_login`... (`LGPD_LOGIN_FIELDS`) |

### Tokens e pesquisa por titular ([ADR-0003](docs/adr/0003-pseudonimizacao-hmac-pesquisavel.md))

O token (`k<id>-<hex>`, HMAC) é gerado **na origem**: o Graylog nunca vê a chave nem o valor em claro, só aplica a
máscara e a rede de segurança. Cada campo LGPD que chega pseudonimizado vem com `<Campo>_token` (`Cpf_token`,
`Email_token`...), e ambos passam intactos (smoke: "origem pseudonimizada: campos *_token preservados"). Objeto
aninhado vira `Obj_Campo` (GELF `_Obj.Campo`) e o token, propriedade de topo `Obj_Campo_token` (smoke: "campo aninhado
gravado como Obj_Cpf ... e Obj_Cpf_token").

Para pesquisar um titular, use a consulta gerada pelo Cadastro e cole na busca do Graylog, por exemplo
`Cpf_token:"k1-b81c27bb5f38080e6ca0ed38b828f262"` (smoke: "Pesquisa por token"). A pesquisa fica registrada no
stream `Cadastro - Pesquisa em logs (LGPD)` e os alertas de excesso e de negação vigiam o uso (smoke: casos
"Auditoria:" e "alerta de excesso..."/"alerta de acessos negados..."). Evento com campo LGPD sem `*_token` é defeito
da origem (fica só mascarado); **não há busca salva para isso**, e essa detecção não é coberta pelo smoke.

O pipeline trabalha em duas camadas, com regras geradas uma por campo dos modelos em
[`provisioning/rules/templates/`](provisioning/rules/templates):
1. **Pelo campo (estágio 3).** Mascara o campo pelo tipo e troca o mesmo valor em todos os textos, sem adivinhar.
   Valor fora do formato vira `***` no campo e nos textos (ex.: celular sem DDD `98765-4321`); só o valor curto
   (login/e-mail com menos de 4 caracteres, CPF/telefone com menos de 8 dígitos e CNPJ com menos de 8 caracteres alfanuméricos no Graylog (na origem a contagem é só de dígitos, ADR-0003 item 10)) não é trocado nos textos, para
   um login como `api` não corromper `Legado.Api` ou `/api/v1`. Na origem (legado e cadastro) a regra do texto é outra: CPF, CNPJ e telefone inválidos com 8 ou mais dígitos viram `***` no texto, e login ou e-mail inválido, de qualquer tamanho, não é trocado no texto (só o campo vira `***`); o Graylog troca o login inválido com 4 ou mais caracteres (ADR-0003 item 10). Valor que já chega mascarado da
   origem (ADR-0003) e os campos `<Campo>_token` ficam como estão.
2. **Pelo formato (estágio 4, rede de segurança).** Reconhece o que vazou sem campo nos textos (`LGPD_TEXT_FIELDS`:
   `message`, `full_message`, `ExceptionMessage`, `StackTrace`, `RequestPath`, `ClientMessage`, `ClientStack`,
   `ClientSource`, `case_reference` e `http_path`, o único campo de URL do access log do nginx). Inclui e-mail em URL
   (`%40`) e celular com `+55`. Celular sem DDD: no texto só por troca do valor do campo (smoke: "fora do formato ... celular sem DDD trocados por *** no texto"); sem campo, fica fora do escopo (ADR-0003, item 9).

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

## Ordem com os demais projetos

O Graylog é opcional e sobe **primeiro** (ele cria a rede `observability`); nenhum projeto depende dele para funcionar.
Com ele no ar, suba os outros **sempre com o override do Graylog**: `../legado` (`-f docker-compose.yml -f
docker-compose.identity.yml -f docker-compose.graylog.yml`, depois de `./scripts/internal-credentials.sh`), `../keycloak`
(`-f docker-compose.yml -f docker-compose.graylog.yml`) e `../cadastro` (`-f docker-compose.yml -f
docker-compose.graylog.yml`). A rede `workspace-identity` é criada por `./scripts/identity-network.sh` (igual em cada
projeto); detalhes no README do `../keycloak`.

**Migração do Legado**: a auditoria do Keycloak chega pelo GELF HTTP (12202) e o stream `Identidade - Migração` reúne
`LEGACY_*` e `RESET_UNKNOWN_USER`. Só esses eventos trazem `masked_login` (ADR-0007 do keycloak, ex.: `ana***@gmail`),
sem `_token`; o nome está em `LGPD_LOGIN_FIELDS` e o valor, já mascarado, passa intacto. Nunca adicione outro campo de
login/e-mail do Keycloak sem ADR. O E2E do `../cadastro` confere que nenhum e-mail completo aparece nesses streams.

Limitação conhecida: não rode o `provisioner` ou o smoke do Graylog junto com o provisionamento/smoke do `../keycloak`
(falha intermitente nos fluxos do Keycloak, causa não comprovada); espere um terminar antes de iniciar o outro.

## Variáveis de ambiente (`.env`)

| Variável | Obrigatória | Para que serve |
|---|---|---|
| `GRAYLOG_PASSWORD_SECRET` | Sim | Segredo interno do Graylog (64+ caracteres aleatórios) |
| `GRAYLOG_ROOT_PASSWORD` | Sim | Senha do `admin` (UI/API e provisionamento) |
| `GRAYLOG_ROOT_PASSWORD_SHA2` | Sim | SHA-256 da senha acima (`printf '%s' "<senha>" \| sha256sum`) |
| `MONGODB_PASSWORD` | Sim | Senha do MongoDB (rede interna) |
| `GRAYLOG_TIMEZONE` | Não | Fuso da UI (padrão `America/Sao_Paulo`) |
| `LOG_RETENTION_DAYS` | Não | Retenção dos index sets (legado, SonarQube, Keycloak e Cadastro) em dias (padrão 30) |
| `OPENSEARCH_HEAP` | Não | Heap da JVM do OpenSearch (padrão `1g`) |

O `scripts/generate-env.sh` preenche tudo. O `.env` está no `.gitignore`, e o [`.env.example`](.env.example) só
documenta as variáveis, sem nenhum valor.

## Teste (smoke test ponta a ponta)

```bash
docker compose run --rm -T -v "$PWD/scripts:/scripts:ro" --entrypoint /scripts/smoke-test.sh provisioner
```

No Git Bash (Windows), prefixe com `MSYS_NO_PATHCONV=1`: sem isso o `--entrypoint /scripts/...` vira um caminho do
Windows e o container falha com `exec: "C:/Program": stat C:/Program: no such file or directory`.

Envia mensagens GELF reais (TCP como o Serilog, UDP como o Docker) e confere: ingestão, roteamento para os streams,
extração dos campos do nginx (legado e Cadastro), `level_name`, a trilha de pesquisas em logs e o **mascaramento
LGPD** de cada formato (e-mail, inclusive `%40`; login; CPF; CNPJ; celular, inclusive `+55`) pelo campo estruturado
(`UserName`, `Cpf`, `Cnpj`, `Phone`, `Email`...) e em cada campo de texto de `LGPD_TEXT_FIELDS`; máscara e token prontos
da origem preservados (inclusive campo aninhado `Obj_Campo`); a pesquisa por `<Campo>_token`; valor curto sem corromper texto; nenhum campo de texto vazio criado. Também carrega o
`provision.sh` sem executá-lo e confere que o erro 400 do Graylog aparece e que nome de campo inválido é recusado.

## Segurança

- Portas publicadas só em `127.0.0.1` (UI 9000, GELF 12201 e 12202). OpenSearch e MongoDB ficam só na rede interna.
- Segredos só no `.env`. A senha do admin chega ao Graylog apenas como SHA-256.
- A trilha de auditoria da pesquisa em logs depende de inputs GELF que não autenticam o remetente: quem alcança a rede
  pode forjar eventos nela. Em produção, input com TLS + mTLS e rede dedicada (ADR-0003, item 7).
- Retenção limitada e mascaramento parcial de dados pessoais na gravação (LGPD), como defesa em profundidade. Dado
  mascarado parcialmente ainda é dado pessoal: o acesso ao Graylog continua restrito. Os serviços
  continuam proibidos de logar dados pessoais (Art. IV.6).
- Uso **local/desenvolvimento**. Para produção, veja as ressalvas do ADR-0001 (TLS, Data Node/segurança do OpenSearch).
