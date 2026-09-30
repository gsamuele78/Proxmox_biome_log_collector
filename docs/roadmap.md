# Roadmap

Deliberately deferred items — each was considered during the initial
build and postponed for a specific, documented reason rather than
overlooked.

## TLS certificate expiry monitoring (blackbox_exporter)

An earlier draft of `config/prometheus/rules/proxmox.rules.yml` included a
`ProxmoxTLSCertificateExpiringSoon` rule, but it was removed: no exporter
in the current stack actually surfaces certificate-expiry metrics (that
requires `blackbox_exporter`'s `probe_ssl_earliest_cert_expiry`, which
isn't deployed). Adding a rule with no metric behind it would silently
never fire — worse than not having the rule at all.

**Plan**: add `blackbox_exporter` as a new service in `docker-compose.yml`
(Prometheus-scraped, probing `https://*.${BASE_DOMAIN}` endpoints plus any
internally-issued cert used per `docs/deployment-guide.md#tls-certificates`),
then reintroduce the alert rule against its actual metric.

## PegaProx VNC/SSH-websocket console routing

ADR-0008 keeps PegaProx opt-in and explicitly does **not** route its VNC
console (`:5001`) or SSH-over-websocket (`:5002`) ports through Traefik —
only its main web UI (`:5000`). Console access via those ports needs
sticky-session / websocket-upgrade handling that wasn't validated as part
of the initial build.

**Plan**: PegaProx is on stable 1.x since ADR-0008. Next, add Traefik
routers for `:5001`/`:5002` with websocket support, tested end-to-end in
the lab against a real console session (extend `tests/e2e/t1-pegaprox.sh`),
and automate adding the lab cluster through PegaProx's API.

## Guest monitoring from inside the VMs

The `Proxmox cluster and guests (cv4pve)` dashboard (0.3.0,
`config/grafana/provisioning/dashboards/cv4pve/`) shows every VM and LXC
from the PVE API, without an agent in the guest. What is still missing is
the inside view: guest logs (journal, `/var/log`, Windows Event Log) and
in-guest metrics (filesystems, services), plus alert rules on guests
(stopped unexpectedly, no backup job, memory near the limit).

**Plan**: a Grafana Alloy agent in each guest, pushing logs to Loki and
metrics to Prometheus (remote write), labelled with the `vmid` so Grafana
can link the outside and inside views. This lets guests reach the
monitoring VM, which changes the trust boundary (Loki listens only on the
management LAN today), so it needs an ADR first.

## Verification gaps to close on real hardware / CI

Three items that were pushed as far as they could go without a real
Proxmox VM or a Docker daemon in the build environment. Each needs one
concrete confirmation step, listed below, before it can be marked fully
verified in `docs/plan/EXECUTION-PLAN.md`.

### PDM firewall script's host-integration steps

**Closed by `tests/lab/`** (`t1-monitoring.sh`, `t1-after-reboot.sh`): on
a real Debian 13 VM with PDM installed, the script keeps the existing
`/etc/nftables.conf`, adds the include once, is idempotent, survives a
reboot, and blocks 8443 from the management LAN and the perimeter. The lab
also found that `enable --now` flushed Docker's rules (fixed, see
CHANGELOG). Original status, for history: the nftables ruleset `scripts/configure-pdm-firewall.sh`
generates was proven correct with real traffic tests in an isolated
network namespace (loopback accepted, edge subnet accepted, everything
else dropped — see `docs/plan/EXECUTION-PLAN.md`'s Verification section).
Not exercised: `systemctl enable --now nftables.service`, and the
idempotent `/etc/nftables.conf` include-line logic, against a real host
that may already have its own `/etc/nftables.conf` content.

**Plan**: on first real deployment, run the script on the actual
monitoring VM, reboot, confirm `nft list ruleset` still shows
`proxmox_biome_pdm`, and confirm it didn't clobber any pre-existing
`/etc/nftables.conf` content. Record the result in `EXECUTION-PLAN.md`.

### PDM's OIDC realm-add CLI flags

**Closed by `tests/lab/`** (`t3-pdm-oidc.sh`): the CLI has no realm
commands at all, so the old step 3b could not work. The realm is created
through PDM's API (`POST /config/access/openid`), and a full Keycloak
login returns a PDM ticket. `docs/keycloak-integration.md` step 3b now
documents the verified API call. PVE's `pveum realm add` example (step 3)
and the oauth2-proxy flow (step 4) were verified end to end too.

### Integration smoke test end-to-end

**Closed by `tests/lab/`** (`t0-smoke.sh`): `smoke-test.sh` passes on a
real Docker daemon. The first run failed and uncovered the
`compress`/`docker-socket-proxy`/healthcheck bugs listed in the CHANGELOG.
Original status, for history: `docker compose config` (both compose files), `promtool`, and
`amtool` were run for real against static binaries downloaded directly
from their GitHub releases — no daemon needed for config validation, and
this caught a real Alertmanager config bug (see CHANGELOG's `[0.1.0]`
"Fixed" section). What wasn't run: `tests/integration/smoke-test.sh`
itself, which needs a live Docker daemon to actually boot containers,
wait for healthchecks, and curl Traefik-routed paths.

**Plan**: the first green run of
`.github/workflows/validate-and-test.yml` after this is pushed is the
real verification of this gap (GitHub Actions runners have Docker). No
local action needed beyond watching that run.

## Further ahead

- **HA for the monitoring VM itself** — currently a single VM; losing it
  loses metrics/log collection (though not the Proxmox cluster's own
  operation). Worth revisiting once the cluster reaches the upper end of
  its planned 7→11 node growth and monitoring becomes more operationally
  critical.
- **Multi-cluster** — the current design assumes one Proxmox VE cluster.
  Extending `config/prometheus/targets/*.json` and `CV4PVE_*` host lists
  to a second cluster is mechanically straightforward but untested; label
  scrape targets by cluster name before doing this so Grafana dashboards
  can filter per-cluster.
- **PBS (Proxmox Backup Server) job status monitoring** — referenced in
  `docs/hardening.md`'s NIS2 control-mapping table as a gap: this stack
  monitors the Ceph/PVE cluster but not backup-job success/failure, which
  is directly relevant to NIS2's business-continuity pillar.
