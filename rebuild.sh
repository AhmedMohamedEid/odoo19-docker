#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

[[ -f .env ]] || { echo "Missing .env. Run this inside an installed instance." >&2; exit 1; }

docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is required." >&2; exit 1; }

BUILD_ARGS=(--pull)
if [[ "${1:-}" == "--no-cache" ]]; then
    BUILD_ARGS+=(--no-cache)
elif [[ -n "${1:-}" ]]; then
    echo "Usage: ./rebuild.sh [--no-cache]" >&2
    exit 1
fi

echo "Building the Odoo image from the pinned base image..."
docker compose build "${BUILD_ARGS[@]}" odoo19

echo "Applying the rebuilt Odoo image only..."
if docker compose up --help 2>&1 | grep -q -- '--wait'; then
    docker compose up -d --no-deps --wait odoo19
else
    docker compose up -d --no-deps odoo19
fi

echo "Current service status:"
docker compose ps
