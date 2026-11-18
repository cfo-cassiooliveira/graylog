# Resumo — Spec 001 Pseudonimização pesquisável de dados pessoais nos logs

**Status da spec**: Aprovada (2026-11-14). Abrange 4 repositórios: graylog, legado, cadastro, keycloak.

## Objetivo
Nenhum dado pessoal em claro no caminho do log, com pesquisa exata por titular feita por pessoa autorizada e auditada, e
documentação igual ao código.

## Decisões-chave
- ADR-0002: máscara parcial no Graylog (pipeline) como rede de segurança (CPF `***.456.789-**`, e-mail `ana***@gmail`).
- ADR-0003: token HMAC-SHA256 pesquisável gerado **na origem** (legado/cadastro); Graylog só mascara e aceita valores prontos.
  `token = "k"+id+"-"+hex(HMAC(key, domínio|canônico))[0..32]`; domínios `cpf`, `cnpj`, `phone`, `login`
  (e-mail = login). Valor fora do formato vira `***`, sem token. Chave fora do repo; ausente = fail fast.

## Contratos e interfaces
- GELF: campo mascarado + `<Campo>_token` (ex.: `Cpf_token`); busca `Cpf_token:"<token>"`.
- Cadastro: `POST /api/v1/log-search/queries` (role `log-investigator` com OTP, policy `logs:investigate`, rate limit 30/h por
  `sub`), `GET /api/v1/log-search/access` (403 registrado); tela `/log-search`.
- Auditoria (stream "Cadastro - Pesquisa em logs (LGPD)"): `audit_event` = `log_search_query_issued` | `log_search_access_denied`,
  `investigator_id`, `data_type`, `case_reference`, `trace_id`, `tokens` (texto único, separado por vírgula). Alertas: >10
  pesquisas/10 min por investigador; >2 acessos negados/10 min por usuário.

## Estado das tarefas (tasks.md × git)
- Concluídas `[x]`: G01-G03, L01, L02, K01, C01-C06, X01.
- X01: rodada documental (commits 7806282 e 8c38ab5) e E2E real em 2026-11-18 ([x01-report.md](x01-report.md)): mesmo login/e-mail nos dois
  serviços por fluxo de aplicação, pesquisa pela tela, trilha de auditoria e valores em claro = 0; sem achado crítico/alto.

## Links
[spec.md](spec.md) · [plan.md](plan.md) · [tasks.md](tasks.md)
