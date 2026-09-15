#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

DB_NAME="${1:-}"
[[ -n "${DB_NAME}" ]] || { echo "Usage: ./finalize.sh <database_name>" >&2; exit 1; }
[[ "${DB_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
    echo "Database name may contain only letters, digits, dot, underscore and hyphen." >&2
    exit 1
}

[[ -f .env ]] || { echo "Missing .env." >&2; exit 1; }
[[ -f config/odoo.conf ]] || { echo "Missing config/odoo.conf." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required on the host." >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is required." >&2; exit 1; }

set -a
# shellcheck disable=SC1091
source .env
set +a

echo "Checking that database '${DB_NAME}' exists..."
DB_EXISTS="$(
    docker compose exec -T db \
      psql -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 -tAc \
      "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}';" \
      | tr -d '[:space:]'
)"

[[ "${DB_EXISTS}" == "1" ]] || {
    echo "Database '${DB_NAME}' was not found. Nothing changed." >&2
    exit 1
}

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="config/odoo.conf.before-finalize-${STAMP}"
cp -p config/odoo.conf "${BACKUP}"

rollback() {
    echo "Finalization failed; restoring previous Odoo config..." >&2
    cp -p "${BACKUP}" config/odoo.conf
    docker compose restart odoo19 >/dev/null 2>&1 || true
}

trap rollback ERR

python3 - "config/odoo.conf" "${DB_NAME}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
db = sys.argv[2]
text = path.read_text()

def set_option(source: str, key: str, value: str) -> str:
    pattern = re.compile(rf"(?m)^\s*{re.escape(key)}\s*=.*$")
    line = f"{key} = {value}"
    if pattern.search(source):
        return pattern.sub(line, source)
    if not source.endswith("\n"):
        source += "\n"
    return source + line + "\n"

text = set_option(text, "list_db", "False")
text = set_option(text, "db_name", db)
text = set_option(text, "dbfilter", "^" + re.escape(db) + "$")
path.write_text(text)
PY

chmod 640 config/odoo.conf

echo "Restarting Odoo only to apply production database lock-down..."
docker compose restart odoo19

CID="$(docker compose ps -q odoo19)"
[[ -n "${CID}" ]] || { echo "Odoo container not found after restart." >&2; false; }

echo "Waiting for Odoo health..."
for _ in $(seq 1 60); do
    STATUS="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${CID}")"
    case "${STATUS}" in
        healthy)
            trap - ERR
            echo "Database Manager disabled and instance locked to database '${DB_NAME}'."
            echo "Previous config: ${BACKUP}"
            exit 0
            ;;
        unhealthy|exited|dead)
            echo "Odoo became ${STATUS}. Recent logs:" >&2
            docker compose logs --tail=100 odoo19 >&2 || true
            false
            ;;
    esac
    sleep 2
done

echo "Timed out waiting for Odoo to become healthy. Recent logs:" >&2
docker compose logs --tail=100 odoo19 >&2 || true
false
