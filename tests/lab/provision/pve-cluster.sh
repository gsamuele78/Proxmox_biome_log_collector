#!/usr/bin/env bash
# Forms the lab PVE cluster over the mgmt network: the founder (pve1)
# creates it, every other node joins through the API (non-interactive, the
# same call the web UI's "Join Cluster" makes). Idempotent.
set -euo pipefail
action="${1:?usage: pve-cluster.sh create|join <own-mgmt-ip>}"
own_ip="${2:?own mgmt ip}"
founder_ip=10.77.10.11

if [[ -f /etc/pve/corosync.conf ]]; then
  echo "[cluster] $(hostname) already in cluster: $(pvecm status | awk -F': *' '/^Name:/ {print $2}')"
  exit 0
fi

case "${action}" in
  create)
    pvecm create biome-lab --link0 "${own_ip}"
    ;;
  join)
    fingerprint="$(openssl s_client -connect "${founder_ip}:8006" </dev/null 2>/dev/null \
      | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)"
    pvesh create /cluster/config/join --hostname "${founder_ip}" --fingerprint "${fingerprint}" \
      --password biome-lab-root --link0 "${own_ip}" || true
    ;;
  *) echo "unknown action ${action}" >&2; exit 2 ;;
esac

# Both paths restart corosync/pve-cluster underneath us ("Cannot initialize
# CMAP service" right after `pvecm create`); wait until the node is quorate.
for _ in $(seq 60); do
  if [[ -f /etc/pve/corosync.conf ]] && pvecm status 2>/dev/null | grep -q 'Quorate: *Yes'; then
    pvecm status | grep -E 'Name:|Nodes:|Quorate:'
    exit 0
  fi
  sleep 5
done
echo "[cluster] $(hostname) not quorate after 5 minutes" >&2
exit 1
