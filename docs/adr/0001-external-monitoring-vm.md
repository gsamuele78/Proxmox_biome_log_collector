# ADR-0001: Dedicated external VM for monitoring/audit, outside the Ceph/Proxmox cluster

Status: Accepted
Date: 2026-07-31

## Context

The Proxmox VE + Ceph cluster this stack observes is growing from 7 to 11
nodes. Cluster nodes themselves are the thing being monitored for
availability, health, and (for NIS2) compliance evidence. Running the
monitoring/alerting/audit stack as a VM or set of containers *on* that same
cluster creates a circular dependency: if a Ceph or Proxmox VE incident is
severe enough to take down the cluster's own compute/storage, the tooling
you need to diagnose and report on that incident goes down with it.

## Decision

Run the entire observability/audit stack (Traefik, Prometheus, Alertmanager,
Grafana, Loki, cv4pve-metrics-exporter, cv4pve-diag, PDM) on a single VM that
is **not** hosted on the Ceph/Proxmox cluster it monitors — a separate host
on the same management network/VLAN.

## Consequences

- Monitoring/alerting keeps working during a cluster-wide incident (the
  scenario where you need it most).
- One more host to patch/back up/secure, distinct from the cluster's own
  Ceph/PBS backup story — documented in `docs/deployment-guide.md`.
- Requires the monitoring VM to reach every cluster node over the
  management LAN (node_exporter :9100, Ceph mgr :9283, Loki push :3100,
  PVE API :8006) — network segmentation implications are covered in
  `docs/network-port-matrix.md`.
- If the monitoring VM itself fails, you lose observability but not the
  cluster's actual workloads — an acceptable, and more recoverable, failure
  mode than the reverse.

## Alternatives considered

- **Run it as a VM/CT on the Ceph/Proxmox cluster itself** — rejected:
  the circular-dependency problem above. Also complicates the "the
  monitoring stack watches the storage it also depends on" bootstrapping
  story.
- **No dedicated monitoring stack, rely on Proxmox VE's built-in UI/alerts
  only** — rejected: insufficient for cross-node aggregation, log
  correlation, alerting routing, and NIS2 compliance evidence (Proxmox's
  own UI doesn't produce auditable historical reports).
