#!/usr/bin/env bash
# Idempotent bootstrap for the monitoring VM's Docker Compose stack.
# Does NOT install Docker itself, and does NOT install PDM (native package,
# see docs/deployment-guide.md) — this only prepares repo-local state and
# brings the core compose stack up. Safe to re-run.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

log() { echo "[bootstrap] $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}
require_cmd docker
require_cmd envsubst
docker compose version >/dev/null 2>&1 || { echo "docker compose plugin not found" >&2; exit 1; }

if [[ ! -f .env ]]; then
  log ".env not found — copying from .env.example (edit it before continuing, or re-run after)"
  cp .env.example .env
  log "Created .env — fill in BASE_DOMAIN, ACME_EMAIL, PVE_API_TOKEN_ID/SECRET, CV4PVE_*_HOSTS, etc., then re-run this script."
  exit 0
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

required_vars=(BASE_DOMAIN ACME_EMAIL PVE_API_TOKEN_ID PVE_API_TOKEN_SECRET CV4PVE_DIAG_HOSTS CV4PVE_EXPORTER_HOSTS ALERTMANAGER_SMTP_SMARTHOST ALERTMANAGER_RECEIVER_EMAIL)
missing=0
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" || "${!var}" == *CHANGEME* ]]; then
    echo "  Missing/placeholder value for ${var} in .env" >&2
    missing=1
  fi
done
if [[ "${missing}" -eq 1 ]]; then
  echo "Fill in the variables above in .env before running this script. See docs/deployment-guide.md." >&2
  exit 1
fi

if [[ ! -x scripts/generate-secrets.sh ]]; then
  chmod +x scripts/generate-secrets.sh
fi
log "Ensuring generated secrets (passwords, htpasswd file) are present..."
scripts/generate-secrets.sh

log "Rendering config/alertmanager/alertmanager.yml from template..."
am_config=config/alertmanager/alertmanager.yml
# envsubst has no ${VAR:-default}; default here so an older .env keeps TLS on.
export ALERTMANAGER_SMTP_REQUIRE_TLS="${ALERTMANAGER_SMTP_REQUIRE_TLS:-true}"
(umask 077 && envsubst < config/alertmanager/alertmanager.yml.tmpl > "${am_config}")
# The alertmanager container runs as nobody (65534) with all capabilities
# dropped, so it can only read the bind-mounted file through its group or
# "other" bits — a 600 file owned by the host user is unreadable to it and
# Alertmanager fails to start.
if [[ "${EUID}" -eq 0 ]]; then
  chown root:65534 "${am_config}"
  chmod 640 "${am_config}"
else
  chmod 644 "${am_config}"
  log "WARNING: not running as root, so ${am_config} (contains SMTP credentials) is left world-readable (644) for the container's nobody user. Re-run as root to tighten it to root:65534 640."
fi

for f in config/prometheus/targets/proxmox-nodes.json config/prometheus/targets/ceph-mgr.json; do
  if [[ ! -f "${f}" ]]; then
    log "Seeding ${f} from ${f}.example — edit it with real node hostnames before scraping will work."
    cp "${f}.example" "${f}"
  fi
done

log "Pulling/building images..."
docker compose pull --ignore-buildable
# --profile tools so the one-shot cv4pve-diag image is built up front
# rather than lazily on the systemd timer's first run.
docker compose --profile tools build

log "Starting core stack..."
docker compose up -d

log "Done. Check status with: docker compose ps"
log "PegaProx (optional, experimental) is not started — see docs/adr/0005 and README for the opt-in overlay command."
log "Keycloak forwardAuth (Phase 2) is not started — see docs/keycloak-integration.md."
