# ADR-0002: Traefik as the reverse proxy, not Nginx Proxy Manager

Status: Accepted
Date: 2026-07-31

## Context

Everything exposed by the monitoring VM needs to sit behind a single
TLS-terminating reverse proxy, since the corporate firewall perimeter only
allows 80/443/22 through to this host (see `docs/network-port-matrix.md`).
The original chat-transcript research (`docs/research/original-chat-transcript.md`)
suggested Nginx Proxy Manager (NPM).

## Decision

Use **Traefik** (static + dynamic file-provider configuration, plus its
Docker provider for label-based service discovery) instead of NPM.

## Consequences

- Every routing/middleware/TLS decision lives in git-tracked YAML
  (`config/traefik/`), reviewable in a PR diff and testable in CI
  (`docker compose config`, `tests/lint/.yamllint.yml`) — NPM's config lives
  in a SQLite DB behind a click-ops UI, which is not git-diffable or
  CI-testable.
- New routed services declare their own router/middleware via Compose
  labels (see any `traefik.http.routers.*` label block in
  `docker-compose.yml`), so adding a service is a one-file diff instead of
  a manual UI action that has to be redone if the NPM container is ever
  rebuilt from scratch.
- Traefik's Docker provider needs *some* access to the Docker API to
  discover containers — mitigated by routing it through
  `docker-socket-proxy` with a minimal, explicitly-scoped permission set
  (`CONTAINERS`, `NETWORKS`, `EVENTS`, `PING`, `VERSION` only — see
  `docker-compose.yml`) rather than mounting `/var/run/docker.sock`
  directly into Traefik.
- Steeper initial learning curve than NPM's UI for admins unfamiliar with
  Traefik's static/dynamic config split — mitigated by
  `docs/deployment-guide.md` and `docs/troubleshooting.md`.

## Alternatives considered

- **Nginx Proxy Manager** — rejected: config lives in an opaque SQLite DB,
  not diffable/reviewable/testable as code; no first-class ForwardAuth
  middleware chain as clean as Traefik's for the Keycloak SSO rollout in
  `docs/keycloak-integration.md`.
- **Bare Nginx with hand-written vhost files** — rejected: no native Docker
  service-discovery, meaning every new service requires a manual
  vhost-file edit and a reload, more error-prone than label-based routing.
- **Caddy** — viable alternative (also config-as-code), not chosen mainly
  because Traefik's Docker-label-driven discovery and ForwardAuth
  middleware ecosystem are a closer fit for a Compose-based multi-service
  stack; noted here for future reconsideration, not ruled out on merit.
