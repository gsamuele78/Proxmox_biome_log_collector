# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- CI job `deploy-e2e`: runs `tests/e2e/t0-deploy.sh` (the documented root
  bootstrap plus the lab's tier-0 assertions) on the runner, with the lab's
  management address on a dummy interface and a Mailpit sink. CI now proves
  auth, the HTTPS redirect, secret file modes, Loki binding, alert delivery
  by mail, and not only that containers start.
- `t0-deploy.sh` also checks a Loki push/query round trip, the Grafana admin
  login and that both provisioned datasources are healthy.
- `tests/lint/check-drift.py` (CI `drift` job, `make lint`): fails when an
  alert has no runbook entry, `.env.example` and the stack disagree on
  variables, repeated image tags differ, a script or test phase is
  undocumented, or a Markdown link is broken.
- `tests/lint/check-changelog.sh` (CI `changelog` job, `make lint`) and
  `.github/workflows/release.yml`: a `vX.Y.Z` tag publishes a GitHub Release
  with that version's changelog section.
- Docs: [docs/testing.md](docs/testing.md) (test catalogue and what to run
  for which change), [docs/maintenance-guide.md](docs/maintenance-guide.md)
  (change, bump, release and upgrade procedures), `AGENTS.md`,
  [docs/repo-audit.md](docs/repo-audit.md), an alert catalogue in the
  runbook, README status and version badges.
- `.github/dependabot.yml`: weekly grouped PRs for the compose images, the
  Dockerfiles' base images and GitHub Actions. `upstream-versions.yml`:
  weekly check of the cv4pve `.deb` versions, opening an issue (never a PR,
  ADR-0007) when upstream has a new release.
- Lab phase `tests/e2e/t1-pegaprox.sh` and
  [ADR-0008](docs/adr/0008-pegaprox-1x-opt-in-overlay.md).

### Changed

- `trivy-images` fails only on CRITICAL/HIGH findings that have a fix, and
  lists the unfixed ones in the job log. A HIGH with no fix in Debian 12's
  OpenSSL (CVE-2026-84782, published 2026-09-29) otherwise blocks every
  build with no possible action here; it stays visible and is re-checked
  by the weekly run.
- Images (checked against the registries on 2026-09-29): `traefik`
  v3.7.9 → v3.7.13, `prom/prometheus` v3.13.2 → v3.15.0,
  `prom/alertmanager` v0.33.1 → v0.34.1, `grafana/loki` 3.7.4 → 3.7.8,
  `nginxinc/nginx-unprivileged` 1.31.3 → 1.31.6-alpine3.24,
  `oauth2-proxy` v7.15.3 → v7.15.4-alpine, PegaProx 0.9.15 → 1.2.0.
  Grafana 13.0.2, node-exporter v1.12.1, docker-socket-proxy v0.5.0 and
  cv4pve-metrics-exporter 2.0.0 were already current.
- cv4pve-diag 2.4.0 → 2.7.0. The `.deb` checksum was computed from the
  release asset and matches the digest GitHub publishes for it. 2.7.0
  renumbers findings: critical levels get their own `C` codes (`WN0027` →
  `CN0027`), some codes are retired. This stack passes no ignore rules, so
  nothing breaks here; if you added an `--ignored-issues-file`, add the new
  `C` codes to it.
- The cv4pve images build from a dated `debian:trixie-20260918-slim` (was
  the floating `trixie-slim`), so builds are reproducible. The runtime stays
  on `gcr.io/distroless/cc-debian12`: `cc-debian13` works (the binaries
  need glibc 2.27) but still ships `libssl3t64` 3.5.7-1~deb13u2, a HIGH
  (CVE-2026-75804) that Trivy fails on. Move once distroless rebuilds.
- PegaProx is no longer labelled EXPERIMENTAL (ADR-0008).
- `make validate` now runs `promtool` and `amtool` like CI (it only ran
  `docker compose config`); `make lint` also runs the two new checks.

### Removed

- `TZ` from `.env.example`: nothing read it. An existing `.env` can keep
  it; it has no effect.
- `PEGAPROX_ADMIN_EMAIL`: PegaProx never read it (its admin account is
  created on first login).

### Fixed

- The PegaProx overlay could not have worked: it mounted its volume at
  `/data` while the image keeps its state in `/app/config` and `/app/logs`
  (so config lived in anonymous volumes, lost on recreate), its `wget`
  healthcheck can't run in the image, and PegaProx served HTTPS to
  Traefik's plain-HTTP backend. **Upgrade** (only if you enabled it): the
  old `pegaprox-data` volume holds nothing; remove it with
  `docker volume rm <project>_pegaprox-data` after bringing the overlay up
  again.
- Deployment guide: new step 5a installs and enables the cv4pve-diag
  systemd timer. The guide never said to, so a deployment that followed it
  produced no compliance report. **Upgrade:** if
  `systemctl list-timers cv4pve-diag.timer` shows nothing on your
  monitoring VM, do step 5a. Step 9's Alertmanager test now uses a working
  `amtool alert add` command.
