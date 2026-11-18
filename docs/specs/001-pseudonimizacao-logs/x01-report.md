# X01 — Relatório de QA E2E (2026-11-18)

Stack real no ar (graylog, keycloak, legado, cadastro, todos com o override do Graylog). Dados fictícios (CPF de teste válido, e-mails `@exemplo.com`).

## Verificado
| Item | Como | Resultado |
|---|---|---|
| Login na tela `/log-search` | Playwright (container): investigador com role `log-investigator` e OTP | OK; sem OTP recente a tela pede "Confirmar com código" (step-up) e, após o código, gera a consulta |
| Consulta pela tela | CPF de teste + referência `X01-QA-2026` | `CPF_token/Cpf_token/cpf_token:("k1-...")`, token idêntico ao de `cadastro/scripts/log-search-token.sh`; sem o valor na tela |
| Dois eventos encontrados | Consulta da tela executada na API de busca do Graylog | 2 eventos: `legado-api` e `cadastro-api` (ver achado M1) |
| Trilha de auditoria | Stream `Cadastro - Pesquisa em logs (LGPD)` | `log_search_query_issued` (investigator_id = sub do Keycloak, `data_type=cpf`, `case_reference`, token) e `log_search_access_denied` (usuário sem role, 403) |
| Nenhum valor em claro | Busca pelo CPF (com e sem pontuação), login e e-mail de teste | 0 resultados (nos 4 valores); `client-logs` dos dois sistemas com o CPF no texto saem mascarados (`***.533.447-**`) |
| Smoke Cadastro→Graylog | `cadastro/scripts/smoke-graylog.sh` | 30 verificações ok, 0 falhas |

## Achados
- **Crítico/Alto:** nenhum.
- **Médio M1:** nenhum ponto de produção do Legado ou do Cadastro loga `{Cpf}`/`{Phone}`/`{UserName}`/`{Email}` como campo (só testes e `client-logs`, que mascara texto sem token). Por isso a pesquisa por token não acha nada em fluxos reais. Os dois eventos do E2E foram **GELF simulados** (`Cpf_token` calculado com a chave de cada projeto; as chaves k1 dos dois `.env` são iguais). O cenário "mesmo CPF registrado no legado e no cadastro" não é executável como escrito: o Legado não tem CPF e a tela "Criar conta" do Cadastro (T21) está fora da DEV-005. Código: só relato.
- **Baixo B1:** o step-up de OTP exige esperar o próximo passo TOTP (o Keycloak recusa o mesmo código); comportamento correto, mas o E2E precisa dessa espera.
- **Baixo B2:** `cadastro/scripts;C/` (pasta vazia, resto de caminho convertido pelo Git Bash) existe na árvore; não é versionada.

## Divergências doc × código
- Escopo do X01 citava "mesmo CPF registrado no legado e no cadastro": ajustado em `tasks.md` (ver M1). Demais docs conferidas (streams, campos, alertas, trilha) batem com o código e o provisionamento.

## Pendente para fechar o X01
Decidir M1: um ponto de log real com campo estruturado de dado pessoal (ex.: login no Cadastro e no Legado) para o E2E ficar 100% com fluxo de aplicação. Até lá X01 fica `[ ]`.
