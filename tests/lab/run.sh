#!/usr/bin/env bash
# Host-side driver for the lab: pushes the working tree into the VMs, runs
# the e2e phases in order, does the cross-VM glue (PVE token hand-off,
# reboot) and the perimeter checks that only the host can do.
#
#   TIER=0|1 tests/lab/run.sh        (VMs must be up: make lab-up TIER=...)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
export TIER="${TIER:-1}"
mkdir -p artifacts
log="artifacts/run-$(date +%Y%m%dT%H%M%S).log"
exec > >(tee "${log}") 2>&1

declare -a results=()
phase() {  # phase "name" vm command...
  local name="$1" vm="$2"; shift 2
  echo; echo "######## ${name} (${vm})"
  if vagrant ssh "${vm}" -c "sudo $*"; then results+=("OK    ${name}"); else results+=("FAIL  ${name}"); fi
}
host_check() {  # host_check "description" expect(ok|fail) command...
  local desc="$1" expect="$2"; shift 2
  if "$@" >/dev/null 2>&1; then got=ok; else got=fail; fi
  if [[ "${got}" == "${expect}" ]]; then echo "PASS  ${desc}"; return 0; fi
  echo "FAIL  ${desc}"; return 1
}

e2e=/opt/proxmox-biome/tests/e2e
echo "== biome lab run, TIER=${TIER}"
vagrant rsync
# `vagrant rsync` silently skips a VM whose synced-folder metadata was never
# written (an interrupted first `vagrant up`), and every phase would then
# fail with "No such file". Sync such a VM by name, or stop here.
vms=(monitoring)
((TIER >= 1)) && vms+=(pve1)
((TIER >= 2)) && vms+=(pve2 pve3)
for vm in "${vms[@]}"; do
  vagrant ssh "${vm}" -c "test -f ${e2e}/lib.sh" 2>/dev/null && continue
  vagrant rsync "${vm}"
  vagrant ssh "${vm}" -c "test -f ${e2e}/lib.sh" 2>/dev/null \
    || { echo "FATAL: the repo is not synced into ${vm} (${e2e}/lib.sh missing)"; exit 1; }
done
phase "t0 smoke test + secret file modes" monitoring "bash ${e2e}/t0-smoke.sh"

token=""
if ((TIER >= 1)); then
  token="$(vagrant ssh pve1 -c "sudo jq -r .value /root/pve-token.json" 2>/dev/null | tr -d '\r')"
  [[ -n "${token}" ]] || echo "WARNING: no PVE token from pve1; cv4pve checks will fail"
fi
phase "t0 bootstrap deployment" monitoring "PVE_TOKEN_SECRET='${token}' bash ${e2e}/t0-deploy.sh"

if ((TIER >= 1)); then
  phase "t1 node agents on pve1" pve1 "bash ${e2e}/t1-node.sh"
  phase "t1 monitoring <- real PVE" monitoring "bash ${e2e}/t1-monitoring.sh"
  phase "t1 reachability from mgmt LAN" pve1 "bash ${e2e}/t1-pve-reachability.sh"
  phase "t1 PegaProx overlay" monitoring "bash ${e2e}/t1-pegaprox.sh"
  phase "t1 internal-CA TLS" monitoring "bash ${e2e}/t1-internal-ca.sh"

  echo; echo "######## t1 perimeter view (host)"
  ok=0
  host_check "Loki :3100 NOT reachable on the perimeter address" fail \
    curl -sf --max-time 5 http://10.77.20.10:3100/ready || ok=1
  host_check "PDM :8443 NOT reachable on the perimeter address" fail \
    curl -sk --max-time 5 https://10.77.20.10:8443/ || ok=1
  host_check "Traefik :443 reachable on the perimeter address" ok \
    curl -sk -o /dev/null --max-time 5 https://10.77.20.10/ || ok=1
  if ((ok == 0)); then results+=("OK    t1 perimeter view"); else results+=("FAIL  t1 perimeter view"); fi

  echo; echo "######## reboot monitoring"
  vagrant reload monitoring --no-provision
  phase "t1 after reboot" monitoring "bash ${e2e}/t1-after-reboot.sh"
  phase "t1 reachability after reboot" pve1 "bash ${e2e}/t1-pve-reachability.sh"
fi

if ((TIER >= 2)); then
  for n in pve2 pve3; do phase "t2 node agents on ${n}" "${n}" "bash ${e2e}/t1-node.sh"; done
  phase "t2 cluster + Ceph on pve1" pve1 "bash ${e2e}/t2-cluster.sh"
  phase "t2 monitoring <- whole cluster" monitoring "bash ${e2e}/t2-monitoring.sh"

  phase "t2 Ceph mgr failover" pve1 "bash ${e2e}/t2-pve-action.sh mgr-fail"
  phase "t2 metrics follow the new active mgr" monitoring "bash ${e2e}/t2-after-failover.sh"

  phase "t2 stop pve2's OSD" pve2 "bash ${e2e}/t2-pve-action.sh osd-stop"
  phase "t2 CephOSDDown fires + mails" monitoring "bash ${e2e}/t2-alert.sh CephOSDDown firing 540"
  phase "t2 start pve2's OSD" pve2 "bash ${e2e}/t2-pve-action.sh osd-start"
  phase "t2 CephOSDDown resolves" monitoring "bash ${e2e}/t2-alert.sh CephOSDDown resolved 300"

  echo; echo "######## power off pve1"
  vagrant halt pve1
  phase "t2 ProxmoxNodeDown fires + mails" monitoring "bash ${e2e}/t2-alert.sh ProxmoxNodeDown firing 540"
  phase "t2 cv4pve-diag falls back to pve2" monitoring "bash ${e2e}/t2-diag-fallback.sh"
  echo; echo "######## power pve1 back on"
  vagrant up pve1 --no-provision
  phase "t2 ProxmoxNodeDown resolves" monitoring "bash ${e2e}/t2-alert.sh ProxmoxNodeDown resolved 300"
  phase "t2 cluster + Ceph healthy again" pve1 "bash ${e2e}/t2-cluster.sh"
fi

if ((TIER >= 3)); then
  phase "t3 oauth2-proxy + Keycloak in front of audit reports" monitoring "bash ${e2e}/t3-oauth2.sh"
  phase "t3 PVE OpenID realm login" pve1 "bash ${e2e}/t3-pve-oidc.sh"
  phase "t3 PDM OpenID realm" monitoring "bash ${e2e}/t3-pdm-oidc.sh"
fi

echo; echo "######## collecting artifacts"
vagrant ssh monitoring -c "sudo tar -C /var/lib/biome-lab -czf - artifacts" 2>/dev/null \
  | tar -C artifacts -xzf - --transform 's#^artifacts#monitoring#' || true
if ((TIER >= 1)); then
  vagrant ssh pve1 -c "sudo tar -C /var/lib/biome-lab -czf - artifacts" 2>/dev/null \
    | tar -C artifacts -xzf - --transform 's#^artifacts#pve1#' || true
fi

echo; echo "======== SUMMARY (TIER=${TIER}) — full log: tests/lab/${log}"
printf '%s\n' "${results[@]}"
! printf '%s\n' "${results[@]}" | grep -q '^FAIL'
