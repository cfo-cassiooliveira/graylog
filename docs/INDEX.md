# Índice — graylog (leia este antes dos docs longos)

## Specs
- 001 Pseudonimização pesquisável de logs — Aprovada — `docs/specs/001-pseudonimizacao-logs/summary.md`

## ADRs (todos Aceitos)
- 0001 Stack Graylog 7.2 + OpenSearch 3.7 + MongoDB 8.0 — `docs/adr/0001-stack-graylog-opensearch.md`
- 0002 Mascaramento parcial LGPD — `docs/adr/0002-mascaramento-parcial-lgpd.md`
- 0003 Token HMAC-SHA256 pesquisável na origem — `docs/adr/0003-pseudonimizacao-hmac-pesquisavel.md`

## Comandos
- `./scripts/generate-env.sh` cria o .env (nunca versionado)
- `docker compose up -d --build` sobe a stack e provisiona
- `./scripts/smoke-test.sh` teste ponta a ponta; `./scripts/smoke-network.sh` isolamento do OpenSearch

## Onde procurar
- Regras de pipeline/streams/alertas: `provisioning/provision.sh`, `provisioning/rules/`
- Subir, variáveis, segurança: `README.md`; convenções do projeto: `CLAUDE.md`
- Decisão de formato/campo LGPD: ADR-0002/0003; plano e vetores de teste: spec 001 `plan.md` §2
