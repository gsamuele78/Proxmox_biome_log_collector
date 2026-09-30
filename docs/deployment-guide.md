# Deployment guide

## VM sizing

| Resource | Starting point | Rationale |
| --- | --- | --- |
| vCPU | 4 | Prometheus + Grafana + Loki + Traefik are the steady-state load; cv4pve-diag runs briefly once a day. |
| RAM | 8 GB | Sized against `docker-compose.yml`'s `deploy.resources.limits` (roughly 3 GB summed across services) plus headroom for PDM and the host OS. |
| Disk | 60 GB | Prometheus retains 30 days (`--storage.tsdb.retention.time=30d`) — re-check actual usage after the first week on your real cluster (7-11 nodes) and grow the `prometheus-data` volume's backing disk if needed. |
| Network | One NIC on the same management VLAN as the Proxmox nodes | Needed for internal-LAN scrape/push/API traffic — see `docs/network-port-matrix.md`. |

This is a starting point, not a hard requirement — scale up if Prometheus's
own `prometheus_tsdb_*` metrics (visible in Grafana once running) show
memory or disk pressure as the cluster grows toward 11 nodes.

## 1. Provision the VM

Debian 13 (Trixie) is recommended — it's what PDM's official packaging
targets. Attach the VM to the same management network/VLAN as the Proxmox
cluster nodes, and give it a static IP and a DNS name that resolves to it
(used as `BASE_DOMAIN` in `.env`).

## 2. Install Docker Engine + Compose plugin

Use Docker's own apt repository, not the `docker.io` distro package (which
lags upstream and doesn't ship the Compose v2 plugin):

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

Verify: `docker compose version` should report Compose v2.19.1 or newer
(this repo's `scripts/bootstrap-monitoring-vm.sh` uses
`docker compose pull --ignore-buildable`, which requires that minimum).

## 3. Install Proxmox Datacenter Manager natively

```bash
# Repository keyring
sudo wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
  -O /usr/share/keyrings/proxmox-archive-keyring.gpg

# No-subscription repo (swap for the enterprise repo if you hold a
# subscription — see https://pdm.proxmox.com/docs/installation.html)
# One-line "deb ..." format belongs in a .list file; a .sources file must
# use the multi-line deb822 format, or apt refuses to parse it.
echo "deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] \
  http://download.proxmox.com/debian/pdm trixie pdm-no-subscription" | \
  sudo tee /etc/apt/sources.list.d/pdm.list > /dev/null

sudo apt-get update
sudo apt-get install -y proxmox-datacenter-manager-container-meta
```

**Immediately after install, run the firewall step below** — PDM's API
daemon has no configurable listen address (verified: it reuses Proxmox
Backup Server's proxy stack, which Proxmox staff have confirmed on the
official forum has no `LISTEN_IP` equivalent, unlike PVE's `pveproxy`). It
binds `0.0.0.0:8443` and stays that way; isolation is enforced entirely by
the host firewall, not by PDM itself. See ADR-0003 for the full reasoning.

```bash
sudo scripts/configure-pdm-firewall.sh
```

This installs an nftables rule restricting tcp/8443 to loopback and the
Docker `monitoring-edge` network's subnet (`172.28.0.0/24`, pinned in
`docker-compose.yml`) only. Verify it's active:

```bash
sudo nft list table inet proxmox_biome_pdm
```

Confirm PDM itself is *not* reachable from another host on the management
LAN (expect a timeout/connection refused, not a TLS handshake):

```bash
curl -k --max-time 3 https://<monitoring-vm-ip>:8443/  # from a DIFFERENT host
```

## 4. Clone this repo and configure

```bash
git clone https://github.com/gsamuele78/Proxmox_biome_log_collector.git /opt/proxmox-biome
cd /opt/proxmox-biome
cp .env.example .env
"${EDITOR:-vi}" .env   # fill in BASE_DOMAIN, PVE_API_TOKEN_*, CV4PVE_*_HOSTS, LOKI_BIND_ADDR, SMTP, etc.
sudo scripts/generate-secrets.sh
```

`generate-secrets.sh` fills in every `CHANGEME`/blank secret-type value in
`.env` (Grafana admin password, oauth2-proxy cookie secret) and writes
`config/traefik/dynamic/.htpasswd` from `TRAEFIK_BASIC_AUTH_USERS`. It's
idempotent — re-running it never overwrites a value you've already set.

## 5. Bootstrap the stack

```bash
sudo scripts/bootstrap-monitoring-vm.sh
```

Run it (and `generate-secrets.sh`) as root: the rendered
`alertmanager.yml` and `.htpasswd` are bind-mounted into containers that
run with every capability dropped, so the scripts chown them for the
container user (`root:65534 0640` / `root:root 0600`). Run as a
non-root docker-group user they fall back to world-readable `0644` and
print a warning.

This validates required `.env` vars, renders `config/alertmanager/alertmanager.yml`
from its `.tmpl` (Alertmanager doesn't support native `${VAR}` substitution),
seeds `config/prometheus/targets/*.json` from the `.example` files if they
don't exist yet, then `docker compose pull --ignore-buildable`, `build`,
and `up -d`. PegaProx is **not** started by this — it's opt-in (see
ADR-0005):

```bash
docker compose -f docker-compose.yml -f docker-compose.pegaprox.yml up -d
```

### 5a. Schedule the daily compliance scan

cv4pve-diag is a one-shot container run by a host systemd timer
(`scripts/systemd/cv4pve-diag.timer`, daily at 02:15 local time plus up to
5 minutes of jitter), which starts `scripts/systemd/cv4pve-diag.service`,
which runs `scripts/run-cv4pve-diag.sh` (it tries each `CV4PVE_DIAG_HOSTS`
entry in order). The unit expects the checkout at `/opt/proxmox-biome`;
edit `WorkingDirectory=` and `ExecStart=` if yours is elsewhere.

