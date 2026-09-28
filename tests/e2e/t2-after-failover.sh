#!/usr/bin/env bash
# Tier 2, monitoring VM as root, after `ceph mgr fail`: because every mgr
# host is listed in ceph-mgr.json, Ceph metrics must move to the new active
# mgr on their own, with no gap long enough to fire CephMgrExporterAbsent.
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"

before="$(cat /var/lib/biome-lab/ceph-active-instance 2>/dev/null || true)"
moved() {
  local now
  now="$(prom_query 'ceph_health_status' | jq -r '.[0].metric.instance // empty')"
  [[ -n "${now}" && "${now}" != "${before}" ]] && prom_true 'count(ceph_health_status) == 1'
}
wait_for "ceph_health_status now comes from a different mgr than ${before:-?}" 240 moved
echo "INFO  now scraped from $(prom_query 'ceph_health_status' | jq -r '.[0].metric.instance')"
check_not "CephMgrExporterAbsent did not fire" alert_firing CephMgrExporterAbsent
summary
