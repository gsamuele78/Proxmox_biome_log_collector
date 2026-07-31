#!/usr/bin/env bash
# Fetches known-good, Prometheus-datasource community Grafana dashboards
# fresh from the grafana.com API into
# config/grafana/provisioning/dashboards/files/ (gitignored — always pulled
# live, never vendored stale copies in git; see dashboards.yaml).
#
# Dashboard IDs used here (verified against the grafana.com API — each is
# confirmed Prometheus-based and matches a datasource this stack actually
# provisions):
#   1860 — "Node Exporter Full"   (matches the node-exporter service)
#   2842 — "Ceph Cluster"         (matches the ceph mgr prometheus module)
#
# NOTE: there is no official community dashboard for cv4pve-metrics-exporter
# (verified against github.com/Corsinvest/cv4pve-metrics-exporter — the repo
# ships the exporter only, no dashboard JSON). Corsinvest's published
# dashboards (e.g. "Proxmox VE Node", ID 12910) target their older
# InfluxDB/Telegraf-based cv4pve-metrics stack, not this Prometheus
# exporter's `cv4pve_*` metric names, and were deliberately NOT added here
# to avoid shipping a dashboard that silently shows no data. See
# docs/roadmap.md for building a native cv4pve_* Grafana dashboard.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest_dir="${repo_root}/config/grafana/provisioning/dashboards/files"
mkdir -p "${dest_dir}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}
require_cmd curl
require_cmd python3

declare -A dashboards=(
  ["1860"]="node-exporter-full"
  ["2842"]="ceph-cluster"
)

for id in "${!dashboards[@]}"; do
  name="${dashboards[${id}]}"
  echo "[dashboards] Fetching metadata for dashboard ${id} (${name})..."
  meta_json="$(curl -fsSL "https://grafana.com/api/dashboards/${id}")"
  revision="$(echo "${meta_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["revision"])')"

  echo "[dashboards] Downloading ${name} (id=${id}, revision=${revision})..."
  curl -fsSL "https://grafana.com/api/dashboards/${id}/revisions/${revision}/download" \
    -o "${dest_dir}/${name}.json"
done

echo "[dashboards] Done. Files written to ${dest_dir} (gitignored)."
echo "[dashboards] Restart/reload Grafana or wait up to 300s (updateIntervalSeconds) for auto-pickup."
