#!/usr/bin/env bash
# Gera o .env local com segredos aleatórios (nunca versionado). Não sobrescreve um .env existente.
# Uso: ./scripts/generate-env.sh            (mostra onde está a senha do admin, sem imprimi-la)
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ -f .env ]]; then
  echo ".env já existe; nada foi alterado. Apague-o para gerar novos segredos."
  exit 0
fi

random() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

admin_password="$(random 24)"
# O Graylog recebe só o SHA-256 da senha do admin; a senha em texto fica no .env para o provisionamento.
admin_sha2="$(printf '%s' "$admin_password" | sha256sum | cut -d' ' -f1)"

umask 077
cat > .env <<EOF
# Gerado por scripts/generate-env.sh em $(date -u +%Y-%m-%dT%H:%M:%SZ). NUNCA versione este arquivo.
GRAYLOG_PASSWORD_SECRET=$(random 96)
GRAYLOG_ROOT_PASSWORD=${admin_password}
GRAYLOG_ROOT_PASSWORD_SHA2=${admin_sha2}
MONGODB_PASSWORD=$(random 32)
GRAYLOG_TIMEZONE=America/Sao_Paulo
LOG_RETENTION_DAYS=30
OPENSEARCH_HEAP=1g
EOF

echo ".env criado. Usuário da UI: admin — senha em GRAYLOG_ROOT_PASSWORD no .env."
