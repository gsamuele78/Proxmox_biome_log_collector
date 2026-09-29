# Next-session plan (after 0.2.0)

Written 2026-09-28, at the end of the session that added `tests/lab/` and
released 0.2.0. Start a new chat with: "read `docs/plan/NEXT-SESSION-PLAN.md`
and continue from step 1".

## Where things stand

- `CHANGELOG.md` has `[0.2.0] - 2026-09-28`. Everything in it passed a
  full lab run on freshly built VMs: `make lab-up TIER=3 && make lab-test TIER=3`,
  25 phases, 0 failed checks (log in `tests/lab/artifacts/`, gitignored).
- Every fix lives in the files that get deployed (`docker-compose*.yml`,
  `config/`, `scripts/`, `docker/`, `docs/`). The lab rsyncs the working
  tree into the VMs, so there is nothing to port back. Lab-only material
  stays under `tests/lab/` (`lab.env`, `docker-compose.lab.yml`,
  `provision/`, the Keycloak realm) and must never be deployed.
- Not yet done: the commit, the `v0.2.0` tag, and a first CI run of these
  changes on GitHub.

## 1. Commit and tag 0.2.0 (user)

The code was committed as `c06dfd9` ("big tests"). What remains is the
release commit (CHANGELOG `[0.2.0]`, this plan, the README link):

```bash
git add CHANGELOG.md README.md docs/plan/NEXT-SESSION-PLAN.md
git commit -m "release: 0.2.0"
git tag -a v0.2.0 -m "0.2.0"
git push && git push --tags
```

Then check that the `lint`, `validate-and-test` and `security-scan`
workflows are green. They have never run on these changes.

## 2. Upgrade the real deployment from 0.1.0 to 0.2.0

Follow the upgrade note under 0.2.0 "Removed" in `CHANGELOG.md`. In order:

1. On the monitoring VM: `git pull`, then add the new keys to `.env`
   (`LOKI_BIND_ADDR` = the management-LAN IP, `ALERTMANAGER_SMTP_REQUIRE_TLS=true`)
   and delete `PVE_API_HOST` / `CV4PVE_DIAG_SCHEDULE_CRON`.
