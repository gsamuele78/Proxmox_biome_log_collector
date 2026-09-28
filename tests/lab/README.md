# Local KVM/libvirt test lab

Vagrant + libvirt VMs that run the stack for real: a Docker daemon, native
PDM, and a real Proxmox VE 9 node. CI can't cover that (see
`tests/README.md`, "What's verified vs. documented-only").

## Requirements

- Vagrant with the `vagrant-libvirt` plugin, `qemu:///system` access
  (user in the `libvirt` group), nested virtualization enabled
  (`/sys/module/kvm_intel/parameters/nested` = `Y`).
- Free RAM / disk in libvirt's `default` pool: tier 1 about 9 GB / 15 GB,
  tier 2 about 15 GB / 35 GB, tier 3 about 16.5 GB / 40 GB.
- The `debian/trixie64` box (`vagrant box add debian/trixie64 --provider libvirt`).

## Usage

```bash
make lab-up            # TIER=1 by default: monitoring + pve1 (~15 min first time)
make lab-test          # runs every phase, prints a summary, exit 1 on any failure
make lab-destroy       # destroys every lab VM, whatever tier created it
make lab-up TIER=2 && make lab-test TIER=2   # + pve2, pve3, Ceph (~45 min up, ~40 min test)
make lab-up TIER=3 && make lab-test TIER=3   # + Keycloak (adds ~5 min)
```

Tiers are cumulative: `lab-test TIER=3` runs every phase of tiers 0-3.

`make lab-test` rsyncs the working tree into the VMs first, so after
editing the repo you re-run it without re-provisioning. Logs and
artifacts (bootstrap log, smoke-test log, a real cv4pve-diag NIS2 report,
the list of `cv4pve_*` metric names) end up in `tests/lab/artifacts/`
(gitignored).

## Topology

| VM | Addresses | Role |
| --- | --- | --- |
| `monitoring` | mgmt `10.77.10.10`, perimeter `10.77.20.10` | Docker stack, native PDM, systemd timer, Mailpit SMTP sink (`:1025`, UI/API `:8025`) |
| `pve1` | mgmt `10.77.10.11` | PVE 9 on Debian 13, cluster founder, API token `monitoring@pve!observability` (PVEAuditor), one LXC guest |
| `pve2`, `pve3` (tier 2) | mgmt `10.77.10.12`, `.13` | cluster members (joined through the API); every node runs a Ceph mon, mgr and one OSD (`/dev/vdb`), pool `rbd` size 3 |
| `idp` (tier 3) | mgmt `10.77.10.20` | Keycloak 26 (`keycloak.biome.lab.test:8080`), realm `lab` from `keycloak/lab-realm.json`, user `labuser`/`labpass` |

Lab-only credentials (never reuse): PVE and PDM `root@pam` password
`biome-lab-root`, Keycloak admin `admin`/`biome-lab-admin`, OIDC client
secret `biome-lab-client-secret`.

Both lab networks are isolated libvirt networks (`biome-lab-mgmt`,
`biome-lab-perimeter`); the host is `.1` on each, which is how the
perimeter checks run from the host. Lab domain: `biome.lab.test`.

To open Grafana from the host browser, add
`10.77.20.10 grafana.biome.lab.test` to the host's `/etc/hosts` and
accept the self-signed certificate. The basic-auth password for the other
services is in `/var/lib/biome-lab/basic-auth` on `monitoring`.

## What each phase proves

| Phase | Where | Checks |
| --- | --- | --- |
| `t0-smoke.sh` | monitoring | `tests/integration/smoke-test.sh` on a real daemon (from a clean copy); `generate-secrets.sh` file modes as root and non-root |
| `t0-deploy.sh` | monitoring | `bootstrap-monitoring-vm.sh` with `lab.env`; file ownership; all healthchecks; Traefik basic auth 401/200; HTTP→HTTPS; Loki bound only to `LOKI_BIND_ADDR`; every in-stack scrape target up; rules loaded |
| `t1-node.sh` | pve1 | the three `node-setup` scripts; agents running and ready; Alloy can read audit.log |
| `t1-monitoring.sh` | monitoring | node + cv4pve exporter scraped from the real API; pve1 logs in Loki; PDM firewall script (idempotent, keeps `nftables.conf`, leaves Docker's rules alone); PDM through Traefik; cv4pve-diag via the systemd unit, report served |
| `t1-pve-reachability.sh` | pve1 | 8443 blocked from the management LAN, 3100/443 reachable |
| perimeter view | host | 3100 and 8443 closed on the perimeter address, 443 open |
| `t1-after-reboot.sh` | monitoring | firewall and stack come back after `vagrant reload` |
| `t2-cluster.sh` | pve1 | quorate 3-node cluster, Ceph `HEALTH_OK`, 3 OSDs, 3 mgrs; `enable-ceph-prometheus.sh` (idempotent) |
| `t2-monitoring.sh` | monitoring | 3 node exporters, every mgr listed as a target but exactly one `ceph_health_status` series, cv4pve sees 3 nodes, logs from every node |
| mgr failover | pve1 → monitoring | `ceph mgr fail`: metrics move to the new active mgr, `CephMgrExporterAbsent` stays quiet |
| OSD down | pve2 → monitoring | stop an OSD: `CephOSDDown` fires and its mail reaches Mailpit; start it: resolves |
| node down | host → monitoring | `vagrant halt pve1`: `ProxmoxNodeDown` fires and mails; cv4pve-diag falls back to pve2; power on: resolves, Ceph healthy again |
| `t3-oauth2.sh` | monitoring | keycloak profile + lab overlay (audit router on `oauth2-proxy-auth`): redirect to Keycloak with PKCE, scripted login through `/oauth2/callback` back to the reports; other routers stay on basic auth |
| `t3-pve-oidc.sh` | pve1 | the documented `pveum realm add` command, then a full login ending in a PVE ticket for `labuser@keycloak` |
| `t3-pdm-oidc.sh` | monitoring | PDM OpenID realm through the API (the CLI has none), then a full login ending in a PDM ticket |
