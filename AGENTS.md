# AGENTS.md

Instructions for coding agents working in this repo. Humans: the same
rules are in [docs/maintenance-guide.md](docs/maintenance-guide.md).

## What this repo is

A Docker Compose monitoring, logging and NIS2-compliance stack that runs on
one VM outside a Proxmox VE + Ceph cluster. Start with
[README.md](README.md), then [docs/architecture.md](docs/architecture.md).

## Layout

| Path | Contents | Deployed? |
| --- | --- | --- |
| `docker-compose.yml`, `docker-compose.pegaprox.yml` | the stack | yes |
| `config/` | Traefik, Prometheus (+ rules, file_sd targets), Alertmanager template, Loki, Grafana provisioning, Alloy template, report server | yes |
| `scripts/` | bootstrap, secrets, PDM firewall, cv4pve-diag runner, `node-setup/` for PVE nodes, `systemd/` units | yes |
| `docker/` | Dockerfiles for the two cv4pve images | yes (built) |
| `docs/` | operator documentation, ADRs, plans | read by operators |
| `tests/lint/` | lint configs, `check-changelog.sh`, `check-drift.py` | no |
| `tests/integration/` | CI smoke test | no |
| `tests/e2e/` | assertion phases run in CI (`t0-deploy.sh`) and in the lab | no |
| `tests/lab/` | Vagrant + libvirt lab, lab-only env and credentials | **never** |

## Rules

- Fix bugs in the deployed files. Never work around a stack bug inside
  `tests/lab/` or `tests/e2e/`; the lab exists to find bugs in the product.
- Never copy `tests/lab/lab.env`, lab IPs (`10.77.*`), lab passwords or
  `biome.lab.test` into deployed files.
- Never commit `.env`, `config/traefik/dynamic/.htpasswd`,
  `config/alertmanager/alertmanager.yml` or `config/prometheus/targets/*.json`.
- Pin every image tag. No `latest`.
- Keep the hardening baseline in [docs/hardening.md](docs/hardening.md) for
  every service.
- Add a `CHANGELOG.md` entry under `[Unreleased]` for every user-visible
  change, with upgrade steps if an operator must act.
- Architecture changes need an ADR in `docs/adr/`.
- Don't tag, release or push without being asked.

## Before you say "done"

```bash
make lint        # includes check-changelog.sh and check-drift.py
make validate    # compose config, promtool, amtool (needs Docker)
make test        # smoke test (needs Docker, refuses to run if .env exists)
```

Then pick the lab tier from the "What to run for a change" table in
[docs/testing.md](docs/testing.md). If you couldn't run a required tier,
say so explicitly. Don't report it as passed.

## Gotchas

- `docker run prom/prometheus ...` runs the server. Use
  `--entrypoint promtool` (and `--entrypoint amtool` for Alertmanager).
- The Alertmanager config is a template rendered by `envsubst`, which has
  no `${VAR:-default}`. Defaults go in `scripts/bootstrap-monitoring-vm.sh`.
- The bootstrap and secrets scripts must run as root in production. They
  set ownership for containers that drop every capability.
- `systemctl restart nftables` on the monitoring VM flushes Docker's rules.
- PDM is a native package, not a container, and binds `0.0.0.0:8443`. Only
  `scripts/configure-pdm-firewall.sh` isolates it.
- `tests/integration/smoke-test.sh` ends with `docker compose down -v`, so
  it refuses to run where a `.env` exists. Keep that guard.
