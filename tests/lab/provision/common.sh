#!/usr/bin/env bash
# Every lab VM: base tools and name resolution for the lab domain.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# A fresh box runs apt-daily at first boot, and an interrupted `vagrant up`
# can leave an apt-get behind: wait for the dpkg/lists locks instead of
# failing on them. Applies to every later apt call on this VM.
echo 'DPkg::Lock::Timeout "600";' > /etc/apt/apt.conf.d/99biome-lab-lock-timeout

apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg jq rsync python3 chrony >/dev/null

# PVE refuses to install unless the node name resolves to a non-loopback
# address, so drop Debian's "127.0.1.1 <hostname>" line on every VM.
sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
sed -i '/# biome-lab-begin/,/# biome-lab-end/d' /etc/hosts
cat >> /etc/hosts <<'HOSTS'
# biome-lab-begin
10.77.10.10 monitoring.biome.lab.test monitoring grafana.biome.lab.test prometheus.biome.lab.test alertmanager.biome.lab.test audit.biome.lab.test traefik.biome.lab.test pdm.biome.lab.test
10.77.10.11 pve1.biome.lab.test pve1
10.77.10.12 pve2.biome.lab.test pve2
10.77.10.13 pve3.biome.lab.test pve3
10.77.10.20 idp.biome.lab.test idp keycloak.biome.lab.test
# biome-lab-end
HOSTS
