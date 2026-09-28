#!/usr/bin/env bash
# Monitoring VM: prerequisites from docs/deployment-guide.md steps 2-3
# (Docker Engine, native PDM). Deploying the stack itself is left to the
# tests (tests/e2e/t0-deploy.sh), so the documented bootstrap path is what
# gets exercised.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y -qq apache2-utils gettext-base nftables iproute2 >/dev/null
systemctl is-active --quiet docker || { echo "docker not provisioned" >&2; exit 1; }

# Docker Engine itself comes from provision/docker.sh (deployment guide step 2).

# --- Mailpit: lab SMTP sink for Alertmanager (not part of the stack) --------
# Published on the management address; Alertmanager reaches it from its
# container through the host IP. Web/API on :8025 for the alert tests.
if ! docker inspect lab-mailpit >/dev/null 2>&1; then
  docker run -d --name lab-mailpit --restart unless-stopped \
    -p 10.77.10.10:1025:1025 -p 10.77.10.10:8025:8025 axllent/mailpit:v1.31.3 >/dev/null
fi

# --- Native PDM (deployment guide step 3) -----------------------------------
mkdir -p /var/lib/biome-lab/artifacts
# Snapshot of the pre-existing nftables.conf, so the tests can prove
# configure-pdm-firewall.sh appends to it instead of clobbering it.
[[ -f /var/lib/biome-lab/nftables.conf.orig ]] || cp /etc/nftables.conf /var/lib/biome-lab/nftables.conf.orig

if ! dpkg -s proxmox-datacenter-manager >/dev/null 2>&1; then
  curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    -o /usr/share/keyrings/proxmox-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] http://download.proxmox.com/debian/pdm trixie pdm-no-subscription" \
    > /etc/apt/sources.list.d/pdm.list
  echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
  echo "postfix postfix/mailname string monitoring.biome.lab.test" | debconf-set-selections
  apt-get update -qq
  apt-get install -y -qq proxmox-datacenter-manager-container-meta >/dev/null
fi
systemctl is-active proxmox-datacenter-api proxmox-datacenter-privileged-api || true
# PDM's root@pam login is PAM; the tier-3 test uses it to configure a realm
# through the API. Lab-only value.
echo 'root:biome-lab-root' | chpasswd
echo "[monitoring] provisioned: $(docker --version); $(docker compose version)"
