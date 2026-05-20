#!/usr/bin/env bash
#
# upgrade.sh — Met à jour l'instance IBATIX sur ce VPS.
#
# Usage : ./upgrade.sh [MODULES]
#
#   MODULES : liste séparée par des virgules. Défaut = 'all' (tous les modules
#             installés sont upgradés). Sinon ex. : ibatix_solar,ibatix_calcul_cee

set -euo pipefail
STACK_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULES="${1:-all}"

if [[ ! -f "$STACK_DIR/.env" ]]; then
  echo "Pas de .env dans $STACK_DIR — le VPS n'est pas initialisé. Lance install.sh d'abord." >&2
  exit 1
fi

cd "$STACK_DIR"

log() { echo -e "\e[1;34m[$(date +%H:%M:%S)]\e[0m $*"; }

log "Pull dernières sources stack + ibatix"
git pull --rebase --autostash

log "Rebuild image Docker (gitaggregate re-clone ibatix branch courante)"
docker compose -f prod.yaml build --pull

log "Arrêt Odoo (laisse Postgres up)"
docker compose -f prod.yaml stop odoo

log "Install/upgrade modules : $MODULES"
docker compose -f prod.yaml run --rm odoo odoo \
  --stop-after-init --no-http \
  -d prod \
  -i "$MODULES" \
  -u "$MODULES"

log "Redémarrage Odoo"
docker compose -f prod.yaml up -d odoo

log "Upgrade terminé. Vérifie les logs : docker compose -f $STACK_DIR/prod.yaml logs -f odoo"