- CI `promtool` and `amtool` jobs never passed: `docker run prom/prometheus
  promtool ...` hands `promtool` to the image's ENTRYPOINT (the server
  binary). Both jobs, and the commands in `tests/README.md`, now use
  `--entrypoint`. The README's `rules/*.yml` glob was also expanded by the
  host shell against a container path; it now lists the files.
- Lab: `vagrant up` failed on a held apt lock (apt-daily at first boot, or
  an interrupted run); provisioning now waits for the lock. `run.sh`
  re-syncs a VM that `vagrant rsync` skipped, or stops with a clear error
  instead of failing every phase.

## [0.2.0] - 2026-09-28

### Added

- `tests/lab/`: a Vagrant + libvirt lab and `tests/e2e/` phases run by
  `make lab-up` / `make lab-test`, in cumulative tiers: 0 monitoring VM,
  1 + a Proxmox VE 9 node, 2 + a 3-node PVE cluster with Ceph, 3 + Keycloak.
  Covers the deployment guide end to end, reboots, Ceph mgr failover,
  alert delivery by mail (Mailpit sink) for `CephOSDDown` and
  `ProxmoxNodeDown`, cv4pve-diag host fallback, and OIDC logins through
  oauth2-proxy, PVE and PDM. See `tests/lab/README.md`.
- `ALERTMANAGER_SMTP_REQUIRE_TLS` (default `true`) for plaintext relays.

### Changed

- Dropped the `docker-socket-proxy` scrape job: it has no `/metrics` and was
  permanently down. Added self-monitoring jobs for the monitoring VM's own
  node-exporter (previously deployed but never scraped), Alertmanager,
  Loki, Grafana and Traefik (metrics enabled on the internal entrypoint).
- New `config/prometheus/rules/monitoring.rules.yml`:
  `Cv4pveMetricsExporterDown` (docs/hardening.md already claimed this
  alert existed), `MonitoringStackTargetDown`, `CephMgrExporterAbsent`,
  `LokiRequestErrors`.
- The smoke test now also checks Loki's host port, the cv4pve-diag binary,
  and that every in-stack scrape job is `up`.

### Removed

- `.env` variables `PVE_API_HOST` and `CV4PVE_DIAG_SCHEDULE_CRON` (never read
  by anything). Bootstrap now requires the variables the stack actually reads
  (`CV4PVE_*_HOSTS`, SMTP smarthost and receiver).
- **Upgrade note:** before re-running `bootstrap-monitoring-vm.sh` on a 0.1.0
  deployment, add `LOKI_BIND_ADDR` and `ALERTMANAGER_SMTP_REQUIRE_TLS` to
  `.env` (see `.env.example`), and make sure `CV4PVE_DIAG_HOSTS`,
  `CV4PVE_EXPORTER_HOSTS`, `ALERTMANAGER_SMTP_SMARTHOST` and
  `ALERTMANAGER_RECEIVER_EMAIL` are set: bootstrap now requires them.

### Fixed

Found by the first lab run, on real hardware:

- Traefik served 404 for every route. `middlewares.yml` used
  `compression:`, which Traefik v3 rejects (the key is `compress:`), so the
  whole file failed to load and every `@file` middleware (security headers,
  basic auth) was missing.
- `docker-socket-proxy` crash-looped: its entrypoint writes
  `/tmp/haproxy.cfg` and the read-only root had no `/tmp` tmpfs. Traefik's
  Docker provider therefore saw no containers.
- `audit-report-server` (and oauth2-proxy/PegaProx) healthchecks probed
  `localhost`, which busybox `wget` resolves to `::1` first; nginx listens
  on IPv4 only, so the container stayed unhealthy. Probes now use `127.0.0.1`.
