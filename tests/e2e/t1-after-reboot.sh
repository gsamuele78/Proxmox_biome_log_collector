#!/usr/bin/env bash
# Tier 1, monitoring VM as root, after `vagrant reload monitoring`: the PDM
# firewall and the stack must come back on their own.
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
cd "${REPO}" || exit 1

check "nftables.service enabled" systemctl is-enabled --quiet nftables.service
check "nft table inet proxmox_biome_pdm survived the reboot" nft list table inet proxmox_biome_pdm
check "/etc/nftables.conf still has exactly one include line" \
  test "$(grep -c 'nftables.d/\*.nft' /etc/nftables.conf)" = 1
wait_for "stack healthy again after reboot (restart: unless-stopped)" 300 all_healthy
wait_for "PDM via Traefik -> 200 after reboot" 120 \
  sh -c "[ \"\$(curl -sk -o /dev/null -w '%{http_code}' --resolve pdm.${DOMAIN}:443:127.0.0.1 -u '$(basic_auth)' https://pdm.${DOMAIN}/)\" = 200 ]"
check "cv4pve-diag.timer active after reboot" systemctl is-active --quiet cv4pve-diag.timer

summary
