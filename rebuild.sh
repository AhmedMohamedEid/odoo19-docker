#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

[[ -f .env ]] || { echo "Missing .env. Run this inside an installed instance." >&2; exit 1; }

docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is required." >&2; exit 1; }

BUILD_ARGS=(--pull)
if [[ "${1:-}" == "--no-cache" ]]; then
    BUILD_ARGS+=(--no-cache)
fi

echo "Building the Odoo image with current requirements..."
docker compose build "${BUILD_ARGS[@]}" odoo19

echo "Applying the rebuilt image..."
docker compose up -d

echo "Done. Current service status:"
docker compose ps
