# syntax=docker/dockerfile:1
## cv4pve-diag has no official Docker image (verified against
## https://github.com/Corsinvest/cv4pve-diag and Docker Hub/GHCR — see
## docs/adr/0007-custom-cv4pve-images.md). Same approach as
## docker/cv4pve-metrics-exporter/Dockerfile: pinned release .deb, checksum
## verified against a hash computed directly from the release by the repo
## maintainer, binary copied into a minimal distroless final stage. `ldd`
## confirmed the same dependency set (glibc/libstdc++/libgcc_s/libpthread/
## libm/libdl/librt) — no shell, no package manager, no unrelated tooling in
## the shipped image.
##
## This is a one-shot CLI tool (profiles: ["tools"] in docker-compose.yml,
## triggered by a host systemd timer via `docker compose run --rm
## cv4pve-diag`) — not a long-running service, so there is deliberately no
## HEALTHCHECK or EXPOSE here.

FROM debian:trixie-20260918-slim AS builder

ARG CV4PVE_VERSION=2.7.0
ARG CV4PVE_DEB_SHA256=19fcb83f96dcbed88abeeb7a8b24a06efad8566c9a8f8e3ccbbfa68301b46b40
ARG CV4PVE_DEB_URL=https://github.com/Corsinvest/cv4pve-diag/releases/download/v${CV4PVE_VERSION}/cv4pve-diag-${CV4PVE_VERSION}-amd64.deb

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ca-certificates/curl are build-stage-only tooling (never shipped in the
# final distroless image below) — pinning their exact Debian package version
# would only make this Dockerfile break every time trixie's archive rotates,
# for no security benefit.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN curl -fsSL -o cv4pve-diag.deb "${CV4PVE_DEB_URL}" \
    && echo "${CV4PVE_DEB_SHA256}  cv4pve-diag.deb" | sha256sum -c - \
    && dpkg-deb -x cv4pve-diag.deb /build/extracted \
    && install -m 0755 -o root -g root /build/extracted/usr/bin/cv4pve-diag /build/cv4pve-diag \
    && mkdir -p /build/reports

FROM gcr.io/distroless/cc-debian12:nonroot

COPY --from=builder --chown=nonroot:nonroot /build/cv4pve-diag /usr/bin/cv4pve-diag
# Mount point for the cv4pve-diag-reports named volume. It must exist in the
# image and be owned by nonroot: Docker copies a mount point's ownership onto
# an empty named volume, and without this the volume is root-owned and the
# nonroot process cannot write its report (distroless has no shell to fix it
# at runtime).
COPY --from=builder --chown=nonroot:nonroot /build/reports /reports

USER nonroot
ENTRYPOINT ["/usr/bin/cv4pve-diag"]
CMD ["--help"]
