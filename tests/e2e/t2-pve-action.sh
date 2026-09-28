#!/usr/bin/env bash
# Tier 2, on a PVE node as root: fault injection for the alert tests.
#   mgr-fail   fail over the active Ceph mgr and check a standby took over
#   osd-stop   stop this node's OSD      osd-start  start it again
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
osd_id() { ceph osd ls-tree "$(hostname)" | head -1; }

case "${1:?action}" in
  mgr-fail)
    before="$(ceph mgr dump -f json | jq -r .active_name)"
    ceph mgr fail "${before}"
    wait_for "a standby mgr took over from ${before}" 120 \
      sh -c "a=\$(ceph mgr dump -f json | jq -r .active_name); [ -n \"\$a\" ] && [ \"\$a\" != '${before}' ] && [ \"\$a\" != null ]"
    echo "INFO  active mgr now $(ceph mgr dump -f json | jq -r .active_name)"
    ;;
  osd-stop)
    id="$(osd_id)"
    systemctl stop "ceph-osd@${id}"
    wait_for "osd.${id} reported down" 120 sh -c "ceph osd dump -f json | jq -e '.osds[] | select(.osd==${id}) | .up == 0'"
    ;;
  osd-start)
    id="$(osd_id)"
    systemctl start "ceph-osd@${id}"
    wait_for "osd.${id} back up" 180 sh -c "ceph osd dump -f json | jq -e '.osds[] | select(.osd==${id}) | .up == 1'"
    ;;
  *) echo "unknown action" >&2; exit 2 ;;
esac
summary
