# syntax=docker/dockerfile:1
## cv4pve-metrics-exporter has no official Docker image (verified against
## https://github.com/Corsinvest/cv4pve-metrics-exporter and Docker Hub/GHCR —
## see docs/adr/0007-custom-cv4pve-images.md). This Dockerfile downloads the
## real, pinned .deb release asset, verifies it against a checksum computed
## directly from that release by the repo maintainer (not trusted blindly),
## and copies the single self-contained binary into a minimal distroless
## final stage. `ldd` on the extracted binary confirmed it only depends on
## glibc/libstdc++/libgcc_s/libpthread/libm/libdl/librt — exactly what
## gcr.io/distroless/cc-debian12 provides, nothing more.

FROM debian:trixie-slim AS builder

ARG CV4PVE_VERSION=2.0.0
ARG CV4PVE_DEB_SHA256=d67d16bb91894a201968eb15ed79086036edf6085d4dc8a4d3a042b02b7859fb
ARG CV4PVE_DEB_URL=https://github.com/Corsinvest/cv4pve-metrics-exporter/releases/download/v${CV4PVE_VERSION}/cv4pve-metrics-exporter-${CV4PVE_VERSION}-amd64.deb

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ca-certificates/curl are build-stage-only tooling (never shipped in the
# final distroless image below) — pinning their exact Debian package version
# would only make this Dockerfile break every time trixie's archive rotates,
# for no security benefit.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN curl -fsSL -o cv4pve-metrics-exporter.deb "${CV4PVE_DEB_URL}" \
    && echo "${CV4PVE_DEB_SHA256}  cv4pve-metrics-exporter.deb" | sha256sum -c - \
    && dpkg-deb -x cv4pve-metrics-exporter.deb /build/extracted \
    && install -m 0755 -o root -g root /build/extracted/usr/bin/cv4pve-metrics-exporter /build/cv4pve-metrics-exporter

# Bake a settings.json with the exporter's HTTP listener bound to all
# interfaces (default is "localhost", which would be unreachable from other
# containers — e.g. Prometheus — since "localhost" resolves inside this
# container's own network namespace, not the Docker bridge). No PVE
# credentials live in this file; those are passed via --api-token at
# container start (see docker-compose.yml).
RUN /build/cv4pve-metrics-exporter create-settings --full -o /build/settings.json \
    && sed -i 's/"Host": "localhost"/"Host": "0.0.0.0"/' /build/settings.json \
    && grep -q '"Host": "0.0.0.0"' /build/settings.json

FROM gcr.io/distroless/cc-debian12:nonroot

COPY --from=builder --chown=nonroot:nonroot /build/cv4pve-metrics-exporter /usr/bin/cv4pve-metrics-exporter
COPY --from=builder --chown=nonroot:nonroot /build/settings.json /etc/cv4pve/settings.json

USER nonroot
EXPOSE 9221
ENTRYPOINT ["/usr/bin/cv4pve-metrics-exporter"]
CMD ["--help"]
