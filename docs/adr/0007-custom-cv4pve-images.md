# ADR-0007: Custom, checksum-pinned Docker images for cv4pve-diag and cv4pve-metrics-exporter

Status: Accepted
Date: 2026-07-31

## Context

Corsinvest's `cv4pve-diag` and `cv4pve-metrics-exporter` are distributed as
`.deb` packages (and other native package formats) via GitHub Releases —
verified against both projects' GitHub repos and Docker Hub/GHCR, neither
publishes an official container image. This stack needs both tools running
as containers alongside everything else in `docker-compose.yml`.

## Decision

Build minimal custom images (`docker/cv4pve-diag/Dockerfile`,
`docker/cv4pve-metrics-exporter/Dockerfile`) using a two-stage build:

1. A `debian:trixie-<date>-slim` builder stage (dated tag, so builds are
   reproducible) downloads the pinned release `.deb`
   (`ARG CV4PVE_VERSION`), verifies it against a SHA-256 checksum computed
   directly from that release asset (`ARG CV4PVE_DEB_SHA256`) rather than
   trusting the download blindly, and extracts the single binary.
2. A `gcr.io/distroless/cc-debian13:nonroot` final stage (Debian 12 until
   0.3.0; the binaries need glibc 2.27 at most, so either works) copies in just that
   binary (`ldd`-verified to depend only on glibc/libstdc++/libgcc_s/
   libpthread/libm/libdl/librt — exactly what that distroless base
   provides) — no shell, no package manager, no unrelated tooling shipped.

## Consequences

- No official upstream image to track for updates — version bumps mean
  updating `CV4PVE_VERSION` and `CV4PVE_DEB_SHA256` by hand against a new
  GitHub release, documented in `docs/deployment-guide.md`. This is a real,
  accepted maintenance cost of building our own image for a tool that
  doesn't publish one.
- The final images have **no shell**. This has concrete downstream
  consequences addressed elsewhere in the repo rather than papered over:
  - No container-level `HEALTHCHECK` is possible for
    `cv4pve-metrics-exporter` (no `wget`/`curl` to run as a probe) — health
    is instead observed via Prometheus's own
    `up{job="cv4pve-metrics-exporter"}` scrape metric (see the comment in
    `docker-compose.yml` and `docs/hardening.md`).
  - Combining `PVE_API_TOKEN_ID` and `PVE_API_TOKEN_SECRET` into the single
    `--api-token=ID=SECRET` CLI flag both tools require cannot happen via
    in-container shell expansion — it's built instead by Docker Compose's
    own `${VAR}` interpolation of the `command:` array at compose-parse
    time, before the container starts (see the same services in
    `docker-compose.yml`).
- Smaller attack surface than a full Debian-based final image: no shell for
  an attacker to pivot with if either binary were ever compromised via a
  supply-chain issue, no package manager to install further tooling.
- `cv4pve-metrics-exporter`'s generated default `settings.json` binds its
  Prometheus HTTP listener to `"Host": "localhost"` — patched at
  image-build time to `"0.0.0.0"` (baked into the image, no PVE credentials
  in that file) so other containers on the `backend` network can actually
  reach it; documented inline in the Dockerfile since it's a non-obvious,
  easy-to-silently-break-on-upgrade default.

## Alternatives considered

- **Run the tools directly on the monitoring VM host (native `.deb`
  install), not containerized** — rejected: breaks the "everything but
  PDM lives in Docker Compose" consistency this repo otherwise maintains,
  and loses per-service resource limits/network isolation the rest of the
  stack gets for free from Compose.
- **A full `debian:trixie-slim` final image instead of distroless** —
  rejected: keeps a shell and package manager in the final image for no
  functional benefit, trading a real security-surface reduction for the
  convenience of being able to `docker exec` a shell into it (which
  `docker compose logs` and the compose-level command-building approach
  above make largely unnecessary anyway).
- **Trust the downloaded `.deb` without a checksum check** — rejected
  outright: a supply-chain compromise of the GitHub release asset would go
  undetected; the checksum is computed independently from the release
  artifact rather than copied from anywhere the artifact itself could have
  tampered with.