- `configure-pdm-firewall.sh` ran `systemctl enable --now nftables`, which
  loads Debian's `/etc/nftables.conf` (`flush ruleset`) and wiped Docker's
  NAT rules: every container lost outbound access (cv4pve-diag: "Host is not
  reachable") until dockerd restarted. It now only enables the unit for
  boot. Its table file is also idempotent now (declare, delete, redefine), so
  re-runs no longer duplicate the rules.
- `install-alloy-agent.sh` left `/etc/alloy/config.alloy` as `root:root 0640`;
  the `alloy` service user could not read it and crash-looped. Now
  `root:alloy`. Re-running the script also failed at `gpg --dearmor`
  (overwrite prompt with no TTY); it now passes `--yes`.
- `docs/deployment-guide.md` wrote a one-line `deb ...` entry into a
  `.sources` file, which apt rejects; it now writes `pdm.list`.
- `docs/keycloak-integration.md` step 3b told operators to run
  `proxmox-datacenter-manager-admin realm add`; that CLI has no realm
  commands. The step now documents the API call the lab verified with a
  full login. Step 1 listed `https://*.${BASE_DOMAIN}/oauth2/callback` as a
  redirect URI; Keycloak never matches a wildcard in the host, so it now
  lists one callback per protected hostname.
- `.env.example`'s cv4pve-diag privilege note was wrong: backup checks need
  `Datastore.AllocateSpace` + `VM.Backup`, not `Datastore.Audit`.

Found by review before the lab existed:

- Loki was unreachable from the PVE nodes: port 3100 was never published,
  so no Alloy agent could push logs. It is now published on
  `LOKI_BIND_ADDR` (new `.env` variable, set it to the management-LAN IP).
- Loki's healthcheck used `wget`, which the distroless Loki 3.x image does
  not have, so the container never became healthy. It now uses `loki -health`.
- oauth2-proxy's default image is distroless too (same `wget` healthcheck
  problem); switched to the `-alpine` tag. ForwardAuth also could not log
  anyone in: no `static://202` upstream, the middleware pointed at
  `/oauth2/auth` (bare 401, no redirect to Keycloak), and no router carried
  `/oauth2/callback` back to oauth2-proxy. All three are fixed, and the
  session cookie is scoped to `.${BASE_DOMAIN}`.
- The PDM router's rule was the literal string `pdm.${BASE_DOMAIN}`:
  Traefik's file provider does not expand `${VAR}`. It now uses
  `{{ env "BASE_DOMAIN" }}`, with `BASE_DOMAIN` passed to the container.
- cv4pve-metrics-exporter listened on `0.0.0.0`, which .NET's HttpListener
  treats as a literal Host-header match, so Prometheus's requests to
  `cv4pve-metrics-exporter:9221` were rejected. Now uses the `+` wildcard.
- cv4pve-diag could not write reports: the named volume was root-owned and
  the image runs as nonroot. The image now ships a nonroot-owned `/reports`.
- Root-level cv4pve options now come before the `execute`/`run` subcommand,
  matching upstream's documented usage.
- The rendered `alertmanager.yml` was `chmod 600` for the host user, which
  the `nobody` Alertmanager process cannot read. `.htpasswd` had the same
  problem for Traefik (root in the container but without
  `CAP_DAC_OVERRIDE`). Both scripts now set ownership that works.
- CI's `amtool` job and the smoke test set `ALERTMANAGER_SMTP_HOST`/`_USER`,
  but the template reads `_SMARTHOST`/`_USERNAME`, so the config was
  checked with an empty smarthost.
- The Trivy image scan never scanned cv4pve-diag: it lives in the `tools`
  profile, which plain `docker compose build` skips.
- The smoke test overwrote and then deleted any existing `.env` and ended
  with `down -v`. It now refuses to run where `.env` exists and only
  removes the files it created. CI installs `htpasswd`, which
  `generate-secrets.sh` needs.
- Alloy could not read `/var/log/audit/audit.log` (root 0600). auditd now
  uses `log_group = adm` and `alloy` is added to `adm`/`systemd-journal`.
  `configure-auditd.sh` no longer calls `systemctl restart auditd`, which
  Debian refuses (`RefuseManualStop=yes`).
- pve-firewall and auditd log streams now carry a `host` label; without it,
  lines from different nodes could not be told apart.
- Audit report URLs in the docs pointed at `/reports/…`; nginx serves the
  reports at the site root.

### Security

- oauth2-proxy: PKCE (`S256`) and `OAUTH2_PROXY_TRUSTED_PROXY_IPS` limited to
  the `monitoring-edge` subnet (it trusted `X-Forwarded-*` from any IP);
  the `oauth2-proxy-auth` forwardAuth middleware caps the auth response
  body (`maxResponseBodySize`).

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
- Split `docs/keycloak-integration.md`'s PVE/PDM OIDC section in two: PVE
  keeps `pveum realm add`; PDM uses its own separate CLI
  (`proxmox-datacenter-manager-admin`), confirmed to support an `openid`
  realm type against PDM 1.1.7's official docs, but with the exact
  `realm add` flags left as a verify-on-deploy step rather than guessed.

### Fixed

- `config/alertmanager/alertmanager.yml.tmpl` rendered an invalid config
  when `ALERTMANAGER_WEBHOOK_URL` was left at its documented-empty
  `.env.example` default — Alertmanager rejects a `webhook_configs` entry
  with an empty `url`. Found by actually running `amtool check-config`
  against the rendered template (previously undemonstrated locally for
  lack of the binary); fixed by commenting the webhook block out by
  default with uncomment instructions, since `envsubst` has no
  conditionals.

[Unreleased]: https://github.com/gsamuele78/Proxmox_biome_log_collector/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/gsamuele78/Proxmox_biome_log_collector/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/gsamuele78/Proxmox_biome_log_collector/releases/tag/v0.1.0
