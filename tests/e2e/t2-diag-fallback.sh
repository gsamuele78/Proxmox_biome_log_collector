#!/usr/bin/env bash
# Tier 2, monitoring VM as root, while pve1 is powered off: cv4pve-diag with
# CV4PVE_DIAG_HOSTS="pve1,pve2" must fall back to pve2 and still report.
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
cd "${REPO}" || exit 1

check_not "pve1 API is really down" curl -sk --max-time 5 https://10.77.10.11:8006/
cp .env /var/lib/biome-lab/env.before-fallback
sed -i 's/^CV4PVE_DIAG_HOSTS=.*/CV4PVE_DIAG_HOSTS=10.77.10.11,10.77.10.12/' .env
if scripts/run-cv4pve-diag.sh > "${ARTIFACTS}/diag-fallback.log" 2>&1; then
  pass "run-cv4pve-diag.sh succeeded with the first host down (fell back to pve2)"
else
  fail "run-cv4pve-diag.sh with fallback host"; tail -20 "${ARTIFACTS}/diag-fallback.log"
fi
cp /var/lib/biome-lab/env.before-fallback .env
summary
