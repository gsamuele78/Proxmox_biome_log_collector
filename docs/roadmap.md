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

ADR-0005 keeps PegaProx opt-in and explicitly does **not** route its VNC
console (`:5001`) or SSH-over-websocket (`:5002`) ports through Traefik —
only its main web UI (`:5000`). Console access via those ports needs
sticky-session / websocket-upgrade handling that wasn't validated as part
of the initial build.

**Plan**: once PegaProx graduates past EXPERIMENTAL/BETA status (per
ADR-0005's stated re-evaluation trigger), add Traefik routers for `:5001`/
`:5002` with `websocket` middleware support tested end-to-end against a
real console session, not just the main UI.

## Native `cv4pve_*` Grafana dashboard

`scripts/fetch-community-dashboards.sh` pulls two verified official
dashboards (Node Exporter Full #1860, Ceph Cluster #2842). No official
Grafana dashboard exists for `cv4pve-metrics-exporter`'s
`cv4pve_*` metric namespace — dashboard #10347 is built for the older,
different `prometheus-pve-exporter` project, and Corsinvest's own
dashboard #12910 targets their separate InfluxDB-based `cv4pve-metrics`
stack, not the Prometheus-based exporter this repo uses. Both were
verified and ruled out rather than used on the assumption they'd fit.

**Plan**: hand-build a dashboard against `cv4pve-metrics-exporter`'s
actual exposed metric names (inspect `https://prometheus.${BASE_DOMAIN}/`
→ `cv4pve_*` after the exporter has been running against a real cluster)
covering VM/LXC/storage-object state that `node_exporter` and Ceph's own
exporter don't surface. Commit it as
`config/grafana/provisioning/dashboards/files/cv4pve-overview.json` (this
one *should* be committed, unlike the fetched community ones, since
there's no upstream source to re-fetch it from).

## Further ahead

- **HA for the monitoring VM itself** — currently a single VM; losing it
  loses metrics/log collection (though not the Proxmox cluster's own
  operation). Worth revisiting once the cluster reaches the upper end of
  its planned 7→11 node growth and monitoring becomes more operationally
  critical.
- **SSO for PDM confirmed end-to-end** — PDM's official docs (checked
  against PDM 1.1.7) confirm it supports `openid` as a realm type, but via
  its own separate CLI (`proxmox-datacenter-manager-admin`), not `pveum`.
  The exact `realm add` flag names weren't in the fetched docs and remain
  unverified against a running instance — see
  [docs/keycloak-integration.md](keycloak-integration.md) step 3b. If the
  deployed PDM version turns out not to support this, oauth2-proxy covers
  the gap in the meantime (step 4).
- **Multi-cluster** — the current design assumes one Proxmox VE cluster.
  Extending `config/prometheus/targets/*.json` and `CV4PVE_*` host lists
  to a second cluster is mechanically straightforward but untested; label
  scrape targets by cluster name before doing this so Grafana dashboards
  can filter per-cluster.
- **PBS (Proxmox Backup Server) job status monitoring** — referenced in
  `docs/hardening.md`'s NIS2 control-mapping table as a gap: this stack
  monitors the Ceph/PVE cluster but not backup-job success/failure, which
  is directly relevant to NIS2's business-continuity pillar.
