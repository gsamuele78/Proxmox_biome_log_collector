# Execution plan

This is the plan approved before this repository was built, persisted here
for provenance, with the execution order checked off as it landed and one
recorded deviation from the plan's original text where verification proved
part of it wrong.

## Context

The repo originally contained only an Italian-language AI chat transcript
(`README.MD`, moved to `docs/research/original-chat-transcript.md`)
exploring how to monitor a growing Proxmox VE + Ceph cluster and reach
NIS2 compliance. The chat was a good source of *requirements* but not a
buildable design — it hallucinated some config, used an EOL log agent
(Promtail), and suggested containerizing an officially-native-only
package (PDM). This plan turned it into a production-grade, tested,
documented repository.

## Confirmed decisions

- **Traefik** as reverse proxy — config-as-code, git-diffable, CI-testable.
- **PegaProx** included only as an opt-in, disabled-by-default Compose
  profile, clearly marked EXPERIMENTAL/BETA (ADR-0005). **cv4pve-diag**
  is the default compliance auditor.
- **Grafana Alloy**, not Promtail (EOL) — ADR-0004.
- **PDM installed natively** on the same VM as the Docker stack — ADR-0003.
- **cv4pve-metrics-exporter** added for PVE-object-level metrics.
- **Alertmanager** added — the original chat built dashboards but never
  alerting.
- Firewall model: the 80/443/22 restriction is a **perimeter**
  (corporate/VPN-facing) constraint only — see
  `docs/network-port-matrix.md`.

## Deviation from the original plan text: PDM isolation mechanism

The original plan asserted PDM's listener could be bound to
`127.0.0.1:8443` ("its listen address is configurable"). This was verified
against the official PDM docs and the Proxmox support forum during
execution and found to be **incorrect**: PDM's API daemon reuses Proxmox
Backup Server's proxy stack, which Proxmox staff have confirmed has no
`LISTEN_IP`-equivalent configuration — unlike PVE's `pveproxy`, it always
binds `0.0.0.0:8443`.

**Corrected mechanism**: a host nftables rule
(`scripts/configure-pdm-firewall.sh`) restricts tcp/8443 to loopback and
the `monitoring-edge` Docker network's fixed subnet (`172.28.0.0/24`,
pinned in `docker-compose.yml`) instead of relying on an application-level
bind. The end result (PDM unreachable from the management LAN or
perimeter, only reachable via Traefik) is the same; the mechanism that
achieves it changed. See ADR-0003's revised Context/Decision/Consequences
sections for the full reasoning, and `docs/troubleshooting.md` for the
operational implications (this is a host-firewall dependency, not a
set-and-forget app config).

## Execution order

1. [x] Repo hygiene: `.gitignore`, `.editorconfig`, `LICENSE`,
   `.env.example`, `CONTRIBUTING.md`, `SECURITY.md`.
2. [x] `docker-compose.yml` + `config/*` for all core services, hardened
   per `docs/hardening.md`'s baseline.
3. [x] `docker-compose.pegaprox.yml` overlay (experimental, opt-in).
4. [x] `scripts/` (bootstrap, node-setup, dashboard fetch, secrets,
   cv4pve-diag runner + systemd, PDM firewall).
5. [x] `tests/` + `.github/workflows/`.
6. [x] `docs/adr/*`, `docs/*.md`.
7. [x] Rewrite `README.md`; move the original chat transcript to
   `docs/research/original-chat-transcript.md`.
8. [x] `CHANGELOG.md` entry for `0.1.0`.
9. [x] Local validation pass (yamllint, hadolint, shellcheck, markdownlint,
   structural checks) — see the "Verification" section below for what was
   and wasn't possible to run without a Docker daemon in the build
   environment.
10. [x] Git commits in logical chunks reflecting the above; **no push**
    without explicit approval.

## Verification: what's actually confirmed vs. documented-only

Built without a Docker daemon available in the environment. What **was**
run and passed locally:

- `yamllint -c tests/lint/.yamllint.yml .` — clean.
- `hadolint --config tests/lint/.hadolint.yaml` on both Dockerfiles — clean.
- `shellcheck` on every script — clean.
- `npx markdownlint-cli2` with `tests/lint/.markdownlint.yaml` on every
  doc — clean.

What was **not** run locally (no Docker daemon) and relies on CI
(`.github/workflows/validate-and-test.yml`) or manual verification on
real hardware instead:

- `docker compose config` (both compose files).
- `promtool check config` / `check rules`.
- `amtool check-config` against the rendered Alertmanager template.
- `tests/integration/smoke-test.sh` itself.
- Anything requiring a real Proxmox VE/Ceph cluster or a live Keycloak
  realm (PVE/Ceph scrape behavior, `cv4pve-diag`/`cv4pve-metrics-exporter`
  against real API tokens, OIDC login flows) — these are documented in
  `docs/deployment-guide.md` and `docs/keycloak-integration.md` but were
  not, and could not be, executed end-to-end during the build.