```bash
sudo cp scripts/systemd/cv4pve-diag.service scripts/systemd/cv4pve-diag.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start cv4pve-diag.service      # first report now; needs step 6's token to work
sudo systemctl enable --now cv4pve-diag.timer
systemctl list-timers cv4pve-diag.timer
```

Without this step no compliance report is ever produced.

## 6. Set up each Proxmox VE node

Run once per node (via your existing config-management tooling, or
manually — these scripts are idempotent either way):

```bash
scripts/node-setup/install-node-exporter.sh
LOKI_PUSH_URL="http://<monitoring-vm-ip>:3100/loki/api/v1/push" \
  scripts/node-setup/install-alloy-agent.sh
scripts/node-setup/configure-auditd.sh
```

`ceph mgr module enable prometheus` only needs running **once**, from any
node (it's cluster-wide, stored in the monitor map):

```bash
scripts/node-setup/enable-ceph-prometheus.sh
```

## 7. Point Prometheus at the real nodes

Edit the seeded target files (do **not** hand-edit `prometheus.yml` itself
— it reads these via file-based service discovery):

- `config/prometheus/targets/proxmox-nodes.json` — one entry per node
  (`:9100` for node_exporter).
- `config/prometheus/targets/ceph-mgr.json` — **every** mgr host, not just
  the currently-active one (mgr failover means Prometheus needs all of
  them listed to keep scraping `:9283` after a failover).

Prometheus picks up target-file changes automatically (`file_sd`, no
restart needed) — check `https://prometheus.${BASE_DOMAIN}/targets`.

## 8. Fetch community Grafana dashboards

```bash
scripts/fetch-community-dashboards.sh
```

Pulls Node Exporter Full (1860) and Ceph Cluster (2842) fresh from the
grafana.com API into `config/grafana/provisioning/dashboards/files/`
(gitignored — always fetched fresh, never committed). No official
dashboard exists for `cv4pve-metrics-exporter`, so this repo ships its own,
`Proxmox cluster and guests (cv4pve)`, from
`config/grafana/provisioning/dashboards/cv4pve/` (committed, provisioned
automatically, no fetch needed): cluster quorum, nodes, storage, and CPU,
memory, disk and network of every VM and LXC, plus the guests with no
backup job.

## 9. Validate

- Grafana (`https://grafana.${BASE_DOMAIN}/`) — dashboards populated with
  real node/Ceph data.
- Alertmanager (`https://alertmanager.${BASE_DOMAIN}/`): inject a test
  alert and confirm the mail reaches `ALERTMANAGER_RECEIVER_EMAIL` (after
  `group_wait`, 30s):
  `docker compose exec alertmanager amtool alert add DeployTest severity=warning --alertmanager.url=http://localhost:9093`
- `sudo systemctl start cv4pve-diag.service` generates a report (step 5a);
  check `https://audit.${BASE_DOMAIN}/latest.html`.
- `https://prometheus.${BASE_DOMAIN}/targets`: every job up.
- PDM (`https://pdm.${BASE_DOMAIN}/`) — reachable via Traefik; confirm (per
  step 3) it is **not** reachable on any other path.

## Updating custom-built images (cv4pve-diag, cv4pve-metrics-exporter)

Neither tool publishes an official container image (ADR-0007) — this repo
builds both from a pinned upstream `.deb` release, checksum-verified at
build time. To bump a version:

1. Find the new release on Corsinvest's GitHub (`Corsinvest/cv4pve-diag` /
   `Corsinvest/cv4pve-metrics-exporter`), download the `.deb` asset, and
   compute its checksum: `sha256sum cv4pve-*.deb`.
2. Update `ARG CV4PVE_VERSION` and `ARG CV4PVE_DEB_SHA256` at the top of
   the relevant `docker/*/Dockerfile`.
3. `docker compose build cv4pve-diag cv4pve-metrics-exporter && docker compose up -d`.

If the build fails at the `sha256sum -c` step, the checksum you copied
doesn't match the actual asset — don't skip the check; re-verify against
the release page rather than disabling it.

## TLS certificates

By default, Traefik requests a certificate from Let's Encrypt via the
`letsencrypt` ACME resolver (`config/traefik/traefik.yml`), which requires
`BASE_DOMAIN` to be a publicly-resolvable name reachable via HTTP-01 (port
80 open to the internet, which it is per the perimeter's 80/443/22 rule).

If `BASE_DOMAIN` is **not** publicly resolvable (e.g. an internal-only
name like the `.env.example` default), ACME cannot issue a certificate.
Use your internal CA instead:

1. Issue a certificate for `*.BASE_DOMAIN` (or one SAN per hostname:
   `grafana.`, `prometheus.`, `alertmanager.`, `audit.`, `pdm.`, `traefik.`)
   from your internal CA. Use the full chain in the certificate file.
2. Put them in `config/traefik/certs/` as `monitoring-vm.crt` and
   `monitoring-vm.key` (the directory is mounted read-only at `/certs` and
   gitignored), `chmod 600` the key.
3. Uncomment the three `certificates:` lines near the top of
   `config/traefik/dynamic/tls-options.yml`, keeping their indentation under
   `tls:`, then `docker compose restart traefik`.

Leave the `tls.certresolver=letsencrypt` router labels alone: with a
matching certificate in its store, Traefik serves it and makes no ACME
request. The lab phase `tests/e2e/t1-internal-ca.sh` checks exactly these
steps (certificate verified against the CA, no Let's Encrypt traffic).

See `docs/troubleshooting.md` if certificate issuance fails.
