#!/usr/bin/env bash
# Tier 1, on pve1: what a management-LAN host can and cannot reach on the
# monitoring VM once the PDM firewall is in place.
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"

check_not "PDM :8443 is NOT reachable from the management LAN" \
  curl -sk --max-time 5 https://10.77.10.10:8443/
check "Loki :3100 IS reachable from the management LAN" curl -sf --max-time 5 http://10.77.10.10:3100/ready
check "Traefik :443 reachable from the management LAN" \
  curl -sk -o /dev/null --max-time 5 https://10.77.10.10/

summary
