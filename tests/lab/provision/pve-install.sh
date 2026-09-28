#!/usr/bin/env bash
# Proxmox VE 9 on Debian 13, per the upstream "Install Proxmox VE on Debian
# 13 Trixie" procedure, in two phases around the reboot into the PVE kernel.
# Also creates the least-privilege API token and one small LXC guest.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
phase="${1:?usage: pve-install.sh kernel|packages [founder|member]}"
role="${2:-founder}"

keyring=/usr/share/keyrings/proxmox-archive-keyring.gpg

case "${phase}" in
  kernel)
    if dpkg -s proxmox-ve >/dev/null 2>&1; then echo "[pve] already installed"; exit 0; fi
    curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -o "${keyring}"
    cat > /etc/apt/sources.list.d/pve-install-repo.sources <<SRC
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: ${keyring}
SRC
    apt-get update -qq
    # One lab run failed in grub-pc's postinst during this upgrade (Proxmox's
    # grub 2.12-9+pmx2, debconf install_devices_failed_upgrade=true; not
    # reproduced since). Pin the install device to the real root disk so the
    # non-interactive postinst never has a question to ask.
    root_disk="/dev/$(lsblk -no pkname "$(findmnt -no SOURCE /)")"
    echo "grub-pc grub-pc/install_devices multiselect ${root_disk}" | debconf-set-selections
    apt-get full-upgrade -y -qq >/dev/null
    apt-get install -y -qq proxmox-default-kernel >/dev/null
    echo "[pve] PVE kernel installed, rebooting"
    ;;

  packages)
    if ! dpkg -s proxmox-ve >/dev/null 2>&1; then
      echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
      echo "postfix postfix/mailname string $(hostname -f)" | debconf-set-selections
      apt-get install -y -qq proxmox-ve postfix open-iscsi chrony >/dev/null
      apt-get remove -y -qq linux-image-amd64 'linux-image-6.12*' os-prober >/dev/null || true
      update-grub >/dev/null 2>&1 || true
      # No subscription in the lab: drop the enterprise repos the packages add.
      rm -f /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources
    fi
    systemctl is-active --quiet pveproxy

    # A joining node must be empty and gets the cluster's /etc/pve on join,
    # so users, tokens and guests are only created on the founder.
    if [[ "${role}" != founder ]]; then echo "[pve] $(pveversion) (member)"; exit 0; fi

    # root@pam password: only used by the other lab nodes to join the
    # cluster through the API (provision/pve-cluster.sh). Lab-only value.
    echo 'root:biome-lab-root' | chpasswd

    # Read-only API token, as .env.example recommends (PVEAuditor, no
    # privilege separation so the token inherits the user's ACL).
    pveum user list --output-format json | jq -e '.[] | select(.userid=="monitoring@pve")' >/dev/null \
      || pveum user add monitoring@pve --comment "biome lab monitoring"
    pveum acl modify / --users monitoring@pve --roles PVEAuditor
    if [[ ! -s /root/pve-token.json ]]; then
      pveum user token remove monitoring@pve observability >/dev/null 2>&1 || true
      pveum user token add monitoring@pve observability --privsep 0 --output-format json > /root/pve-token.json
      chmod 600 /root/pve-token.json
    fi

    # One small container so cv4pve has a guest to report on. Not fatal:
    # the stack tests do not depend on it. nesting=1 is required for
    # systemd 257 guests (Debian 13), or the container fails to start.
    (
      if ! pct status 100 >/dev/null 2>&1; then
        pveam update >/dev/null
        tmpl="$(pveam available --section system | awk '/debian-13-standard.*_amd64/ {print $2}' | tail -1)"
        pveam download local "${tmpl}" >/dev/null
        pct create 100 "local:vztmpl/${tmpl}" --hostname lab-ct --memory 256 --rootfs local:2 \
          --unprivileged 1 --features nesting=1
      fi
      pct set 100 --features nesting=1
      pct status 100 | grep -q running || pct start 100
    ) || echo "[pve] WARNING: LXC guest creation failed (non-fatal)"
    echo "[pve] $(pveversion)"
    ;;
  *) echo "unknown phase ${phase}" >&2; exit 2 ;;
esac
