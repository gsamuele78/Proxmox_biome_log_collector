# Proxmox Biome — Observability, Audit & NIS2 Compliance Stack

[![Lint](https://github.com/gsamuele78/Proxmox_biome_log_collector/actions/workflows/lint.yml/badge.svg?branch=main)](https://github.com/gsamuele78/Proxmox_biome_log_collector/actions/workflows/lint.yml)
[![Validate and test](https://github.com/gsamuele78/Proxmox_biome_log_collector/actions/workflows/validate-and-test.yml/badge.svg?branch=main)](https://github.com/gsamuele78/Proxmox_biome_log_collector/actions/workflows/validate-and-test.yml)
[![Security scan](https://github.com/gsamuele78/Proxmox_biome_log_collector/actions/workflows/security-scan.yml/badge.svg?branch=main)](https://github.com/gsamuele78/Proxmox_biome_log_collector/actions/workflows/security-scan.yml)
[![Version](https://img.shields.io/github/v/tag/gsamuele78/Proxmox_biome_log_collector?sort=semver&label=version)](CHANGELOG.md)
[![Last commit](https://img.shields.io/github/last-commit/gsamuele78/Proxmox_biome_log_collector/main)](https://github.com/gsamuele78/Proxmox_biome_log_collector/commits/main)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[![Traefik](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Fgsamuele78%2FProxmox_biome_log_collector%2Fmain%2Fdocker-compose.yml&query=%24.services.traefik.image&label=traefik)](docker-compose.yml)
[![Prometheus](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Fgsamuele78%2FProxmox_biome_log_collector%2Fmain%2Fdocker-compose.yml&query=%24.services.prometheus.image&label=prometheus)](docker-compose.yml)
[![Alertmanager](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Fgsamuele78%2FProxmox_biome_log_collector%2Fmain%2Fdocker-compose.yml&query=%24.services.alertmanager.image&label=alertmanager)](docker-compose.yml)
[![Loki](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Fgsamuele78%2FProxmox_biome_log_collector%2Fmain%2Fdocker-compose.yml&query=%24.services.loki.image&label=loki)](docker-compose.yml)
[![Grafana](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Fgsamuele78%2FProxmox_biome_log_collector%2Fmain%2Fdocker-compose.yml&query=%24.services.grafana.image&label=grafana)](docker-compose.yml)
[![cv4pve-diag](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Fgsamuele78%2FProxmox_biome_log_collector%2Fmain%2Fdocker-compose.yml&query=%24.services%5B%27cv4pve-diag%27%5D.image&label=cv4pve-diag)](docker/cv4pve-diag/Dockerfile)

The badges update themselves: CI status from the workflows, the release
from the latest `vX.Y.Z` tag (whose notes come from [CHANGELOG.md](CHANGELOG.md)),
component versions from the tags pinned in `docker-compose.yml` on `main`.

A single external monitoring/audit VM for a growing Proxmox VE + Ceph
cluster: metrics, logs, alerting, and NIS2-tagged compliance reporting,
behind a hardened Traefik reverse proxy, with local-auth bootstrap and a
supported path to Keycloak SSO.

## Why

Monitoring a Proxmox/Ceph cluster that's growing (in the case this repo
was built for, 7 → 11 nodes) means aggregating health, metrics, logs, and
compliance evidence from *outside* the cluster — so the monitoring stack
keeps working even if the cluster itself is degraded. This repo is that
external stack: production-grade, tested, and documented, not a one-off
script collection.

## Architecture

```mermaid
flowchart LR
  subgraph Perimeter["Corporate firewall / VPN — only 80, 443, 22 open"]
    Admin[Admin browser / VPN client]
  end

  Admin -->|443 HTTPS only| Traefik

  subgraph VM["Monitoring VM (single host)"]
    Traefik["Traefik :80/:443"]
    PDM["PDM (native apt package)\n:8443, nftables-restricted"]
    subgraph Docker["Docker Compose stack"]
      Prometheus[Prometheus]
      Grafana[Grafana]
      Loki[Loki]
      Alertmanager[Alertmanager]
      CvExporter[cv4pve-metrics-exporter]
      CvDiag["cv4pve-diag (NIS2 compliance)"]
    end
    Traefik --> PDM
    Traefik --> Grafana
    Grafana --> Prometheus
    Grafana --> Loki
    Prometheus --> Alertmanager
  end

  subgraph Nodes["Proxmox VE cluster nodes — internal management LAN"]
    NodeExp["node_exporter"]
    CephMgr["ceph mgr prometheus"]
    Alloy["Grafana Alloy"]
  end

  Prometheus --> NodeExp
  Prometheus --> CephMgr
  Alloy --> Loki
  CvExporter -->|PVE API| Nodes
```

See [docs/architecture.md](docs/architecture.md) for the full diagram,
data flow, and network segmentation, and
[docs/network-port-matrix.md](docs/network-port-matrix.md) for the
authoritative port-by-port breakdown.

## What's in the stack

| Component | Role |
| --- | --- |
| **Traefik** | Reverse proxy — the *only* thing exposed past the corporate perimeter (443). |
| **Prometheus + Alertmanager** | Metrics collection and alerting for PVE nodes and Ceph. |
| **Grafana** | Dashboards (Node Exporter Full, Ceph Cluster, provisioned automatically). |
| **Loki + Grafana Alloy** | Log aggregation, including `auditd` traceability logs from each node. |
| **cv4pve-metrics-exporter** | PVE-object-level metrics (VM/LXC/storage state) that node_exporter/Ceph's own exporter don't cover. |
| **cv4pve-diag** | Default NIS2/ISO27001/GDPR/DORA-tagged compliance auditor, scheduled daily. |
| **Proxmox Datacenter Manager (PDM)** | Native install, reverse-proxied — see [ADR-0003](docs/adr/0003-pdm-colocated-native-loopback-proxy.md). |
| **PegaProx** | Optional, opt-in, EXPERIMENTAL — see [ADR-0005](docs/adr/0005-cv4pve-diag-default-pegaprox-experimental.md). |
| **oauth2-proxy** | Keycloak OIDC ForwardAuth for services with no native SSO support (Phase 2 — [ADR-0006](docs/adr/0006-local-auth-bootstrap-then-keycloak-oidc.md)). |

Every design decision above — and the alternatives considered and
rejected — is recorded in [docs/adr/](docs/adr/).

## Quick start

```bash
git clone https://github.com/gsamuele78/Proxmox_biome_log_collector.git
cd Proxmox_biome_log_collector
cp .env.example .env
"${EDITOR:-vi}" .env
scripts/generate-secrets.sh
scripts/bootstrap-monitoring-vm.sh
```

This is the abbreviated version — the full walkthrough (VM sizing, Docker
Engine install, native PDM install + its required host firewall step,
per-node agent setup, TLS certificate options) is
[docs/deployment-guide.md](docs/deployment-guide.md).

## Documentation

- [docs/architecture.md](docs/architecture.md) — diagram, data flow, network segmentation.
- [docs/network-port-matrix.md](docs/network-port-matrix.md) — authoritative port table.
- [docs/deployment-guide.md](docs/deployment-guide.md) — step-by-step deployment.
- [docs/hardening.md](docs/hardening.md) — container hardening baseline + NIS2 Art. 21 control mapping.
- [docs/keycloak-integration.md](docs/keycloak-integration.md) — Phase 2 SSO wiring.
- [docs/troubleshooting.md](docs/troubleshooting.md) — symptom → cause → fix.
- [docs/runbook-incident-response.md](docs/runbook-incident-response.md) — alert catalogue, alert → triage → NIS2 notification timeline.
- [docs/testing.md](docs/testing.md) — every test layer, lab phase and CI job, and what to run for which change.
- [docs/maintenance-guide.md](docs/maintenance-guide.md) — changing, bumping, releasing and upgrading (humans); [AGENTS.md](AGENTS.md) is the agent version.
- [docs/repo-audit.md](docs/repo-audit.md) — what the repo contains vs what was documented, and what was fixed.
- [docs/roadmap.md](docs/roadmap.md) — deliberately deferred work, and why.
- [docs/adr/](docs/adr/) — every architectural decision, with alternatives considered.
- [docs/plan/EXECUTION-PLAN.md](docs/plan/EXECUTION-PLAN.md) — the build plan this repo was built from, checked off.
- [docs/plan/NEXT-SESSION-PLAN.md](docs/plan/NEXT-SESSION-PLAN.md) — what comes after 0.2.0 (upgrade, image bumps, PegaProx, Dependabot).
- [docs/research/original-chat-transcript.md](docs/research/original-chat-transcript.md) — the original research that motivated this repo (provenance only, unedited).

## Testing & CI

| Layer | Runs in | Proves |
| --- | --- | --- |
| Lint, changelog and drift checks | CI, `make lint` | style, no secrets, docs agree with code |
| Config validation | CI, `make validate` | compose, `promtool`, `amtool` accept the configs |
| Smoke test | CI, `make test` | the stack boots and every container is healthy |
| Deployment e2e | CI (`deploy-e2e`) | the documented root bootstrap, auth, TLS redirect, Loki round trip, Grafana datasources, an alert delivered by mail |
| VM lab tiers 1-3 | local libvirt, `make lab-up && make lab-test` | real PVE node, 3-node Ceph cluster, failover alerts, Keycloak OIDC |

CI has no Proxmox or Ceph, so anything touching them is proven only by the
lab. See [docs/testing.md](docs/testing.md) for the full catalogue and
[tests/README.md](tests/README.md) for the commands.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues:
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE).
