#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="${HOME:-/home/cherny}"
DB_PATH="${DATABASE_PATH:-${HOME_DIR}/.cloudcli/auth.db}"
CLOUDCLI_ROOT="/usr/local/lib/node_modules/@siteboon/claude-code-ui"
INIT_SQL="${CLOUDCLI_ROOT}/server/database/init.sql"
USERNAME="${CLOUDCLI_PLATFORM_USERNAME:-${USER:-cherny}}"

mkdir -p "$(dirname "$DB_PATH")"

if [[ ! -f "$INIT_SQL" ]]; then
  echo "cloudcli-bootstrap-user: missing init.sql at ${INIT_SQL}" >&2
  exit 1
fi

sqlite3 "$DB_PATH" < "$INIT_SQL"

sqlite3 "$DB_PATH" <<SQL
CREATE TABLE IF NOT EXISTS app_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO users (username, password_hash, has_completed_onboarding, is_active)
SELECT '${USERNAME}', 'platform-mode-disabled', 1, 1
WHERE NOT EXISTS (SELECT 1 FROM users WHERE is_active = 1);
UPDATE users SET has_completed_onboarding = 1 WHERE is_active = 1;
SQL
