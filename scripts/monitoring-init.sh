#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ -e monitoring/.env ]; then
    echo "monitoring/.env already exists; credentials preserved."
    exit 0
fi
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }
umask 077
password=$(openssl rand -hex 24)
# Noclobber also protects against a simultaneous second initializer.
set -C
printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$password" > monitoring/.env
echo "Created monitoring/.env (mode 600). Read the password privately with your editor."
echo "Next: make monitoring-up"
