#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${ODOO_DOCKER_REPO:-https://github.com/AhmedMohamedEid/odoo19-docker.git}"
REPO_REF="${ODOO_DOCKER_REF:-main}"
PORT_START="${ODOO_PORT_START:-10019}"
PORT_END="${ODOO_PORT_END:-19999}"
GEVENT_OFFSET="${ODOO_GEVENT_OFFSET:-10000}"
ODOO_VERSION="${ODOO_VERSION:-19.0}"
POSTGRES_VERSION="${POSTGRES_VERSION:-16}"

usage() {
    cat <<'EOF'
Usage:
  sudo ./run.sh <destination>

Examples:
  sudo ./run.sh /odoo/customer-sa
  sudo ./run.sh customer-eg

Optional environment overrides:
  ODOO_DOCKER_REF=main
  ODOO_PORT_START=10019
  ODOO_PORT_END=19999
  ODOO_GEVENT_OFFSET=10000
  ODOO_VERSION=19.0
  POSTGRES_VERSION=16
EOF
}

log() {
    printf '\033[1;34m[odoo19]\033[0m %s\n' "$*"
}

fail() {
    printf '\033[1;31m[odoo19] ERROR:\033[0m %s\n' "$*" >&2
    exit 1
}

if [[ ${EUID} -ne 0 ]]; then
    fail "Run the installer with sudo so runtime directory ownership can be configured safely."
fi

DESTINATION="${1:-}"
[[ -n "${DESTINATION}" ]] || { usage; exit 1; }

command -v git >/dev/null 2>&1 || fail "git is required."
command -v docker >/dev/null 2>&1 || fail "Docker is required."
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required (docker compose)."
command -v openssl >/dev/null 2>&1 || fail "openssl is required to generate instance secrets."

if [[ -e "${DESTINATION}" ]] && [[ -n "$(find "${DESTINATION}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]]; then
    fail "Destination already exists and is not empty: ${DESTINATION}"
fi

HOST_USER="${SUDO_USER:-root}"
if [[ "${HOST_USER}" == "root" ]]; then
    HOST_UID=0
    HOST_GID=0
else
    HOST_UID="$(id -u "${HOST_USER}")"
    HOST_GID="$(id -g "${HOST_USER}")"
fi

project_name_from_path() {
    local raw
    raw="$(basename "${DESTINATION%/}")"
    raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^[^a-z0-9]+//; s/[-_]+$//')"
    [[ -n "${raw}" ]] || raw="odoo19"
    printf '%s' "${raw}"
}

list_used_ports() {
    {
        if command -v ss >/dev/null 2>&1; then
            ss -H -ltn 2>/dev/null | awk '{a=$4; sub(/^.*:/, "", a); if (a ~ /^[0-9]+$/) print a}'
        elif command -v netstat >/dev/null 2>&1; then
            netstat -lnt 2>/dev/null | awk 'NR>2 {a=$4; sub(/^.*:/, "", a); if (a ~ /^[0-9]+$/) print a}'
        fi

        docker ps --format '{{.Ports}}' 2>/dev/null \
            | grep -oE ':[0-9]+->' 2>/dev/null \
            | sed -E 's/^:([0-9]+)->$/\1/' || true
    } | sort -n -u
}

mapfile -t USED_PORTS < <(list_used_ports)

port_is_used() {
    local wanted="$1"
    local port
    for port in "${USED_PORTS[@]:-}"; do
        [[ "${port}" == "${wanted}" ]] && return 0
    done
    return 1
}

find_port_pair() {
    local highest=$((PORT_START - 1))
    local p candidate gevent

    for p in "${USED_PORTS[@]:-}"; do
        if [[ "${p}" =~ ^[0-9]+$ ]] && (( p >= PORT_START && p <= PORT_END && p > highest )); then
            highest="${p}"
        fi
    done

    if (( highest >= PORT_START )); then
        candidate=$((highest + 1))
    else
        candidate="${PORT_START}"
    fi

    while (( candidate <= PORT_END )); do
        gevent=$((candidate + GEVENT_OFFSET))
        if (( gevent <= 65535 )) && ! port_is_used "${candidate}" && ! port_is_used "${gevent}"; then
            printf '%s %s\n' "${candidate}" "${gevent}"
            return 0
        fi
        candidate=$((candidate + 1))
    done

    # If the upper end of the range is occupied, reuse the first safe gap.
    candidate="${PORT_START}"
    while (( candidate <= PORT_END )); do
        gevent=$((candidate + GEVENT_OFFSET))
        if (( gevent <= 65535 )) && ! port_is_used "${candidate}" && ! port_is_used "${gevent}"; then
            printf '%s %s\n' "${candidate}" "${gevent}"
            return 0
        fi
        candidate=$((candidate + 1))
    done

    return 1
}

