#!/usr/bin/env bash
#
# backup.sh — Backup pg_dump + filestore de l'instance IBATIX.
#
# Sortie : /opt/backups/ibatix-CLIENT-YYYYMMDD-HHMM.tar.gz

set -euo pipefail
STACK_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/opt/backups}"
TS="$(date +%Y%m%d-%H%M)"

source "$STACK_DIR/.env"
mkdir -p "$BACKUP_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { echo -e "\e[1;34m[$(date +%H:%M:%S)]\e[0m $*"; }

cd "$STACK_DIR"

log "pg_dump base 'prod'"
docker compose -f prod.yaml exec -T db pg_dump -U odoo -F c -f /tmp/dump.pg prod
docker compose -f prod.yaml exec -T db cat /tmp/dump.pg >"$WORK/dump.pg"
docker compose -f prod.yaml exec -T db rm /tmp/dump.pg

log "Snapshot filestore"
docker run --rm -v "ibatix-${CLIENT_NAME}_filestore:/data:ro" -v "$WORK:/out" alpine \
  tar -C /data -czf /out/filestore.tar.gz .

ARCHIVE="$BACKUP_DIR/ibatix-${CLIENT_NAME}-${TS}.tar.gz"
tar -C "$WORK" -czf "$ARCHIVE" dump.pg filestore.tar.gz

log "Backup écrit : $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
