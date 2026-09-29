# ADR-0005: cv4pve-diag as the default compliance auditor; PegaProx opt-in and marked experimental

Status: Accepted; the PegaProx part is superseded by [ADR-0008](0008-pegaprox-1x-opt-in-overlay.md)
Date: 2026-07-31

## Context

Two candidate tools surfaced for Proxmox-side compliance/audit reporting:

- **Corsinvest cv4pve-diag** — a mature CLI tool (part of the long-running
  `cv4pve-tools` suite) that tags findings against multiple frameworks,
  including NIS2, ISO 27001, GDPR, and DORA (`--compliance=Nis2`), and
  outputs structured HTML/JSON reports.
- **PegaProx** — a newer, actively developed Proxmox web-management/audit
  tool, currently at v0.9.x (pre-1.0), licensed AGPL-3.0.

The original chat-transcript research also included a PegaProx config with
hallucinated environment variables that do not correspond to anything the
real project exposes.

## Decision

Ship **cv4pve-diag** as the default, always-on compliance auditor
(`docker-compose.yml`, triggered on a schedule by
`scripts/systemd/cv4pve-diag.timer` → `scripts/run-cv4pve-diag.sh`).
Include **PegaProx** only as a separate, disabled-by-default overlay
(`docker-compose.pegaprox.yml`), clearly labeled EXPERIMENTAL/BETA, with
its *actual* verified port/env configuration (not the transcript's
hallucinated one) — activated only via an explicit second `-f` flag on
`docker compose`.

## Consequences

- The default deployment's compliance-reporting story rests on a tool
  (cv4pve-diag) with a track record and direct NIS2 framework tagging —
  lower risk for something whose whole purpose is regulatory evidence.
- Admins who want PegaProx's broader web-management feature set can opt in
  with `docker compose -f docker-compose.yml -f docker-compose.pegaprox.yml up -d`,
  with the risk (pre-1.0, AGPL-3.0 license terms, smaller track record)
  made explicit rather than silently defaulted-on.
- PegaProx's VNC/SSH-websocket console-proxying features (ports 5001/5002
  in its own docs) are deliberately **not** routed through Traefik in this
  repo — scoped out, tracked in `docs/roadmap.md`, rather than half-wired.
- Two separate compliance-report surfaces exist in the repo (cv4pve-diag's
  static HTML reports served by `audit-report-server`, and PegaProx's own
  web UI if enabled) — documented distinctly in
  `docs/keycloak-integration.md` so both get the same SSO treatment if
  Keycloak is wired up.

## Alternatives considered

- **PegaProx as the default** — rejected: pre-1.0 upstream maturity is a
  worse default for a compliance-evidence tool than an established one.
- **Drop PegaProx entirely** — rejected: it's a real, actively developed
  project with a legitimate feature set beyond compliance tagging; keeping
  it as an explicit, clearly-labeled opt-in preserves that option without
  making it the trust boundary's default.
- **Trust the chat transcript's PegaProx config as-is** — rejected outright:
  it referenced environment variables that don't exist in the real
  project (verified against PegaProx's actual documentation), which would
  have shipped a broken/non-functional overlay.
