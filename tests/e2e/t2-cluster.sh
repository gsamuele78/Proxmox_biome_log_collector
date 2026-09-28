#!/usr/bin/env bash
# Tier 2, on pve1 as root: the 3-node cluster and Ceph are healthy, then
# the repo's enable-ceph-prometheus.sh turns on the mgr exporter.
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
cd "${REPO}" || exit 1

check "cluster quorate" sh -c 'pvecm status | grep -q "Quorate: *Yes"'
check "cluster has 3 nodes" test "$(pvecm nodes | grep -cE ' pve[123]')" = 3
wait_for "Ceph HEALTH_OK" 300 sh -c 'ceph health | grep -q HEALTH_OK'
check "3 OSDs up and in" test "$(ceph osd stat -f json | jq '.num_up_osds + .num_in_osds')" = 6
check "3 mgr daemons (1 active + 2 standby)" \
  test "$(ceph mgr dump -f json | jq '(.standbys | length) + 1')" = 3

if scripts/node-setup/enable-ceph-prometheus.sh > "${ARTIFACTS}/enable-ceph-prometheus.log" 2>&1; then
  pass "scripts/node-setup/enable-ceph-prometheus.sh"
else
  fail "enable-ceph-prometheus.sh"; tail -20 "${ARTIFACTS}/enable-ceph-prometheus.log"
fi
check "enable-ceph-prometheus.sh is idempotent (2nd run)" scripts/node-setup/enable-ceph-prometheus.sh
wait_for "mgr reports a prometheus endpoint" 120 sh -c 'ceph mgr services -f json | jq -e .prometheus'
active="$(ceph mgr dump -f json | jq -r .active_name)"
check "active mgr (${active}) serves ceph_health_status on :9283" \
  sh -c "curl -sf --max-time 10 http://${active}:9283/metrics | grep -q '^ceph_health_status'"
for n in pve1 pve2 pve3; do
  [[ "${n}" == "${active}" ]] && continue
  echo "INFO  standby ${n}:9283 -> HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${n}:9283/metrics")"
done

summary
