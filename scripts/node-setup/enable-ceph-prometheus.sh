#!/usr/bin/env bash
# Enables Ceph's built-in `prometheus` mgr module, which exposes
# cluster/OSD/PG metrics on :9283 (internal management LAN — see
# docs/network-port-matrix.md). Only needs to be run ONCE per cluster
# (mgr modules are stored in the Ceph monitor map, not per-node config),
# but is safe to re-run from any node with a functioning `ceph` CLI.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (needs access to the Ceph admin keyring)." >&2
  exit 1
fi

if ! command -v ceph >/dev/null 2>&1; then
  echo "ceph CLI not found — run this on a Proxmox VE node that is part of the Ceph cluster." >&2
  exit 1
fi

echo "[ceph-prometheus] Enabling mgr prometheus module..."
if ceph mgr module ls --format json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "prometheus" in d.get("enabled_modules", []) else 1)'; then
  echo "[ceph-prometheus] Already enabled."
else
  ceph mgr module enable prometheus
fi

echo "[ceph-prometheus] Verifying listener..."
active_mgr="$(ceph mgr services --format json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("prometheus","not-found"))')"
echo "[ceph-prometheus] Active mgr prometheus endpoint: ${active_mgr}"
echo "[ceph-prometheus] Add the active mgr's mgmt-LAN IP/hostname (port 9283) to"
echo "  config/prometheus/targets/ceph-mgr.json on the monitoring VM."
echo "[ceph-prometheus] Note: on mgr failover, the active mgr (and thus which host answers"
echo "  on :9283) changes — list ALL mgr hosts as targets so Prometheus's 'up' series"
echo "  tracks the failover instead of just going stale."
