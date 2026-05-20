# ibatix-stack

Stack de déploiement IBATIX sur VPS client. Basé sur [Doodba](https://github.com/Tecnativa/doodba) (Tecnativa) + Traefik 3.

**1 VPS = 1 client.** Odoo 19 Community, modules `ibatix_*` clonés depuis [renoware/ibatix](https://github.com/renoware/ibatix) en deploy key.

## Architecture

```
VPS client
├── Traefik (inverseproxy_shared) — HTTPS Let's Encrypt automatique
└── ibatix-stack
    ├── odoo (Doodba 19.0)
    └── postgres 16
```

Le clone d'OCB + `renoware/ibatix` se fait au build de l'image, via `gitaggregate` (Doodba). La base par défaut s'appelle `prod`. dbfilter `^prod$`.

## Installation d'un nouveau client

Sur un VPS Ubuntu 22.04+ ou Debian 12+, en root, DNS de `DOMAIN` pointant déjà vers l'IP :

```bash
apt update && apt install -y git
git clone https://github.com/renoware/ibatix-stack.git /opt/ibatix-stack
cd /opt/ibatix-stack
./install.sh CLIENT_NAME DOMAIN [BRANCH]
```

Exemple :

```bash
./install.sh acme acme.ibatix.io main
```

Le script :
1. Installe Docker + UFW (80/443/22 ouverts)
2. Génère une clé SSH ed25519 et **demande à l'opérateur de l'ajouter comme deploy key sur `renoware/ibatix`**
3. Génère les mots de passe DB + admin (sauvegardés dans `secrets/credentials.txt`, mode 600)
4. Démarre Traefik (inverseproxy)
5. Build l'image Doodba (clone OCB + ibatix)
6. Initialise la base `prod` avec les modules de base IBATIX
7. Restart final

Durée : ~10-15 min selon la bande passante du VPS.

## Upgrade d'un client existant

```bash
cd /opt/ibatix-stack
./upgrade.sh                            # upgrade tous les modules installés
./upgrade.sh ibatix_solar               # upgrade un module
./upgrade.sh ibatix_solar,ibatix_pac    # upgrade plusieurs
```

Le script `git pull` la stack, rebuild l'image (re-clone le repo `ibatix` à la branche `IBATIX_BRANCH` du `.env`), puis lance `odoo -u`.

## Backup

```bash
./backup.sh
# → /opt/backups/ibatix-CLIENT-YYYYMMDD-HHMM.tar.gz
```

Contient : `pg_dump -F c` de la base + tarball du filestore.

## Structure du dépôt

| Fichier | Rôle |
|---|---|
| `install.sh` | Bootstrap initial du VPS |
| `upgrade.sh` | Upgrade des modules |
| `backup.sh` | Backup DB + filestore |
| `prod.yaml` | docker-compose production (odoo + db, labels Traefik) |
| `common.yaml`, `devel.yaml`, `test.yaml` | Compose Doodba standard (devel/test inutilisés en prod) |
| `odoo/Dockerfile` | Image Doodba 19.0 |
| `odoo/custom/src/repos.yaml` | Sources git (OCB + renoware/ibatix) |
| `odoo/custom/src/addons.yaml` | Liste des modules ibatix_* exposés |
| `odoo/custom/ssh/` | Clés SSH du VPS pour clone GitHub (générées au 1er install) |
| `inverseproxy/docker-compose.yml` | Traefik 3 (proxy partagé du VPS) |
| `.docker.example/` | Templates env (passwords substitués par install.sh) |
| `.env.example` | Variables d'environnement attendues |

## Modules IBATIX inclus

Voir `odoo/custom/src/addons.yaml`. Modules de base installés par `install.sh` :

- `ibatix_theme`, `ibatix_home`, `ibatix_champs`
- `ibatix_identity`, `ibatix_siret`, `ibatix_gov_api`
- `ibatix_document`
- `ibatix_usage_client` (callback vers le HUB pour la conso API/IA)

Les modules métier (`ibatix_solar`, `ibatix_pac`, `ibatix_calcul_cee`, etc.) sont disponibles dans l'addons_path mais **non installés par défaut** — à activer dans `Apps` selon le client.

## Pièges connus

- **Port 8069 jamais exposé** : Traefik proxie sur 80/443 (cf. piège pare-feu hébergeurs).
- **Header `Host` préservé** : Traefik transmet le Host original, dbfilter `^prod$` matche bien.
- **Deploy key par VPS** : chaque client a sa propre clé SSH read-only sur `renoware/ibatix`.
- **dbfilter `^prod$`** : la base s'appelle TOUJOURS `prod`. Le domaine change, pas la DB.

## Hub IBATIX

`ibatix_usage_client` installé par défaut → l'instance phone-home vers le HUB (`renowave.cloud`) pour les compteurs de conso API/IA et le fleet management (module `ibatix_fleet` côté HUB).

Voir aussi : repo `renoware/ibatix-fleet-ansible` pour les playbooks d'orchestration.
