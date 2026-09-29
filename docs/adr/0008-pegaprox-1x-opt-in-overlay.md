# ADR-0008: PegaProx 1.x stays an opt-in overlay, no longer "experimental"

Status: Proposed
Date: 2026-09-29

Supersedes the PegaProx half of
[ADR-0005](0005-cv4pve-diag-default-pegaprox-experimental.md). The
cv4pve-diag half (default compliance auditor) is unchanged.

## Context

ADR-0005 labelled PegaProx EXPERIMENTAL/BETA because upstream was at 0.9.x.
Upstream has since shipped stable releases 1.0.1 to 1.2.0 (1.2.0 on
2026-09-21, not a prerelease), published as `ghcr.io/pegaprox/pegaprox`.

Reading the 1.2.0 image config (and 0.9.15's, which is the same) showed the
0.2.0 overlay could not have worked:

- it mounted the named volume at `/data`, but the image keeps its config and
  database in its own `VOLUME`s `/app/config` and `/app/logs`, so the real
  state lived in anonymous volumes and was lost on every recreate;
- its healthcheck used `wget`, which the `python:3.12-slim`-based image
  doesn't have, so the container could never be healthy;
- PegaProx serves self-signed HTTPS on `:5000` unless
  `PEGAPROX_BEHIND_PROXY` is set, while Traefik talked plain HTTP to it;
- `PEGAPROX_ADMIN_EMAIL` is not a variable PegaProx reads.

The overlay had only ever been checked with `docker compose config`.

PegaProx is still AGPL-3.0 and still a second management UI with write
access to the cluster, which is why ADR-0005 kept it out of the default
stack.

## Decision

Keep PegaProx as the opt-in `docker-compose.pegaprox.yml` overlay, pinned to
1.2.0, fixed to match the image (`/app/config` and `/app/logs` volumes,
`PEGAPROX_BEHIND_PROXY=true`, trusted proxies = the edge subnet, a Python
healthcheck on `/api/health`), and drop the EXPERIMENTAL/BETA wording. It is
proven by the lab phase `tests/e2e/t1-pegaprox.sh`.

## Consequences

- Operators who enable it get a working, persistent PegaProx behind Traefik
  basic auth (or oauth2-proxy once Keycloak is wired).
- An operator who ran the 0.2.0 overlay has nothing worth migrating: its
  state was in anonymous volumes. Remove the old `pegaprox-data` volume.
- PegaProx's own admin account is created on first login, so the basic-auth
  layer in front of it is what protects that first-login window.
- Still not done: routing the VNC/SSH websockets (ports 5001/5002) and
  automating "add a cluster" in the lab; see `docs/roadmap.md`.
- The AGPL obligations apply to anyone who modifies PegaProx and offers it
  to others over a network; running the upstream image unmodified, as here,
  does not change this repo's MIT licence.

## Alternatives considered

- **Make PegaProx part of the default stack** — rejected: write access to
  the cluster from a second UI widens the trust boundary for every
  deployment, including those that only want monitoring and NIS2 reports.
- **Drop the overlay** — rejected: it works now, it's tested, and some
  operators want its management features next to the monitoring stack.
- **Keep the EXPERIMENTAL label** — rejected: the label was about upstream
  maturity, and upstream now ships stable 1.x releases.
