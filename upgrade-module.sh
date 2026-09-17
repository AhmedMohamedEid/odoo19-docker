#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

usage() {
    cat <<'EOF'
Usage:
  ./upgrade-module.sh [--db DATABASE] [--yes] module[,module2,...]

Examples:
  ./upgrade-module.sh my_custom_module
  ./upgrade-module.sh sale,purchase
  ./upgrade-module.sh --db customer_prod my_custom_module
  ./upgrade-module.sh --yes my_custom_module

Behavior:
  - Uses db_name from config/odoo.conf when available, otherwise --db is required.
  - Verifies the target database exists.
  - Stops only the Odoo service if it is currently running.
  - Runs the module update in a temporary one-off Odoo container.
  - Starts Odoo again and waits for health.
  - PostgreSQL remains running throughout the operation.

IMPORTANT:
  Module upgrades can change database schema and data. Take a current backup or
  snapshot before upgrading production databases. This script does not create a
  database backup automatically.
EOF
}

fail() {
    printf '[upgrade-module] ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[upgrade-module] %s\n' "$*"
}

DB_NAME=""
ASSUME_YES=0
MODULES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db)
            [[ $# -ge 2 ]] || fail "--db requires a database name."
            DB_NAME="$2"
            shift 2
            ;;
        --yes|-y)
            ASSUME_YES=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            fail "Unknown option: $1"
            ;;
        *)
            [[ -z "${MODULES}" ]] || fail "Provide modules as one comma-separated argument."
            MODULES="$1"
            shift
            ;;
    esac
done

[[ -n "${MODULES}" ]] || { usage; exit 1; }
[[ "${MODULES}" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] || \
    fail "Invalid module list. Use technical module names separated by commas."

[[ -f .env ]] || fail "Missing .env. Run this script inside an installed project."
[[ -f config/odoo.conf ]] || fail "Missing config/odoo.conf."
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required."

set -a
# shellcheck disable=SC1091
source .env
set +a

POSTGRES_USER="${POSTGRES_USER:-odoo}"

read_config_db_name() {
    awk -F= '
        /^[[:space:]]*db_name[[:space:]]*=/ {
            value=$0
            sub(/^[^=]*=/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' config/odoo.conf
}

if [[ -z "${DB_NAME}" ]]; then
    DB_NAME="$(read_config_db_name || true)"
fi

[[ -n "${DB_NAME}" ]] || \
    fail "Database is not locked in config/odoo.conf yet. Pass it explicitly with --db DATABASE."

[[ "${DB_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || \
    fail "Database name may contain only letters, digits, dot, underscore and hyphen."

log "Checking database '${DB_NAME}'..."
DB_EXISTS="$(
    docker compose exec -T db \
      psql -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 -tAc \
      "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}';" \
      | tr -d '[:space:]'
)"
[[ "${DB_EXISTS}" == "1" ]] || fail "Database '${DB_NAME}' was not found."

ODOO_CID="$(docker compose ps -q odoo19 2>/dev/null || true)"
ODOO_WAS_RUNNING=0
if [[ -n "${ODOO_CID}" ]]; then
    ODOO_STATE="$(docker inspect --format '{{.State.Status}}' "${ODOO_CID}" 2>/dev/null || true)"
    [[ "${ODOO_STATE}" == "running" ]] && ODOO_WAS_RUNNING=1
fi

if (( ASSUME_YES == 0 )); then
    if [[ -t 0 ]]; then
        printf '\nDatabase : %s\nModules  : %s\n' "${DB_NAME}" "${MODULES}"
        printf 'This operation changes the database. Confirm a current backup/snapshot exists.\n'
        read -r -p 'Continue with module upgrade? [y/N] ' answer
        [[ "${answer}" =~ ^[Yy]$ ]] || { log "Cancelled."; exit 0; }
    else
        fail "Non-interactive execution requires --yes."
    fi
fi

wait_for_odoo_health() {
    local cid status
    cid="$(docker compose ps -q odoo19 2>/dev/null || true)"
    [[ -n "${cid}" ]] || return 1

    for _ in $(seq 1 60); do
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${cid}" 2>/dev/null || true)"
        case "${status}" in
            healthy)
                return 0
                ;;
            running)
                # Fallback for a project without a Docker healthcheck.
                if ! docker inspect --format '{{if .State.Health}}yes{{else}}no{{end}}' "${cid}" | grep -qx yes; then
                    return 0
                fi
                ;;
            unhealthy|exited|dead)
                return 1
                ;;
        esac
        sleep 2
    done
    return 1
}

restart_original_service() {
    if (( ODOO_WAS_RUNNING == 1 )); then
        log "Restoring Odoo service..."
        docker compose up -d --no-deps odoo19 >/dev/null || true
        if ! wait_for_odoo_health; then
            printf '[upgrade-module] WARNING: Odoo did not become healthy after restart.\n' >&2
            docker compose ps >&2 || true
            docker compose logs --tail=120 odoo19 >&2 || true
            return 1
        fi
    fi
}

UPGRADE_STARTED=0
cleanup_on_error() {
    local rc=$?
    if (( rc != 0 && UPGRADE_STARTED == 1 )); then
        printf '[upgrade-module] Upgrade failed. Attempting to restore the previous Odoo runtime state.\n' >&2
        restart_original_service || true
    fi
    exit "${rc}"
}
trap cleanup_on_error ERR

if (( ODOO_WAS_RUNNING == 1 )); then
    log "Stopping Odoo only; PostgreSQL remains online..."
    docker compose stop odoo19
fi

UPGRADE_STARTED=1
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p logs
{
    printf '%s database=%s modules=%s status=STARTED\n' "$(date -Is)" "${DB_NAME}" "${MODULES}"
} >> logs/module-upgrade-history.log

log "Upgrading module(s): ${MODULES}"
docker compose run --rm --no-deps odoo19 \
    odoo \
    -c /etc/odoo/odoo.conf \
    -d "${DB_NAME}" \
    -u "${MODULES}" \
    --stop-after-init \
    --no-http \
    --workers=0 \
    --max-cron-threads=0

{
    printf '%s database=%s modules=%s status=UPGRADE_OK\n' "$(date -Is)" "${DB_NAME}" "${MODULES}"
} >> logs/module-upgrade-history.log

trap - ERR

if (( ODOO_WAS_RUNNING == 1 )); then
    log "Starting Odoo and waiting for health..."
    docker compose up -d --no-deps odoo19
    if ! wait_for_odoo_health; then
        printf '[upgrade-module] ERROR: Module upgrade completed, but Odoo did not become healthy after restart.\n' >&2
        docker compose ps >&2 || true
        docker compose logs --tail=120 odoo19 >&2 || true
        exit 1
    fi
fi

{
    printf '%s database=%s modules=%s status=COMPLETE\n' "$(date -Is)" "${DB_NAME}" "${MODULES}"
} >> logs/module-upgrade-history.log

log "Module upgrade completed successfully."
log "Database: ${DB_NAME}"
log "Modules : ${MODULES}"
log "History : logs/module-upgrade-history.log"
