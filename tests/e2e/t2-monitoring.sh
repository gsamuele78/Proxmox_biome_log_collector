#!/usr/bin/env bash
# Tier 2, monitoring VM as root: Prometheus scrapes the whole cluster and
# every Ceph mgr, cv4pve sees all nodes, logs arrive from every node.
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
cd "${REPO}" || exit 1

cat > config/prometheus/targets/proxmox-nodes.json <<'JSON'
[{"targets":["10.77.10.11:9100","10.77.10.12:9100","10.77.10.13:9100"],"labels":{"job":"proxmox-node-exporter","cluster":"biome-lab"}}]
JSON
# Every mgr host, as the deployment guide says (failover moves the exporter).
cat > config/prometheus/targets/ceph-mgr.json <<'JSON'
[{"targets":["10.77.10.11:9283","10.77.10.12:9283","10.77.10.13:9283"],"labels":{"job":"ceph-mgr-prometheus","cluster":"biome-lab"}}]
JSON

wait_for "3 node exporters up" 180 prom_true 'count(up{job="proxmox-node-exporter"} == 1) == 3'
wait_for "ceph_health_status scraped" 180 prom_true 'ceph_health_status'
wait_for "Prometheus sees 3 OSDs up" 120 prom_true 'sum(ceph_osd_up) == 3'
echo "INFO  ceph-mgr targets: $(prom_query 'up{job="ceph-mgr-prometheus"}' | jq -c '[.[] | {i: .metric.instance, up: .value[1]}]')"
check "exactly one ceph_health_status series (standbys add no duplicates)" \
  prom_true 'count(ceph_health_status) == 1'
prom_query 'ceph_health_status' | jq -r '.[0].metric.instance // empty' > /var/lib/biome-lab/ceph-active-instance
check_not "CephHealthError not firing" alert_firing CephHealthError
check_not "CephMgrExporterAbsent not firing" alert_firing CephMgrExporterAbsent
wait_for "cv4pve sees 3 nodes (cv4pve_node_info)" 180 prom_true 'count(cv4pve_node_info) == 3'
for n in pve2 pve3; do
  wait_for "Loki has journal lines from ${n}" 180 loki_has "{job=\"systemd-journal\",host=\"${n}\"}"
done

summary
