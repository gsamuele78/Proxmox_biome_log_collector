# Repo audit: what exists vs what is documented

Snapshot of 2026-09-29, at 0.2.0 plus `[Unreleased]`. It records what was
checked, what was wrong, and what was changed. Mechanical drift is now
caught by `tests/lint/check-drift.py` (see [testing.md](testing.md)); run
the audit again by hand before a 1.0.

## Method

- Every service, tag, port, env var and profile in the compose files and
  `.env.example`, cross-checked with the architecture, port matrix,
  deployment and hardening docs.
- Every file in `scripts/`, the `Makefile` targets and every CI workflow,
  cross-checked with what the docs tell an operator to run.
- Every alert rule and scrape job, cross-checked with the runbook,
  troubleshooting and the tests.
- Every relative Markdown link.
- The CI history on GitHub and a lab run (`make lab-up TIER=1`,
  `make lab-test TIER=1`).

## Findings and fixes

| # | Area | Finding | Severity | Fixed by |
| --- | --- | --- | --- | --- |
| 1 | CI | `promtool` and `amtool` jobs had never passed: `docker run prom/prometheus promtool ...` runs the server with `promtool` as an argument, so `smoke-test` was always skipped | wrong | `--entrypoint` in the workflow, `tests/README.md` and `make validate` |
| 2 | CI | CI only checked that containers start with a dummy `.env`; the documented root bootstrap, auth, TLS redirect, Loki binding and alert mail were proven only in the lab | missing coverage | `deploy-e2e` job running `tests/e2e/t0-deploy.sh` |
| 3 | Deployment guide | The cv4pve-diag systemd units were never installed by any documented step; only the lab test copied them. A deployment that followed the guide produced no compliance report | wrong | step 5a in [deployment-guide.md](deployment-guide.md) |
| 4 | Deployment guide | Step 9's Alertmanager test (`wget --post-data='[]' ...`) was a placeholder, not a command | wrong | `amtool alert add` |
| 5 | Runbook | "Where things live" listed two of the three rule files; no per-alert triage guidance existed | stale / missing | alert catalogue in [runbook-incident-response.md](runbook-incident-response.md), enforced by the drift check |
| 6 | `Makefile` | `make validate` ran only `docker compose config`, though `tests/README.md` and CONTRIBUTING said it ran promtool and amtool | wrong | same checks as CI |
| 7 | `.env.example` | `TZ` was declared but read by nothing | stale | removed |
| 8 | `.env.example` | `ALERTMANAGER_WEBHOOK_URL` is read only after uncommenting the template's `webhook_configs` | ok, documented | allow-listed in the drift check |
| 9 | `tests/README.md` | `promtool check rules /config/rules/*.yml` was globbed by the host shell against a container path | wrong | files listed explicitly |
| 10 | `SECURITY.md` | `../../security/advisories/new` resolves only on github.com | minor | absolute URL |
| 11 | Tests | No map of the tests: which phase proves what, which to run for a change | missing | [testing.md](testing.md) |
| 12 | Process | No written procedure for bumping, releasing or upgrading; release notes were manual | missing | [maintenance-guide.md](maintenance-guide.md), `AGENTS.md`, `release.yml`, `check-changelog.sh` |
| 13 | Lab | `vagrant up` failed when apt was locked (apt-daily at first boot, or a previous interrupted run) | wrong (lab) | `DPkg::Lock::Timeout` in `tests/lab/provision/common.sh` |
| 14 | Lab | After an interrupted first `vagrant up`, `vagrant rsync` silently skipped the VM and every phase failed with `No such file` | wrong (lab) | `run.sh` syncs such a VM by name or stops with `FATAL`; recovery in [tests/lab/README.md](../tests/lab/README.md) |

## Lab result

2026-09-29, on VMs built that day:

- `make lab-test TIER=1`: 8 phases, 0 failed, including the new Loki round
  trip and Grafana datasource checks.
- `make lab-test TIER=2`: 22 phases, 142 assertions, 0 failed: 3-node
  cluster with Ceph, mgr failover, `CephOSDDown` and `ProxmoxNodeDown`
  firing and mailed, cv4pve-diag host fallback, recovery.
- Tier 3 (Keycloak) was not run in this pass.

The deployed stack needed no fix at tiers 1-2. Findings 1-12 came from
reading the repo and the CI history; 13 and 14 are in the lab tooling.

## Checked and consistent

- Prometheus and Alertmanager tags agree across compose, CI, `tests/README.md`
  and the `Makefile`; cv4pve image tags agree with their Dockerfiles.
- Every job matched by an alert rule exists in `prometheus.yml`.
- The auditd rules and the docker-socket-proxy API scope are documented in
  [hardening.md](hardening.md).
- The Makefile and CI shellcheck globs cover the same files.

## Still open

These are known, not fixed here:

- ADR-0002 (Traefik) is not linked from `architecture.md`.
- `config/grafana/provisioning/`, `config/audit-report-server/nginx.conf`
  and `config/traefik/dynamic/middlewares.yml` are described only by their
  own comments.
- The gaps listed under "Known gaps" in [testing.md](testing.md).
