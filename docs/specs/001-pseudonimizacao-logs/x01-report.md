# X01 — Relatório de QA E2E (2026-11-18, rodada 2)

Stack real no ar (graylog, keycloak, legado, cadastro, todos com o override do Graylog), código do M1 (branch DEV-010). **Sem GELF simulado.**
Spec versionável e repetível: `cadastro/e2e/tests/zz-x01-log-search.spec.js` (`./scripts/e2e.sh --project=desktop zz-x01`). Dados fictícios
(`x01qa<epoch>`, `@exemplo.com`, celular `119` + 8 dígitos). Resultado: 1 teste, **passou** (1,3 min).

## Verificado por fluxo real
| Etapa | Resultado |
|---|---|
| Cadastro + login no Legado (API) e login no Cadastro (migração sob demanda no Keycloak, mesma senha) | OK; eventos `signed in`/`registered` reais com `UserName`/`Email`/`MobilePhone` mascarados (`x01***`) + `*_token` |
| Investigador (`log-investigator`, OTP, step-up com espera do próximo passo TOTP) na tela `/log-search` | OK; a tela não mostra o valor |
| Consulta por token do login | eventos de `legado-api` (≥ 2: registro e login) e `cadastro-api` |
| Consulta por e-mail / celular | só `legado-api` (e-mail: nenhum `cadastro-api`), todos com `Email_token`/`MobilePhone_token` |
| Trilha de auditoria | 3 × `log_search_query_issued` (`data_type` login, email, phone) com `investigator_id` = sub e `case_reference`, sem valor |
| Valores em claro | login, e-mail, celular, senha do usuário e do investigador: 0 ocorrências em todas as mensagens do período (todos os streams/campos) e 0 resultados nas buscas de texto |
| Limpeza | usuários apagados do Keycloak (spec) e do Legado (`DELETE` no SQL; o Legado não tem exclusão); stack derrubada sem `-v` |

## Ainda coberto só pela rodada anterior (real, sem simulação nova)
`log_search_access_denied` (403 sem role) e o smoke `smoke-graylog.sh` (30 ok). CPF: só em testes (o Legado não tem CPF; autocadastro T21 fora da DEV-005).

## Achados
- **Crítico/Alto/Médio:** nenhum. M1 (sem log real com campo pessoal) resolvido: Legado e Cadastro logam `{UserName}`, o Legado também `{Email}`/`{MobilePhone}`.
- **Baixo B1:** o step-up de OTP exige esperar o próximo passo TOTP (o spec espera 31 s).
- **Baixo B2:** `cadastro/scripts;C/` (pasta vazia, resto de caminho do Git Bash) não versionada.
- **Baixo B3:** a conta `x01qa*` fica no Legado depois do spec (sem exclusão pela API); limpar por SQL, como feito aqui.
- **Baixos da auditoria documental ainda abertos (sem impacto em garantia):** descrição do stream Keycloak - Auditoria em `provision.sh` ("sem dados pessoais", mas recebe `masked_login` mascarado) e teste de texto para login inválido longo e para o CNPJ alfanumérico curto (ADR-0003, item 10).