PROJECT_NAME="$(project_name_from_path)"
read -r ODOO_PORT ODOO_GEVENT_PORT < <(find_port_pair) || fail "No free Odoo port pair was found in ${PORT_START}-${PORT_END}."
POSTGRES_PASSWORD="$(openssl rand -hex 24)"
ODOO_MASTER_PASSWORD="$(openssl rand -hex 24)"

log "Creating ${PROJECT_NAME} from ${REPO_REF}..."
git clone --depth=1 --branch "${REPO_REF}" "${REPO_URL}" "${DESTINATION}"
rm -rf "${DESTINATION}/.git"
cd "${DESTINATION}"

mkdir -p \
    addons/custom \
    addons/enterprise \
    data/odoo \
    data/postgresql \
    logs \
    config \
    requirements

cat > .env <<EOF
COMPOSE_PROJECT_NAME=${PROJECT_NAME}
ODOO_VERSION=${ODOO_VERSION}
POSTGRES_VERSION=${POSTGRES_VERSION}
ODOO_PORT=${ODOO_PORT}
ODOO_GEVENT_PORT=${ODOO_GEVENT_PORT}
POSTGRES_DB=postgres
POSTGRES_USER=odoo
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
EOF

sed "s/__ODOO_MASTER_PASSWORD__/${ODOO_MASTER_PASSWORD}/g" \
    config/odoo.conf.example > config/odoo.conf

# Keep the project editable by the invoking user while giving only runtime
# directories to the service users that need them.
chown -R "${HOST_UID}:${HOST_GID}" .
chmod 600 .env

log "Pulling PostgreSQL ${POSTGRES_VERSION} and building Odoo ${ODOO_VERSION}..."
docker compose pull db
docker compose build --pull odoo19

ODOO_IMAGE="${PROJECT_NAME}-odoo:${ODOO_VERSION}"
POSTGRES_IMAGE="postgres:${POSTGRES_VERSION}"
ODOO_UID="$(docker run --rm --entrypoint sh "${ODOO_IMAGE}" -c 'id -u odoo')"
ODOO_GID="$(docker run --rm --entrypoint sh "${ODOO_IMAGE}" -c 'id -g odoo')"
POSTGRES_UID="$(docker run --rm --entrypoint sh "${POSTGRES_IMAGE}" -c 'id -u postgres')"
POSTGRES_GID="$(docker run --rm --entrypoint sh "${POSTGRES_IMAGE}" -c 'id -g postgres')"

chown "${HOST_UID}:${ODOO_GID}" config/odoo.conf
chmod 640 config/odoo.conf

chown -R "${ODOO_UID}:${HOST_GID}" data/odoo logs
find data/odoo logs -type d -exec chmod 2770 {} +

chown -R "${POSTGRES_UID}:${POSTGRES_GID}" data/postgresql
chmod 700 data/postgresql

chown -R "${HOST_UID}:${HOST_GID}" addons requirements
chmod -R u+rwX,go+rX addons requirements

log "Starting PostgreSQL and Odoo..."
if docker compose up --help 2>&1 | grep -q -- '--wait'; then
    if ! docker compose up -d --wait; then
        docker compose ps || true
        [[ -f logs/odoo-server.log ]] && tail -n 100 logs/odoo-server.log || true
        fail "The instance did not become healthy. Review the status and log above."
    fi
else
    docker compose up -d
fi

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

printf '\n'
printf '============================================================\n'
printf ' Odoo 19 instance created successfully\n'
printf '============================================================\n'
printf ' Project directory : %s\n' "$(pwd)"
printf ' Odoo HTTP port    : %s\n' "${ODOO_PORT}"
printf ' Gevent/WS port    : %s\n' "${ODOO_GEVENT_PORT}"
printf ' Local URL         : http://localhost:%s\n' "${ODOO_PORT}"
if [[ -n "${SERVER_IP}" ]]; then
    printf ' Server URL        : http://%s:%s\n' "${SERVER_IP}" "${ODOO_PORT}"
fi
printf ' Master password   : %s\n' "${ODOO_MASTER_PASSWORD}"
printf ' Database          : not created (create it from Odoo)\n'
printf ' Runtime data      : %s/data\n' "$(pwd)"
printf ' Odoo log          : %s/logs/odoo-server.log\n' "$(pwd)"
printf ' Custom addons     : %s/addons/custom\n' "$(pwd)"
printf ' Python packages   : %s/requirements/requirements.txt\n' "$(pwd)"
printf ' System packages   : %s/requirements/apt.txt\n' "$(pwd)"
printf '============================================================\n'
