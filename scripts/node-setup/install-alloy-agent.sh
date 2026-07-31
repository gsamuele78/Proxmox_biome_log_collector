#!/usr/bin/env bash
# Installs Grafana Alloy on a Proxmox VE node and renders
# config/alloy/config.alloy.tmpl into /etc/alloy/config.alloy, pointed at
# the monitoring VM's Loki ingest endpoint over the internal management LAN
# (see ADR-0004 for why Alloy and not Promtail — Promtail is EOL 2026-03).
#
# Run as root ON each PVE node. Requires the repo checked out somewhere
# reachable (or just this script + the rendered template copied over) and
# the LOKI_PUSH_URL env var, e.g.:
#   LOKI_PUSH_URL=http://monitoring-vm.mgmt.example.internal:3100/loki/api/v1/push \
#     ./install-alloy-agent.sh
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (needed to install packages and manage systemd)." >&2
  exit 1
fi

: "${LOKI_PUSH_URL:?Set LOKI_PUSH_URL, e.g. http://monitoring-vm.mgmt.example.internal:3100/loki/api/v1/push}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="${script_dir}/../../config/alloy/config.alloy.tmpl"

if [[ ! -f "${template}" ]]; then
  echo "Template not found at ${template} — run this script from a checkout of the repo." >&2
  exit 1
fi

echo "[alloy] Installing GPG/apt prerequisites..."
apt-get update
apt-get install -y gpg curl

echo "[alloy] Adding Grafana apt repository..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list

echo "[alloy] Installing Alloy..."
apt-get update
apt-get install -y alloy

echo "[alloy] Rendering config.alloy from template..."
mkdir -p /etc/alloy
sed "s#__LOKI_PUSH_URL__#${LOKI_PUSH_URL}#g" "${template}" > /etc/alloy/config.alloy
chmod 640 /etc/alloy/config.alloy

echo "[alloy] Enabling and starting service..."
systemctl enable --now alloy
systemctl restart alloy

echo "[alloy] Done. Check status with: systemctl status alloy"
echo "[alloy] Logs should appear in Loki/Grafana under job=systemd-journal, job=pve-firewall, job=auditd."
