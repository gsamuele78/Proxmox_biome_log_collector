#!/usr/bin/env bash
# Installs and configures auditd on a Proxmox VE node with rules watching
# the cluster config filesystem (/etc/pve, pmxcfs) and key system files —
# NIS2 Art. 21 traceability/access-control evidence (see
# docs/hardening.md's control-mapping table). Run as root on each node.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (needed to install packages and manage systemd/auditd rules)." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script targets Debian/Proxmox VE hosts (apt-get not found)." >&2
  exit 1
fi

echo "[auditd] Installing auditd..."
apt-get update
apt-get install -y auditd audispd-plugins

rules_file="/etc/audit/rules.d/proxmox-biome.rules"
echo "[auditd] Writing ${rules_file}..."
cat > "${rules_file}" <<'EOF'
## Proxmox Biome NIS2 traceability rules.
## /etc/pve is the pmxcfs FUSE-mounted cluster config filesystem — VM/LXC
## definitions, cluster firewall rules, ACLs, storage config, certs. Changes
## here ARE the audit trail for "who changed what" across the cluster.
-w /etc/pve -p wa -k proxmox_pve_config

## Local (non-cluster-synced) system auth/config — changes here matter even
## though they're per-node, not cluster-wide.
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
-w /etc/sudoers.d/ -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd_config

## Privilege escalation / admin actions. Commented out by default: on a busy
## hypervisor this fires on every root-owned process exec (cron jobs, VM
## lifecycle helpers, etc.) and can generate very high log volume. Uncomment
## if your NIS2 risk assessment requires syscall-level root-action tracing
## and you've sized Loki retention/storage for it.
# -a always,exit -F arch=b64 -S execve -F euid=0 -k root_actions
EOF

echo "[auditd] Loading rules..."
augenrules --load

echo "[auditd] Enabling and restarting service..."
systemctl enable --now auditd
systemctl restart auditd

echo "[auditd] Done. Verify with: auditctl -l"
echo "[auditd] Alloy (once installed via install-alloy-agent.sh) ships /var/log/audit/audit.log to Loki under job=auditd."
