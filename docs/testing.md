# Testing

This page maps every test in the repo: what it proves, where it runs, and
which one to run for a given change. For copy-paste commands see
[tests/README.md](../tests/README.md); for the VM lab itself see
[tests/lab/README.md](../tests/lab/README.md).

## Layers

| Layer | What it proves | Where it runs | Command | Time |
| --- | --- | --- | --- | --- |
| Lint | Style and static errors in YAML, Dockerfiles, shell, Markdown; no secrets committed | CI on every push/PR | `make lint` | 1 min |
| Drift | Docs and code agree (see [Drift checks](#drift-checks)) | CI, `make lint` | `tests/lint/check-drift.py` | seconds |
| Changelog | `CHANGELOG.md` is well formed and every tag has its section | CI, `make lint` | `tests/lint/check-changelog.sh` | seconds |
| Config validation | Compose files merge; `promtool` and `amtool` accept the configs | CI, `make validate` | `make validate` | 1 min |
| Smoke | The stack boots on a dummy `.env`, every container is healthy, Traefik routes, the in-stack scrape jobs are up | CI, lab `t0` | `make test` | 5 min |
| Deployment e2e | The documented bootstrap as root, then auth, TLS redirect, file modes, Loki binding and round trip, Grafana datasources, rules loaded, an alert delivered by mail | CI (`deploy-e2e`), lab `t0` | see [below](#deployment-e2e-in-ci) | 8 min |
| Lab tier 1 | A real PVE 9 node: node-setup scripts, real scrape and PVE API, logs in Loki, PDM and its firewall, reboot survival | Local libvirt | `make lab-up && make lab-test` | 15 + 15 min |
| Lab tier 2 | A 3-node cluster with Ceph: mgr failover, `CephOSDDown` and `ProxmoxNodeDown` fire and mail, cv4pve-diag host fallback | Local libvirt | `make lab-up TIER=2 && make lab-test TIER=2` | 45 + 40 min |
| Lab tier 3 | Keycloak: oauth2-proxy, PVE and PDM OpenID logins | Local libvirt | `make lab-up TIER=3 && make lab-test TIER=3` | + 5 min |
| Security | gitleaks, Trivy on configs and on the two custom images (fixable CRITICAL/HIGH fail; unfixed ones are listed) | CI on push/PR and weekly | none locally (see workflow) | 3 min |

CI never talks to Proxmox or Ceph. Anything that needs a PVE API, a node
agent or Ceph is tested only in the lab, so a green CI does not prove it.

## CI workflows

| Workflow | Jobs | Trigger |
| --- | --- | --- |
| `lint.yml` | yamllint, hadolint (both Dockerfiles), shellcheck, markdownlint, changelog, drift | push/PR to `main` |
| `validate-and-test.yml` | compose-config, promtool, amtool, then smoke-test and deploy-e2e | push/PR to `main` |
| `security-scan.yml` | gitleaks, trivy-config, trivy-images | push/PR to `main`, weekly schedule |
| `release.yml` | publishes a GitHub Release from the matching `CHANGELOG.md` section | push of a `vX.Y.Z` tag, or manual with a tag |
| `upstream-versions.yml` | compares the cv4pve `.deb` versions with upstream releases and opens an issue per outdated tool (red run = something to bump) | weekly, manual |

Dependabot (`.github/dependabot.yml`) opens weekly grouped PRs for the
compose images, the two Dockerfiles' base images and the GitHub Actions.
Its PRs go through the same workflows; see the table below for the lab tier
an image bump still needs.

### Deployment e2e in CI

The `deploy-e2e` job runs `tests/e2e/t0-deploy.sh`, the same file the lab
runs on the monitoring VM, unchanged. It recreates the lab's environment on
the runner: the management address `10.77.10.10` on a dummy interface, the
checkout symlinked to `/opt/proxmox-biome`, and a Mailpit SMTP sink on
`10.77.10.10:1025`. To reproduce it on a disposable Linux host with Docker:

```bash
sudo ip link add biome-mgmt type dummy
sudo ip addr add 10.77.10.10/24 dev biome-mgmt && sudo ip link set biome-mgmt up
sudo mkdir -p /var/lib/biome-lab/artifacts && sudo ln -sfn "$PWD" /opt/proxmox-biome
docker run -d --name lab-mailpit -p 10.77.10.10:1025:1025 -p 10.77.10.10:8025:8025 axllent/mailpit:v1.31.3
sudo bash tests/e2e/t0-deploy.sh
```

It overwrites `.env` and the generated files in the checkout, so never run
it in a deployment directory.

## Lab phases

`tests/lab/run.sh` (`make lab-test`) runs the phases below in order and
prints one `OK`/`FAIL` line per phase. Each `tests/e2e/*.sh` file runs as
root inside one VM, prints `PASS`/`FAIL` per assertion and exits non-zero
on any failure. Logs go to `tests/lab/artifacts/`.

| Tier | Phase file | VM | Proves |
| --- | --- | --- | --- |
| 0 | `t0-smoke.sh` | monitoring | `tests/integration/smoke-test.sh` on a real daemon; `generate-secrets.sh` file modes as root (600) and non-root (644) |
| 0 | `t0-deploy.sh` | monitoring | `bootstrap-monitoring-vm.sh` with `tests/lab/lab.env`; the checks listed under Deployment e2e |
| 1 | `t1-node.sh` | pve1 | `configure-auditd.sh`, `install-alloy-agent.sh`, node exporter: agents run and can read their sources |
| 1 | `t1-monitoring.sh` | monitoring | the real node scraped, cv4pve against the real PVE API, node logs in Loki, PDM firewall and Traefik route, cv4pve-diag timer and report |
| 1 | `t1-pve-reachability.sh` | pve1 | PDM `:8443` blocked from the management LAN, Loki and Traefik reachable |
| 1 | `t1-pegaprox.sh` | monitoring | the opt-in PegaProx overlay: healthy, the image's own volumes, 401/200 through Traefik, config kept across a recreate; stopped again afterwards |
| 1 | (host checks in `run.sh`) | host | on the perimeter address only `:443` answers |
| 1 | `t1-after-reboot.sh` | monitoring | firewall and stack come back after `vagrant reload` |
| 2 | `t2-cluster.sh` | pve1 | quorate 3-node cluster, Ceph `HEALTH_OK`, `enable-ceph-prometheus.sh` idempotent |
| 2 | `t2-monitoring.sh` | monitoring | every node and mgr scraped, one `ceph_health_status` series, logs from every node |
| 2 | `t2-pve-action.sh` | pve nodes | fault injection: `mgr-fail`, `osd-stop`, `osd-start` |
| 2 | `t2-after-failover.sh` | monitoring | metrics follow the new active mgr, `CephMgrExporterAbsent` stays quiet |
| 2 | `t2-alert.sh <Alert> <timeout>` | monitoring | the alert fires and its mail reaches Mailpit, then resolves |
| 2 | `t2-diag-fallback.sh` | monitoring | cv4pve-diag falls back to the next host when the first is down |
| 3 | `t3-oauth2.sh` | monitoring | oauth2-proxy with PKCE, scripted Keycloak login lands on the reports |
| 3 | `t3-pve-oidc.sh` | pve1 | the documented `pveum realm add`, then a login ending in a PVE ticket |
| 3 | `t3-pdm-oidc.sh` | monitoring | an OpenID realm on PDM through its API, then a login |

Shared helpers (`check`, `wait_for`, `expect_code`, `prom_true`,
`loki_has`, `mailpit_has`, `summary`) are in `tests/e2e/lib.sh`.

## What to run for a change

| You changed | Minimum before merging |
| --- | --- |
| Markdown only | `make lint` |
| `config/prometheus/`, `config/alertmanager/` | `make lint validate`; for a new or changed alert, lab tier 2 if it's a PVE/Ceph alert |
| `docker-compose*.yml`, `config/traefik/`, `config/loki/`, `config/grafana/` | CI green (smoke + deploy-e2e), then lab tier 1 |
| An image tag | CI green, then lab tier 1; tier 3 for Traefik, oauth2-proxy or Loki |
| `docker/*/Dockerfile`, cv4pve versions | CI green (includes Trivy), lab tier 1 (real PVE API) |
| `scripts/bootstrap-*`, `generate-secrets.sh`, `configure-pdm-firewall.sh` | CI green, lab tier 1 (includes the reboot) |
| `scripts/node-setup/`, `scripts/systemd/` | lab tier 1; tier 2 for Ceph-related scripts |
| Keycloak / OIDC docs or config | lab tier 3 |
| A release | lab at the highest tier the release touches, from clean (`make lab-destroy` first) |

## Drift checks

`tests/lint/check-drift.py` fails CI when:

- an alert in `config/prometheus/rules/` has no row in the runbook's
  [alert catalogue](runbook-incident-response.md#alert-catalogue);
- a line of `.env.example` is neither a comment nor `KEY=value`, a
  `${VAR}` read by the compose files or the Alertmanager template is
  missing from it, or it declares a variable nothing reads;
- a `prom/prometheus` or `prom/alertmanager` tag in CI, `tests/README.md`
  or the `Makefile` differs from `docker-compose.yml`, or a cv4pve image
  tag differs from its Dockerfile's `CV4PVE_VERSION`;
- a file under `scripts/` is not mentioned in any Markdown file, or a
  `tests/e2e/t*.sh` phase or a workflow is missing from this page;
- a relative Markdown link points at a file that does not exist.

When it fails, fix the side that is wrong. Don't weaken the check.

## Adding a test

- A new assertion on the deployed stack goes into the phase that owns
  that component, using the `lib.sh` helpers. If it only needs Docker,
  put it in `t0-deploy.sh` so CI runs it too.
- A new phase is a new `tests/e2e/tN-<name>.sh` sourcing `lib.sh` and
  ending with `summary`, a `phase` line in `tests/lab/run.sh`, and a row
  in the table above (the drift check enforces the row).
- A test that needs a new lab-only service goes under `tests/lab/`
  (provisioning, `docker-compose.lab.yml`), never into the deployed files.
- Every bug the lab finds gets fixed in the deployed files and, where
  possible, an assertion that would have caught it.

## Known gaps

- No automated test for real Let's Encrypt issuance or an internal-CA
  certificate (`config/traefik/dynamic/tls-options.yml`).
- PegaProx is tested up to its own health endpoint; adding a cluster to it
  through its API is not automated.
- Grafana dashboards are fetched at deploy time
  (`scripts/fetch-community-dashboards.sh`) and not checked.
- `tests/lab/` needs a libvirt host; it cannot run in hosted CI.
