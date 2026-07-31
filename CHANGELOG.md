# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-07-31

Initial production-grade build, replacing the raw research transcript
(now `docs/research/original-chat-transcript.md`) with a tested,
documented, git-tracked repository.

### Added

- Core Docker Compose stack: Traefik, Prometheus, Alertmanager, Grafana,
  Loki, node_exporter, cv4pve-metrics-exporter, cv4pve-diag,
  audit-report-server, oauth2-proxy, docker-socket-proxy.
- `docker-compose.pegaprox.yml` optional overlay for PegaProx
  (EXPERIMENTAL/BETA, opt-in — [ADR-0005](docs/adr/0005-cv4pve-diag-default-pegaprox-experimental.md)).
- Custom, checksum-verified, distroless container images for
  `cv4pve-diag` and `cv4pve-metrics-exporter`
  ([ADR-0007](docs/adr/0007-custom-cv4pve-images.md)), neither of which
  publishes an official image upstream.
- Hardening baseline applied uniformly: pinned image tags, `cap_drop:
  [ALL]`, `no-new-privileges`, read-only root filesystems, non-root users,
  per-service resource limits, log rotation — see
  [docs/hardening.md](docs/hardening.md).
- Two-network Docker segmentation (`monitoring-edge` / `monitoring-backend`).
- Native Proxmox Datacenter Manager install, isolated from the management
  LAN by a host nftables rule
  (`scripts/configure-pdm-firewall.sh`) rather than an application-level
  bind — PDM's proxy stack has no configurable listen address
  ([ADR-0003](docs/adr/0003-pdm-colocated-native-loopback-proxy.md)).
- Node-side setup scripts: `node_exporter`, Grafana Alloy (replacing the
  now-EOL Promtail — [ADR-0004](docs/adr/0004-alloy-not-promtail.md)),
  Ceph `mgr prometheus` module enablement, `auditd` NIS2 traceability
  rules.
- Scheduled `cv4pve-diag` NIS2/ISO27001/GDPR/DORA compliance scanning via
  systemd timer, served as static HTML reports through
  `audit-report-server`.
- Two-phase auth model: Traefik `basicAuth` bootstrap, Keycloak OIDC SSO
  (Grafana native, PVE/PDM `pveum realm add`, oauth2-proxy ForwardAuth for
  everything else) as the steady state
  ([ADR-0006](docs/adr/0006-local-auth-bootstrap-then-keycloak-oidc.md)).
- Full documentation set: architecture, network port matrix, deployment
  guide, hardening/NIS2 control mapping, Keycloak integration,
  troubleshooting, incident-response runbook, roadmap, and the persisted
  execution plan.
- CI: lint (yamllint, hadolint, shellcheck, markdownlint), config
  validation (`docker compose config`, `promtool`, `amtool`), security
  scanning (gitleaks, Trivy config + image scans), and an integration
  smoke test that boots the full stack and checks healthchecks/routing/
  scrape-target registration.

### Changed

- Corrected the original research transcript's assumption that PDM's
  listen address is configurable to loopback-only — verified against
  official docs and the Proxmox support forum, no such option exists for
  PDM's proxy stack. See `docs/plan/EXECUTION-PLAN.md`'s "Deviation"
  section.
- Replaced the transcript's suggested Promtail agent with Grafana Alloy
  (Promtail reaches end-of-life in March 2026).

[Unreleased]: https://github.com/gsamuele78/Proxmox_biome_log_collector/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/gsamuele78/Proxmox_biome_log_collector/releases/tag/v0.1.0