2. `sudo scripts/configure-pdm-firewall.sh`. The new table file is
   idempotent and the script no longer runs `enable --now`. Do not run
   `systemctl restart nftables` on this host (it flushes Docker's rules);
   if it ever happens, run `systemctl restart docker` right after.
3. `sudo scripts/generate-secrets.sh && sudo scripts/bootstrap-monitoring-vm.sh`
   (run both as root, for the file ownership of `.htpasswd` and
   `alertmanager.yml`).
4. On every PVE node: re-run `configure-auditd.sh` and then
   `install-alloy-agent.sh` (0.1.0 left Alloy unable to read its config and
   audit.log, so no node logs have ever reached Loki).
5. Add the Mailpit-free equivalent of the lab's alert check: from the
   monitoring VM,
   `docker compose exec alertmanager amtool alert add DeployTest severity=warning --alertmanager.url=http://localhost:9093`
   and confirm the mail arrives at `ALERTMANAGER_RECEIVER_EMAIL`.
6. Check `https://prometheus.<domain>/targets`: every job up, including
   the new self-monitoring jobs.

## 3. Image updates, released as 0.3.0

Checked against the registries on 2026-09-28:

| Image / artifact | Pinned | Latest | Notes |
| --- | --- | --- | --- |
| `traefik` | v3.7.9 | v3.7.13 | patch |
| `prom/prometheus` | v3.13.2 | v3.15.0 | also bump it in `.github/workflows/validate-and-test.yml` and `tests/README.md` (promtool) |
| `prom/alertmanager` | v0.33.1 | v0.34.1 | same (amtool) |
| `grafana/loki` | 3.7.4 | 3.7.8 | patch |
| `nginxinc/nginx-unprivileged` | 1.31.3-alpine3.24 | 1.31.6-alpine3.24 | patch |
| `quay.io/oauth2-proxy/oauth2-proxy` | v7.15.3-alpine | v7.15.4-alpine | patch |
| `grafana/grafana-oss` | 13.0.2 | 13.0.2 | current |
| `prom/node-exporter` | v1.12.1 | v1.12.1 | current |
| `tecnativa/docker-socket-proxy` | v0.5.0 | v0.5.0 | current |
| cv4pve-diag `.deb` | 2.4.0 | 2.7.0 (2026-09-28) | new `CV4PVE_DEB_SHA256`; re-check CLI flags and the permissions doc |
| cv4pve-metrics-exporter `.deb` | 2.0.0 | 2.0.0 | current |
| `debian:trixie-slim` (builder) | floating tag | `trixie-20260918-slim` | pin a dated tag so builds are reproducible |
| `gcr.io/distroless/cc-debian12` | debian12 | `cc-debian13` exists | evaluate moving the runtime to Debian 13 |

Process: bump everything in one branch, run
`make lab-up TIER=3 && make lab-test TIER=3` from clean, fix whatever
breaks, then release. Record each bump under `### Changed` in `[Unreleased]`.

## 4. PegaProx: promote from EXPERIMENTAL (in 0.3.0)

Upstream has left 0.9.x behind: stable releases v1.0.1 through v1.2.0
(2026-09-21, not prereleases), and `ghcr.io/pegaprox/pegaprox:1.2.0` exists.
Proposal: keep it an **opt-in overlay** (it's AGPL-3.0, and it adds a
second management UI with write access to the cluster), but bump it to 1.2.0,
drop the EXPERIMENTAL/BETA wording, and record the decision in a new ADR
that supersedes the PegaProx half of ADR-0005. cv4pve-diag stays the
compliance default.

Before deciding, check in the lab:

- the 1.x image's environment variables, data path (`/data`), ports
  5000-5002 and whether `wget` still exists for the healthcheck;
- a new phase `tests/e2e/t1-pegaprox.sh`: overlay up, container healthy,
  `pegaprox.biome.lab.test` through Traefik with basic auth (and oauth2
  at tier 3), able to add `pve1` as a cluster using the lab API token.

## 5. Dependabot, plus what it cannot see

Add `.github/dependabot.yml` with weekly updates for:

- `docker-compose` (directory `/`): the images pinned in both compose files;
- `docker` (`/docker/cv4pve-diag`, `/docker/cv4pve-metrics-exporter`): the
  `debian` and `distroless` base images;
- `github-actions` (directory `/`).

Group the minor and patch updates to keep the PR count down. Dependabot
does not see:

- the cv4pve `.deb` versions (an `ARG` plus a checksum). Add a scheduled
  workflow that compares `ARG CV4PVE_VERSION` with the latest GitHub
  release and opens an issue. It should not open a PR: the checksum must
  be verified by a person (ADR-0007);
- tags repeated outside the compose files: promtool/amtool in the CI
  workflow and `tests/README.md`, and Mailpit, Keycloak and curl in
  `tests/lab/`.

CI only runs the smoke test, so a green Dependabot PR is not proof. Before
merging an image bump, run the lab (tier 1 at minimum, tier 3 for
Traefik, oauth2-proxy or Loki). Write this rule in `CONTRIBUTING.md`.

## 6. Loose ends

- cv4pve-metrics-exporter 2.0.0 once logged "Null values are not supported
  for metric label names" in `WriteNodeAssignmentMetrics`. It did not
  reproduce on rebuilt VMs. If it shows up in production, report it upstream.
- Grafana has no dashboard for the `cv4pve_*` metrics yet. The real metric
  names are in `tests/lab/artifacts/monitoring/cv4pve-metric-names.txt`
  after any tier-1 run (roadmap item).
- The lab's Traefik keeps asking Let's Encrypt for `*.biome.lab.test` and
  logs the rejection every time. It's harmless, but an optional lab phase
  could exercise the internal-CA path (`tls-options.yml` `certificates:`).
