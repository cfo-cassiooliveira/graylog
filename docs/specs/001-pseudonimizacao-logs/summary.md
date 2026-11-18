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
- Concluídas `[x]`: G01-G03, L01, L02, K01, C01-C06.
- Pendente `[ ]`: X01 (auditoria cruzada final).
- **Divergência**: o git indica X01 já feita no graylog (commits 7806282 "fecha a auditoria cruzada e amplia o smoke",
  62e6f10, 9f10d4d; PR #7 da DEV-004 mesclado), mas tasks.md mantém X01 sem marcar. Outros 3 repos não verificados; tasks.md não alterado.

## Links
[spec.md](spec.md) · [plan.md](plan.md) · [tasks.md](tasks.md)
