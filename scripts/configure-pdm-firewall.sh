#!/usr/bin/env bash
# Restricts the natively-installed Proxmox Datacenter Manager's web/API
# daemon (tcp/8443) to loopback + the Docker `monitoring-edge` network only.
#
# Why this exists instead of a PDM config setting: PDM's API daemon (like
# Proxmox Backup Server's proxy it's built on) has NO configurable listen
# address — no `LISTEN_IP` equivalent exists for it, unlike PVE's pveproxy.
# It always binds 0.0.0.0:8443. Verified against Proxmox staff statements on
# the official forum (forum.proxmox.com) confirming PBS's proxy has no
# supported bind-address override, and that PDM's daemon has the same
# limitation. See ADR-0003 for the full reasoning; this script is that
# ADR's actual isolation mechanism.
#
# Run once, as root, on the monitoring VM itself (not a PVE node).
set -euo pipefail

# Must match docker-compose.yml's `networks.edge.ipam.config[0].subnet`.
EDGE_SUBNET="172.28.0.0/24"
NFT_FILE="/etc/nftables.d/proxmox-biome-pdm.nft"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

if ! command -v nft >/dev/null 2>&1; then
  echo "Installing nftables..."
  apt-get update -qq
  apt-get install -y nftables
fi

mkdir -p /etc/nftables.d

cat > "${NFT_FILE}" <<EOF
#!/usr/sbin/nft -f
# Managed by scripts/configure-pdm-firewall.sh — do not edit by hand.
# Restricts PDM (tcp/8443) to loopback and the Docker edge network only.
# A separate base chain at the input hook: nftables evaluates every base
# chain at a hook independently, so this drop takes effect regardless of
# what any other table's input chain (e.g. the host's main firewall) does.
# Declare-then-delete makes re-running this file idempotent: without it,
# every "nft -f" run appends another copy of the rules to the existing chain.
table inet proxmox_biome_pdm
delete table inet proxmox_biome_pdm

table inet proxmox_biome_pdm {
    chain input {
        type filter hook input priority filter; policy accept;
        tcp dport 8443 ip saddr 127.0.0.1 accept
        tcp dport 8443 ip saddr ${EDGE_SUBNET} accept
        tcp dport 8443 drop
    }
}
EOF
chmod 644 "${NFT_FILE}"

# Idempotent: only add the include line if it isn't already present.
if [[ -f /etc/nftables.conf ]] && ! grep -q 'nftables.d/\*.nft' /etc/nftables.conf; then
  echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
fi

nft -f "${NFT_FILE}"
# enable, NOT --now: starting nftables.service loads /etc/nftables.conf,
# whose Debian default begins with `flush ruleset` — that would wipe the
# rules Docker installed (NAT/forwarding) and cut every container off the
# network until dockerd restarts. At boot the order is safe: nftables.service
# runs before network-pre.target, dockerd adds its rules afterwards.
systemctl enable nftables.service

echo "PDM (tcp/8443) is now firewalled to loopback + ${EDGE_SUBNET} only."
echo "Verify with: nft list table inet proxmox_biome_pdm"
echo "NOTE: never 'systemctl restart nftables' on this host without 'systemctl restart docker' right after (flush ruleset drops Docker's rules)."
