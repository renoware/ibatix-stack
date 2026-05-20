#!/usr/bin/env bash
#
# install.sh — Bootstrap d'une instance IBATIX sur un VPS neuf.
#
# Usage : ./install.sh CLIENT_NAME DOMAIN [BRANCH]
# Exemple : ./install.sh acme acme.ibatix.io main
#
# Prérequis :
#   - VPS Ubuntu 22.04+ ou Debian 12+ frais
#   - Accès root
#   - DNS de DOMAIN pointant déjà vers l'IP du VPS
#   - Ce dépôt ibatix-stack cloné dans /opt/ibatix-stack (ou répertoire courant)

set -euo pipefail

CLIENT_NAME="${1:-}"
DOMAIN="${2:-}"
IBATIX_BRANCH="${3:-main}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-ops@ibatix.io}"
STACK_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -z "$CLIENT_NAME" || -z "$DOMAIN" ]]; then
  echo "Usage : $0 CLIENT_NAME DOMAIN [BRANCH]" >&2
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "Doit être lancé en root." >&2
  exit 1
fi

log() { echo -e "\e[1;34m[$(date +%H:%M:%S)]\e[0m $*"; }

#-----------------------------------------------------------------------
# 1. Paquets système + Docker
#-----------------------------------------------------------------------
log "Mise à jour APT + paquets de base"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release ufw openssh-client git pwgen

if ! command -v docker &>/dev/null; then
  log "Installation Docker"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

#-----------------------------------------------------------------------
# 2. Pare-feu (80/443/22)
#-----------------------------------------------------------------------
log "Configuration pare-feu (UFW)"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

#-----------------------------------------------------------------------
# 3. Clé SSH GitHub pour accès au repo privé renoware/ibatix
#-----------------------------------------------------------------------
SSH_KEY="$STACK_DIR/odoo/custom/ssh/id_rsa"
if [[ ! -s "$SSH_KEY" || $(wc -c <"$SSH_KEY") -lt 100 ]]; then
  log "Génération clé SSH ed25519 pour accès GitHub (deploy key)"
  rm -f "$SSH_KEY" "$SSH_KEY.pub"
  ssh-keygen -t ed25519 -N "" -C "ibatix-${CLIENT_NAME}@$(hostname)" -f "$SSH_KEY"
  chmod 600 "$SSH_KEY"
  chmod 644 "$SSH_KEY.pub"
fi

cat >"$STACK_DIR/odoo/custom/ssh/config" <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile /opt/odoo/custom/ssh/id_rsa
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF

echo
echo "============================================================"
echo "  AJOUTE CETTE CLÉ COMME DEPLOY KEY SUR renoware/ibatix"
echo "  → https://github.com/renoware/ibatix/settings/keys/new"
echo "  → Titre : ibatix-${CLIENT_NAME}"
echo "  → Read-only suffit"
echo "============================================================"
cat "$SSH_KEY.pub"
echo "============================================================"
if [[ -z "${IBATIX_NON_INTERACTIVE:-}" ]]; then
  read -rp "Appuie sur ENTRÉE quand la deploy key est ajoutée."
fi

#-----------------------------------------------------------------------
# 4. Secrets locaux (jamais commités)
#-----------------------------------------------------------------------
log "Génération des secrets locaux"
mkdir -p "$STACK_DIR/.docker"
ADMIN_PASSWORD="$(pwgen -s 32 1)"
DB_PASSWORD="$(pwgen -s 32 1)"

for f in odoo.env db-access.env db-creation.env; do
  sed -e "s|__ADMIN_PASSWORD__|$ADMIN_PASSWORD|g" \
      -e "s|__DB_PASSWORD__|$DB_PASSWORD|g" \
      "$STACK_DIR/.docker.example/$f" >"$STACK_DIR/.docker/$f"
done

cat >"$STACK_DIR/.env" <<EOF
CLIENT_NAME=$CLIENT_NAME
DOMAIN=$DOMAIN
IBATIX_BRANCH=$IBATIX_BRANCH
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
COMPOSE_PROJECT_NAME=ibatix-$CLIENT_NAME
EOF

mkdir -p "$STACK_DIR/secrets"
chmod 700 "$STACK_DIR/secrets"
cat >"$STACK_DIR/secrets/credentials.txt" <<EOF
# IBATIX — credentials générés à l'installation ($(date -u +%Y-%m-%dT%H:%MZ))
CLIENT_NAME=$CLIENT_NAME
DOMAIN=$DOMAIN
URL=https://$DOMAIN

ADMIN_PASSWORD=$ADMIN_PASSWORD
DB_PASSWORD=$DB_PASSWORD

ADMIN_LOGIN=admin
ADMIN_INITIAL_PASSWORD=admin   # à changer au 1er login
EOF
chmod 600 "$STACK_DIR/secrets/credentials.txt"

#-----------------------------------------------------------------------
# 5. Inverseproxy (Traefik) — partagé pour tous les compose sur ce VPS
#-----------------------------------------------------------------------
log "Démarrage Traefik (inverseproxy)"
cd "$STACK_DIR/inverseproxy"
LETSENCRYPT_EMAIL="$LETSENCRYPT_EMAIL" docker compose up -d

#-----------------------------------------------------------------------
# 6. Build et démarrage de l'instance Odoo
#-----------------------------------------------------------------------
log "Build de l'image Doodba (clone OCB + ibatix, takes a few min)"
cd "$STACK_DIR"
docker compose -f prod.yaml build

log "Démarrage des conteneurs odoo + db"
docker compose -f prod.yaml up -d

log "Attente que Postgres soit prêt"
for i in {1..30}; do
  if docker compose -f prod.yaml exec -T db pg_isready -U odoo >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

#-----------------------------------------------------------------------
# 7. Init DB + installation des modules de base IBATIX
#-----------------------------------------------------------------------
log "Initialisation de la base 'prod' + installation des modules de base"
docker compose -f prod.yaml exec -T odoo odoo \
  --stop-after-init --no-http \
  -d prod \
  -i base,ibatix_theme,ibatix_home,ibatix_champs,ibatix_identity,ibatix_siret,ibatix_gov_api,ibatix_document,ibatix_usage_client \
  --load-language=fr_FR

log "Redémarrage final"
docker compose -f prod.yaml restart odoo

echo
echo "============================================================"
echo "  Installation terminée."
echo "============================================================"
echo "  URL          : https://$DOMAIN"
echo "  Login        : admin / admin (à changer au premier login)"
echo "  Credentials  : $STACK_DIR/secrets/credentials.txt"
echo "  Logs         : docker compose -f $STACK_DIR/prod.yaml logs -f odoo"
echo "============================================================"
