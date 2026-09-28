#!/usr/bin/env bash
# Ceph across every lab node, driven from the last node over the cluster's
# own root SSH trust: packages, one mon + mgr and one OSD (/dev/vdb) per
# node, a size-3 pool. Memory is capped for a small lab. Idempotent.
set -euo pipefail
nodes=("$@")
on() { local n="$1"; shift; ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${n}" "$@"; }

for n in "${nodes[@]}"; do
  if ! on "${n}" "command -v ceph-osd >/dev/null"; then
    echo "[ceph] installing packages on ${n}"
    on "${n}" "yes | pveceph install --repository no-subscription --version squid >/dev/null"
  fi
done

[[ -f /etc/pve/ceph.conf ]] || on "${nodes[0]}" "pveceph init --network 10.77.10.0/24"

for n in "${nodes[@]}"; do
  on "${n}" "test -d /var/lib/ceph/mon/ceph-${n} || pveceph mon create"
  on "${n}" "test -d /var/lib/ceph/mgr/ceph-${n} || pveceph mgr create"
done
# Lab VMs have ~3 GB each; the Ceph default OSD target is 4 GiB.
ceph config set osd osd_memory_target 939524096
ceph config set mon mon_warn_on_insecure_global_id_reclaim_allowed false

for n in "${nodes[@]}"; do
  on "${n}" "ceph-volume lvm list /dev/vdb >/dev/null 2>&1 || pveceph osd create /dev/vdb"
done
ceph osd pool ls | grep -qx rbd || pveceph pool create rbd --size 3 --min_size 2 --pg_num 32 --add_storages 0

for _ in $(seq 60); do
  [[ "$(ceph osd stat -f json | jq '.num_up_osds')" == "${#nodes[@]}" ]] && ceph health | grep -q HEALTH_OK && break
  sleep 10
done
ceph -s
