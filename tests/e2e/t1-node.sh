#!/usr/bin/env bash
# Tier 1, on pve1 as root: the three node-setup scripts from deployment
# guide step 6, then checks that each agent runs and can read its sources.
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
cd "${REPO}" || exit 1
mkdir -p "${ARTIFACTS}"

for step in install-node-exporter configure-auditd install-alloy-agent; do
  if LOKI_PUSH_URL="http://10.77.10.10:3100/loki/api/v1/push" \
    "scripts/node-setup/${step}.sh" > "${ARTIFACTS}/${step}.log" 2>&1; then
    pass "scripts/node-setup/${step}.sh"
  else
    fail "scripts/node-setup/${step}.sh (see ${ARTIFACTS}/${step}.log)"
    tail -30 "${ARTIFACTS}/${step}.log"
  fi
done

check "prometheus-node-exporter active" systemctl is-active --quiet prometheus-node-exporter
check "node_exporter answers on :9100" curl -sf --max-time 5 http://127.0.0.1:9100/metrics
check "auditd active" systemctl is-active --quiet auditd
check "auditd rule on /etc/pve loaded" sh -c 'auditctl -l | grep -q proxmox_pve_config'
# Alloy can report "active" for a moment before crash-looping, so wait for
# its own readiness endpoint and require no restarts.
wait_for "alloy ready (http://127.0.0.1:12345/-/ready)" 90 curl -sf --max-time 3 http://127.0.0.1:12345/-/ready
check "alloy has not restarted" test "$(systemctl show -p NRestarts --value alloy)" = 0
check "alloy is in groups adm and systemd-journal" \
  sh -c 'id -nG alloy | tr " " "\n" | grep -qx adm && id -nG alloy | tr " " "\n" | grep -qx systemd-journal'
check "alloy can read /var/log/audit/audit.log" sudo -u alloy test -r /var/log/audit/audit.log
check "Loki push endpoint reachable from the node" curl -sf --max-time 5 http://10.77.10.10:3100/ready

# Generate audit events the Loki test on the monitoring VM looks for.
touch /etc/sudoers.d/zz-biome-lab && rm -f /etc/sudoers.d/zz-biome-lab
touch /etc/pve/biome-lab-marker 2>/dev/null && rm -f /etc/pve/biome-lab-marker
check "audit.log recorded the identity-key event" grep -q 'key="identity"' /var/log/audit/audit.log
logger -t biome-lab "journal marker for the e2e test"

summary
