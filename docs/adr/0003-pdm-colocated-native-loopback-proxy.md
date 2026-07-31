# ADR-0003: Proxmox Datacenter Manager co-located natively on the monitoring VM, proxied via loopback

Status: Accepted
Date: 2026-07-31

## Context

Proxmox Datacenter Manager (PDM) is officially distributed only as a native
`.deb` package — there is no official container image, and nesting a full
Proxmox-family package inside Docker (or worse, inside a nested-KVM VM) adds
fragility for no real benefit. At the same time, the corporate firewall
perimeter allows only 80/443/22 through to the monitoring VM
(see `docs/network-port-matrix.md`) — PDM's own web UI defaults to
`:8443`, which would otherwise need its own perimeter firewall rule.

An earlier draft of this ADR assumed PDM's listener could simply be bound
to `127.0.0.1:8443` (a "loopback bind"), analogous to how PVE's `pveproxy`
supports a `LISTEN_IP` override in `/etc/default/pveproxy`. This was
verified against the official PDM docs and the Proxmox support forum and
turned out to be **wrong**: PDM reuses Proxmox Backup Server's proxy stack,
which Proxmox staff have confirmed on the forum has no `LISTEN_IP`
equivalent and always binds `0.0.0.0:8443` — the same limitation applies to
PDM (different architecture from `pveproxy`, no supported bind-address
override). The isolation mechanism below reflects this corrected
understanding rather than the original assumption.

## Decision

Install PDM natively (`apt`, official Proxmox repo) directly on the same VM
that runs the Docker Compose stack — a hybrid host, not a separate PDM VM.
Since PDM itself cannot be told to bind only to loopback, isolate it with a
**host nftables rule** (`scripts/configure-pdm-firewall.sh`) that drops all
traffic to tcp/8443 except from `127.0.0.1` and the Docker `monitoring-edge`
network's fixed subnet (`172.28.0.0/24`, pinned in `docker-compose.yml`).
Traefik, running in a container on that same host, reaches PDM via
`host.docker.internal` (wired through
`extra_hosts: host.docker.internal:host-gateway` in `docker-compose.yml`,
whose source address falls inside the allow-listed edge subnet) and
reverse-proxies `pdm.${BASE_DOMAIN}` to it
(`config/traefik/dynamic/pdm.yml`).

## Consequences

- PDM never needs its own perimeter firewall rule: even though it still
  technically binds `0.0.0.0:8443` at the application level, the host
  nftables rule makes it unreachable from the management LAN or any other
  network the VM is attached to — only loopback and the Docker edge
  subnet can reach it. Only 443 (already open) reaches it externally,
  multiplexed through Traefik same as every other routed service.
- This is a **host-level control, not an application-level one** — unlike
  a true loopback bind, it depends on `scripts/configure-pdm-firewall.sh`
  having been run and `nftables.service` staying enabled. This is a real,
  accepted operational dependency: `docs/deployment-guide.md` includes it
  as a mandatory bootstrap step (not optional hardening), and
  `docs/troubleshooting.md` covers verifying the rule is active
  (`nft list table inet proxmox_biome_pdm`).
- If the `monitoring-edge` Docker network's subnet ever changes, both
  `docker-compose.yml`'s `ipam.config` and
  `scripts/configure-pdm-firewall.sh`'s `EDGE_SUBNET` must be updated
  together — they are not derived from a single source of truth, since
  nftables rules are evaluated independently of Docker's own network
  state. Documented inline in both files.
- PDM ships a self-signed certificate by default; the Traefik→PDM backend
  hop is over that self-signed connection, so
  `config/traefik/dynamic/pdm.yml` sets `insecureSkipVerify: true` on a
  *scoped* `serversTransport` (`pdm-loopback`) that applies only to this
  one backend connection — not a global TLS verification bypass. This is
  a deliberate, documented exception (see the comment block in that file
  and `docs/hardening.md#pdm-loopback-tls`), justified because the
  connection is confined to the host and its Docker bridge by the
  nftables rule above, not because it travels over loopback specifically.
- `docker container → host` addressing is not automatic — `127.0.0.1`
  inside a container refers to the container's own network namespace, not
  the host's. This requires the `host.docker.internal` / `host-gateway`
  wiring documented above; getting this wrong (pointing Traefik at literal
  `127.0.0.1:8443`) silently produces a "connection refused" that looks
  like PDM itself is down when it's actually a routing mistake — called
  out explicitly in `docs/troubleshooting.md`.
- The monitoring VM now has one component (PDM) managed outside Docker
  Compose's usual `docker compose pull && up -d` update flow — PDM updates
  are a separate `apt upgrade` step, documented in
  `docs/deployment-guide.md`.
- PDM's own auth (initially local, later Keycloak OIDC per
  `docs/keycloak-integration.md`) is layered underneath Traefik's edge
  auth (`basicAuth` bootstrap, later `oauth2-proxy` ForwardAuth) — two
  auth layers by design during the local-auth bootstrap phase, collapsing
  to Keycloak SSO end-to-end once wired up.

## Alternatives considered

- **PDM in a separate VM** — rejected: an extra VM to provision/patch/back
  up for a single component, and it would need its own path through the
  perimeter firewall (another 443 vhost or another IP+port combination),
  which co-locating it avoids entirely.
- **PDM nested in a Docker container via some unofficial image** —
  rejected: no official image exists; building and maintaining an
  unofficial one adds an unverified, self-maintained attack surface for a
  security-sensitive management tool, for no benefit over the native
  package (see the same reasoning that led to ADR-0007's checksum-verified
  approach for cv4pve tools — but PDM is a much larger, more privileged
  package than a single CLI binary, where that tradeoff doesn't hold).
- **Bind PDM to the VM's external interface directly and open 8443 on the
  perimeter** — rejected: the whole point of the 80/443/22 constraint is
  to minimize the perimeter's exposed surface; adding a fourth open port
  defeats that, and Traefik can front unlimited internal services through
  a single 443 entrypoint instead.
- **A reverse-proxy-only isolation with no host firewall rule at all**
  (relying solely on the fact that nothing routes to `:8443` externally)
  — rejected: without the nftables rule, PDM's `0.0.0.0:8443` bind is
  directly reachable by anything on the management LAN that can reach the
  VM's IP at all (any other cluster node, any compromised host on that
  VLAN), which is a materially worse blast radius than a host-firewalled
  port. The nftables rule is what actually closes that gap.
