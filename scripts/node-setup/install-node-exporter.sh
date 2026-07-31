#!/usr/bin/env bash
# Installs Prometheus node_exporter on a Proxmox VE node, as a systemd
# service, listening on the internal management LAN (not the corporate
# perimeter — see docs/network-port-matrix.md). Run this ON each PVE node
# (as root), not on the monitoring VM.
#
# Uses the distro package where available (Debian trixie ships
# prometheus-node-exporter) rather than hand-rolling a binary download +
# systemd unit, since Proxmox VE 9.x is Debian-trixie-based and the
# packaged version tracks upstream closely enough for this use case.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (needed to install packages and manage systemd)." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script targets Debian/Proxmox VE hosts (apt-get not found)." >&2
  exit 1
fi

echo "[node-exporter] Installing prometheus-node-exporter..."
apt-get update
apt-get install -y prometheus-node-exporter

echo "[node-exporter] Enabling and starting service..."
systemctl enable --now prometheus-node-exporter

echo "[node-exporter] Listening on :9100 (internal LAN only — do not expose to the perimeter)."
echo "[node-exporter] Add this node's mgmt-LAN IP/hostname to config/prometheus/targets/proxmox-nodes.json on the monitoring VM."
systemctl --no-pager status prometheus-node-exporter || true
