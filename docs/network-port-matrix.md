# Network port matrix

This supersedes the several conflicting port lists that appeared over the
course of the original research chat
(`docs/research/original-chat-transcript.md`). Two zones matter, and the
firewall rules that apply to each are different — conflating them is where
the transcript's earlier drafts went wrong.

## Zone 1: Corporate perimeter / VPN → monitoring VM

The corporate firewall/VPN this VM sits behind allows **only** these ports
inbound from an admin's browser or VPN client:

| Port | Protocol | Purpose                                                        |
| ---- | -------- | --------------------------------------------------------------- |
| 22   | TCP      | SSH — host administration                                       |
| 80   | TCP      | HTTP — Traefik, redirects to 443 and serves ACME HTTP-01 only    |
| 443  | TCP      | HTTPS — Traefik, every routed service multiplexed by hostname    |

Nothing else is ever exposed on the monitoring VM's external-facing
interface. Grafana (3000), Prometheus (9090), Alertmanager (9093), the Traefik dashboard (8080 internal), PDM (8443), PegaProx
(5000-5002), and every exporter port are reached exclusively through
Traefik on 443, host-routed by name (`grafana.${BASE_DOMAIN}`,
`prometheus.${BASE_DOMAIN}`, `pdm.${BASE_DOMAIN}`, `audit.${BASE_DOMAIN}`,
`traefik.${BASE_DOMAIN}`, `alertmanager.${BASE_DOMAIN}`, and
`pegaprox.${BASE_DOMAIN}` if that optional overlay is enabled).

## Zone 2: Monitoring VM ↔ Proxmox VE cluster nodes (internal management LAN)

Confirmed with the user as **not** subject to the 80/443/22 perimeter
restriction — this is internal VM-to-VM / VM-to-node traffic on the
management network/VLAN, using each service's normal port:

| Port | Protocol | Direction                          | Purpose                                             |
| ---- | -------- | ----------------------------------- | ---------------------------------------------------- |
| 8006 | TCP      | monitoring VM → each PVE node        | PVE API — PDM, cv4pve-metrics-exporter, cv4pve-diag  |
| 9100 | TCP      | monitoring VM → each PVE node        | Prometheus scrapes node_exporter                     |
| 9283 | TCP      | monitoring VM → active Ceph mgr host | Prometheus scrapes Ceph's `mgr prometheus` module    |
| 3100 | TCP      | each PVE node → monitoring VM        | Alloy pushes logs to Loki's ingest API               |
| 22   | TCP      | monitoring VM ↔ each PVE node        | Ops/config-management SSH (not perimeter SSH)        |

## Internal-only (never leaves the Docker network or host loopback)

| Port | Where              | Purpose                                                              |
| ---- | ------------------ | ----------------------------------------------------------------------- |
| 8080 | Traefik container   | Internal `ping`/`metrics` entrypoint — not bound to any host port             |
| 2375 | docker-socket-proxy | Scoped Docker API access for Traefik's Docker provider (`edge` network) |
| 8443 | Host, nftables-restricted to loopback + `172.28.0.0/24` (edge) | PDM, natively installed. Binds `0.0.0.0:8443` at the app level (no configurable listen address exists) — isolation is enforced by `scripts/configure-pdm-firewall.sh`, not by an app-level bind. See ADR-0003. |
| 9090 | `backend` network   | Prometheus's own UI/API (reached via Traefik, not directly)             |
| 9093 | `backend` network   | Alertmanager's own UI/API (reached via Traefik, not directly)           |
| 8080 | `backend`+`edge`    | audit-report-server (nginx, reached via Traefik, not directly)          |
| 9221 | `backend` network   | cv4pve-metrics-exporter's Prometheus metrics endpoint                   |
| 3100 | Host, `LOKI_BIND_ADDR` | Loki push/query API — the one non-Traefik published port, so PVE nodes' Alloy agents can push (zone 2). Set `LOKI_BIND_ADDR` to the management-LAN IP so it is never bound on the perimeter-facing interface. |

## Why this resolves the original port-blocking problem

The only thing that ever crosses the corporate perimeter is 443 (plus 80
for redirect/ACME, and 22 for SSH). Every other port in this document is
either internal-only (Docker network, host loopback) or rides the
management LAN, which the user confirmed is unrestricted for this traffic.
This is the direct, concrete answer to "the firewall only allows
80/443/22(/8006)" — see ADR-0001 and ADR-0003 for the architectural
decisions that make it possible.
