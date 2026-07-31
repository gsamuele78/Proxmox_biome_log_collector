# Troubleshooting

Symptom → likely cause → fix, for the issues most likely to actually come
up on real hardware (as opposed to the CI smoke test's synthetic
environment — see `tests/README.md` for what that does and doesn't cover).

## PDM router returns "Bad Gateway" / connection refused

**Cause**: Traefik's `pdm.yml` router points at
`https://host.docker.internal:8443` (see ADR-0003). If you (or an edit)
change that to literal `127.0.0.1:8443`, it silently breaks: `127.0.0.1`
inside the Traefik *container* is the container's own loopback, not the
host's — there's nothing listening there. This looks exactly like "PDM
itself is down" from the outside, but PDM is fine; it's a routing mistake.

**Fix**: Confirm `docker-compose.yml`'s `traefik` service still has
`extra_hosts: ["host.docker.internal:host-gateway"]`, and that
`config/traefik/dynamic/pdm.yml`'s backend URL uses
`host.docker.internal`, not `127.0.0.1` or `localhost`. Then confirm PDM
is actually listening:

```bash
sudo ss -ltnp | grep 8443       # should show the PDM process
sudo nft list table inet proxmox_biome_pdm   # confirm the firewall rule exists
curl -k https://127.0.0.1:8443/  # from the HOST itself, not from inside a container
```

## PDM is reachable from other hosts on the management LAN

**Cause**: `scripts/configure-pdm-firewall.sh` was never run, or
`nftables.service` isn't enabled/running. PDM's API daemon has no
configurable listen address — it binds `0.0.0.0:8443` by design (see
ADR-0003) — so without the host firewall rule, it's directly reachable by
anything that can reach the VM's IP.

**Fix**:

```bash
sudo systemctl status nftables.service
sudo scripts/configure-pdm-firewall.sh   # idempotent, safe to re-run
sudo nft list table inet proxmox_biome_pdm
```

## Keycloak redirect loop / "Unexpected error when handling authentication request"

**Cause**: `KEYCLOAK_ISSUER_URL` includes an `/auth/` path segment
(`https://keycloak.example/auth/realms/corp`). Keycloak dropped that path
segment from its default configuration some time ago — using the old-style
URL against a current Keycloak version produces exactly this error.

**Fix**: Drop `/auth` from `KEYCLOAK_ISSUER_URL` —
`https://keycloak.example/realms/corp`, not
`https://keycloak.example/auth/realms/corp`. Verify by fetching the
discovery document directly:

```bash
curl -s "${KEYCLOAK_ISSUER_URL}/.well-known/openid-configuration" | head
```

If that 404s, the issuer URL is wrong regardless of the `/auth/` question.

## Let's Encrypt certificate never issues

**Cause 1**: `BASE_DOMAIN` isn't publicly resolvable, so Let's Encrypt's
HTTP-01 challenge can never reach Traefik. This is expected for an
internal-only hostname — see `docs/deployment-guide.md#tls-certificates`
for the internal-CA alternative; ACME was never going to work for a name
the internet can't resolve.

**Cause 2**: Port 80 isn't actually reaching Traefik (firewall, NAT, or a
different service already bound to host port 80). Check:

```bash
docker compose logs traefik | grep -i acme
sudo ss -ltnp | grep :80
```

**Cause 3**: `ACME_EMAIL` in `.env` is unset/still the placeholder —
Traefik's ACME resolver needs it (passed via the native
`TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL` env var, since
Traefik's static config file cannot expand `${VAR}` itself). Confirm it's
actually reaching the container:

```bash
docker compose exec traefik printenv | grep ACME_EMAIL
```

## Alertmanager container won't start / config parse error

**Cause**: `config/alertmanager/alertmanager.yml` doesn't exist or is
stale. Alertmanager's config is rendered from
`config/alertmanager/alertmanager.yml.tmpl` via `envsubst` at bootstrap
time (Alertmanager has no native `${VAR}` substitution) —
`scripts/bootstrap-monitoring-vm.sh` does this automatically, but if
you've edited `.env` *after* the last bootstrap run, the rendered file is
stale.

**Fix**: Re-run the bootstrap script, or render manually:

```bash
set -a; source .env; set +a
envsubst < config/alertmanager/alertmanager.yml.tmpl > config/alertmanager/alertmanager.yml
docker compose up -d alertmanager
```

## cv4pve-diag / cv4pve-metrics-exporter: can't `docker exec` a shell in to debug

**Cause**: both images are built from a distroless final stage (ADR-0007)
— no shell, no `sh`, `docker exec ... /bin/sh` will fail with "executable
file not found." This is intentional, not a bug.

**Fix**: debug via logs and Prometheus instead of exec'ing in:

```bash
docker compose logs cv4pve-metrics-exporter
docker compose run --rm --entrypoint="" cv4pve-diag /app/cv4pve-diag --version   # override entrypoint to test the binary directly
```

Check Prometheus's own view of the exporter's health:
`https://prometheus.${BASE_DOMAIN}/targets` → `job="cv4pve-metrics-exporter"`
should show `state=up`. If it's `down`, the error shown there (connection
refused, timeout, 401) is more informative than anything you'd get from a
shell anyway.

## `docker compose up` fails with a network/subnet conflict

**Cause**: `monitoring-edge`'s pinned subnet (`172.28.0.0/24`, in
`docker-compose.yml`) collides with an existing Docker network or the
host's own routing on that VM.

**Fix**: pick a different subnet in `docker-compose.yml`'s
`networks.edge.ipam.config` — but remember to also update
`scripts/configure-pdm-firewall.sh`'s `EDGE_SUBNET` to match (they're not
derived from each other; see ADR-0003's consequences section), then
re-run `sudo scripts/configure-pdm-firewall.sh` and `docker compose up -d`.

## Ceph mgr Prometheus target flips between "up" and "down"

**Cause**: only the currently-active Ceph mgr host is listed in
`config/prometheus/targets/ceph-mgr.json`. Mgr failover moves the active
mgr to a different host, and the old target stops responding.

**Fix**: list **every** mgr host in that target file, not just the
current active one (`ceph mgr module enable prometheus` is cluster-wide
and every mgr exposes the endpoint, but only the active one actually
serves useful data — Prometheus scraping all of them and getting
metrics-with-stale-data from standbys is expected and harmless). See
`scripts/node-setup/enable-ceph-prometheus.sh`'s printed guidance.

## shellcheck passes locally but a script still misbehaves after `source .env`

If a script both `cd`s to a computed path and later does
`set -a; source .env; set +a` on one line, shellcheck's
`# shellcheck disable=SC1091` directive can silently fail to suppress the
warning (a confirmed shellcheck quirk, not specific to this repo). If
you add a new script following this repo's pattern, keep `source .env` on
its own line with the disable comment directly above it, matching
`scripts/bootstrap-monitoring-vm.sh` — don't collapse it back onto one
line.
