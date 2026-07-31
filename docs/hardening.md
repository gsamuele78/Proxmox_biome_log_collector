# Hardening baseline

This is the single source of truth for *why* the stack is configured the
way it is — referenced from `docker-compose.yml` comments and the ADRs
rather than repeated inline.

## Container hardening (applied uniformly)

Every service in `docker-compose.yml` gets, via the `default-hardening`
YAML anchor unless a specific exception is documented below:

- **Pinned image tags** — no `:latest` anywhere; every image is pinned to
  a specific version verified against its registry before being added.
- **`no-new-privileges: true`** — blocks privilege escalation via setuid
  binaries inside the container.
- **`cap_drop: [ALL]`**, with capabilities re-added only where a specific
  service needs one (only Traefik, for `NET_BIND_SERVICE` to bind ports
  80/443 as non-root).
- **`read_only: true`** root filesystem, with explicit `tmpfs`/named
  volumes for the specific paths each service needs to write to. This
  means a compromised process can't persist a modified binary or drop a
  new one into the image's own filesystem.
- **Non-root `user:`** where the upstream image supports it — explicit
  `65532:65532` (the distroless "nonroot" UID) for the custom cv4pve
  images; the upstream Grafana/Prometheus/Loki/Traefik images already run
  as non-root by default.
- **Per-service resource limits** (`deploy.resources.limits`) — bounds the
  blast radius of a runaway or compromised process.
- **`restart: unless-stopped`** and log rotation (`json-file`, 10 MB × 3
  files) on every service, so a crash-looping or noisy container can't
  fill the host's disk.
- **No host ports published** except Traefik's 80/443 — every other
  service is reachable only via the internal Docker networks. See
  `docs/network-port-matrix.md`.

## Network segmentation

Two Docker networks, `monitoring-edge` and `monitoring-backend` — see
`docs/architecture.md#network-segmentation` for the full breakdown. The
scoped `docker-socket-proxy` (read-only subset of the Docker API: watch
containers/networks/events only, no service/task/POST access) sits between
Traefik and the real Docker socket so a compromised Traefik container
can't use the socket to escape to the host or control other containers.

## No `HEALTHCHECK` on distroless services

`cv4pve-metrics-exporter` and `cv4pve-diag` (ADR-0007) run from
`gcr.io/distroless/cc-debian12:nonroot` final-stage images — deliberately
no shell, no package manager, nothing beyond the single binary and its
glibc/libstdc++ runtime dependencies. This means there is no `wget`/`curl`
available to run as a container-level `HEALTHCHECK` probe.

Rather than adding a shell back in just to run a healthcheck (which would
undo the actual security benefit of the distroless base — see ADR-0007's
"alternatives considered"), health is observed externally instead:

- `cv4pve-metrics-exporter`'s liveness is Prometheus's own
  `up{job="cv4pve-metrics-exporter"}` scrape-success metric — if the
  exporter is down or unreachable, this flips to `0` and
  `config/prometheus/rules/proxmox.rules.yml` alerts on it the same way it
  would for any other down target.
- `cv4pve-diag` is a one-shot job (`profiles: [tools]`, run by
  `scripts/systemd/cv4pve-diag.timer`), not a long-running service — its
  "health" is whether `scripts/run-cv4pve-diag.sh` exits non-zero, which
  systemd's own `OnFailure=`/journal already surfaces.

## PDM loopback TLS

`config/traefik/dynamic/pdm.yml` sets `insecureSkipVerify: true` on a
*scoped* `serversTransport` (`pdm-loopback`) that applies only to
Traefik's one backend connection to PDM's self-signed certificate — not a
global TLS verification bypass anywhere else in the stack.

This is justified because that connection never reaches the management
LAN or perimeter: PDM's API daemon has no configurable listen address (it
always binds `0.0.0.0:8443` — see ADR-0003), so a host nftables rule
(`scripts/configure-pdm-firewall.sh`) restricts tcp/8443 to loopback and
the `monitoring-edge` Docker network's subnet only, before Traefik's
container-to-host hop (`host.docker.internal`) ever happens. The
`insecureSkipVerify` exception is scoped to exactly that already-isolated
path — swapping PDM's self-signed cert for an internally-issued one would
remove the need for it, at the cost of a manual cert-rotation step PDM
doesn't otherwise require.

## TLS

Traefik's TLS options (`config/traefik/dynamic/tls-options.yml`) pin a
"modern" profile: TLS 1.2 minimum (1.3 preferred by client/server
negotiation order), a curated AEAD-only cipher suite list, X25519/P-256
curve preference, and strict SNI matching. TLS 1.0/1.1 and non-AEAD
ciphers are never offered. See `docs/deployment-guide.md#tls-certificates`
for the ACME-vs-internal-CA certificate options this profile applies to.

## NIS2 Article 21 control mapping

NIS2 Article 21 requires "appropriate and proportionate" technical and
organisational measures across several risk-management pillars. This maps
each pillar to what's actually shipped in this repo — not an aspirational
checklist:

| NIS2 Art. 21 pillar | Mechanism in this repo |
| --- | --- |
| Risk analysis / policies for information system security | `docs/adr/*` — every architectural security decision is recorded with its reasoning, alternatives, and consequences. |
| Incident handling | Prometheus alert rules (`config/prometheus/rules/*.yml`) → Alertmanager → email/webhook (`config/alertmanager/alertmanager.yml.tmpl`); `docs/runbook-incident-response.md` for the triage/escalation/notification workflow. |
| Business continuity, backup management, disaster recovery | Out of scope for this repo directly (Ceph's own replication and Proxmox Backup Server are the cluster's continuity mechanisms) — this stack *monitors* those, it doesn't replace them; see `docs/roadmap.md` for planned coverage of PBS job status. |
| Supply-chain security | Pinned image tags, no `:latest`; checksum-verified upstream `.deb` downloads for custom images (ADR-0007); `security-scan.yml` runs Trivy against both config and built images, plus gitleaks for committed secrets, on every push and weekly on a schedule. |
| Security in network and information systems acquisition, development, maintenance (vulnerability handling, disclosure) | `security-scan.yml`'s Trivy job fails CI on CRITICAL/HIGH findings; `SECURITY.md` documents the vulnerability-reporting process. |
| Policies/procedures on the use of cryptography | TLS profile above; PVE API access uses scoped, least-privilege API tokens (`.env.example`'s `PVE_API_TOKEN_ID`/`_SECRET` comments recommend the `PVEAuditor` role, not root). |
| Human resources security, access control, asset management | Local-auth bootstrap → Keycloak OIDC SSO for every exposed surface (ADR-0006, `docs/keycloak-integration.md`); `auditd` rules on each PVE node watching `/etc/pve`, `/etc/passwd`, `/etc/shadow`, `/etc/sudoers*`, `/etc/ssh/sshd_config` (`scripts/node-setup/configure-auditd.sh`) provide the access-change traceability trail, shipped to Loki via Alloy. |
| Use of MFA, secured communications | Keycloak realm (once configured) is where MFA policy is enforced for every surface behind `oauth2-proxy`/native OIDC; all external access is HTTPS-only through Traefik, no plaintext HTTP surface beyond the ACME challenge/redirect. |

This table intentionally doesn't claim full NIS2 compliance on its own —
it maps *mechanisms present in this repository* to the pillars they
support. Organisational measures (policies, training, formal incident
notification to the competent authority within the 24h/72h windows) are
process, not code — see `docs/runbook-incident-response.md` for where this
repo's tooling plugs into that process.
