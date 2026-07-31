#!/usr/bin/env bash
# CI/local integration smoke test for the core Docker Compose stack.
#
# Scope: proves the stack actually boots, containers reach a healthy state,
# Traefik routes to at least one backend, and Prometheus registers its own
# scrape targets. It does NOT test against real Proxmox VE/Ceph hardware —
# there is none available here — so cv4pve-metrics-exporter/cv4pve-diag's
# actual PVE API calls are out of scope (dummy credentials are used just to
# let the containers start). See tests/README.md.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

log() { echo "[smoke-test] $*"; }

cleanup() {
  log "Tearing down..."
  docker compose down -v --remove-orphans || true
  rm -f .env
}
trap cleanup EXIT

log "Writing throwaway .env with CI-safe dummy values..."
cp .env.example .env
cat >> .env <<'EOF'

# --- smoke-test overrides (throwaway, not real infra) ---
BASE_DOMAIN=smoketest.internal
ACME_EMAIL=smoketest@example.com
PVE_API_HOST=pve-smoketest.invalid
PVE_API_TOKEN_ID=smoketest@pve!smoketest
PVE_API_TOKEN_SECRET=00000000-0000-0000-0000-000000000000
CV4PVE_EXPORTER_HOSTS=pve-smoketest.invalid
CV4PVE_DIAG_HOSTS=pve-smoketest.invalid
ALERTMANAGER_SMTP_HOST=smtp.invalid:587
ALERTMANAGER_SMTP_FROM=alerts@smoketest.internal
ALERTMANAGER_SMTP_USER=smoketest
ALERTMANAGER_SMTP_PASSWORD=smoketest
ALERTMANAGER_RECEIVER_EMAIL=oncall@smoketest.internal
EOF

log "Generating secrets (passwords, htpasswd)..."
chmod +x scripts/generate-secrets.sh
scripts/generate-secrets.sh >/dev/null

log "Rendering alertmanager.yml from template..."
set -a
# shellcheck disable=SC1091
source .env
set +a
envsubst < config/alertmanager/alertmanager.yml.tmpl > config/alertmanager/alertmanager.yml

log "Seeding Prometheus file_sd targets from examples..."
for f in config/prometheus/targets/proxmox-nodes.json config/prometheus/targets/ceph-mgr.json; do
  [[ -f "${f}" ]] || cp "${f}.example" "${f}"
done

log "Validating compose config..."
docker compose config --quiet
docker compose -f docker-compose.yml -f docker-compose.pegaprox.yml config --quiet

log "Building custom images..."
docker compose build

log "Starting core stack..."
docker compose up -d

healthchecked_services=(traefik prometheus alertmanager node-exporter loki grafana audit-report-server)

log "Waiting for healthchecks (timeout 180s)..."
deadline=$((SECONDS + 180))
for service in "${healthchecked_services[@]}"; do
  container_id="$(docker compose ps -q "${service}")"
  if [[ -z "${container_id}" ]]; then
    echo "Service ${service} did not start" >&2
    docker compose logs "${service}" || true
    exit 1
  fi
  while true; do
    status="$(docker inspect --format '{{.State.Health.Status}}' "${container_id}")"
    if [[ "${status}" == "healthy" ]]; then
      log "${service}: healthy"
      break
    fi
    if [[ "${SECONDS}" -ge "${deadline}" ]]; then
      echo "${service} did not become healthy in time (last status: ${status})" >&2
      docker compose logs "${service}" || true
      exit 1
    fi
    sleep 3
  done
done

log "Checking cv4pve-metrics-exporter container is at least running (no healthcheck — distroless, see docker-compose.yml)..."
exporter_status="$(docker inspect --format '{{.State.Status}}' "$(docker compose ps -q cv4pve-metrics-exporter)")"
if [[ "${exporter_status}" != "running" ]]; then
  echo "cv4pve-metrics-exporter is not running (status: ${exporter_status})" >&2
  docker compose logs cv4pve-metrics-exporter || true
  exit 1
fi
log "cv4pve-metrics-exporter: running"

log "Curling Grafana through Traefik (self-signed fallback cert expected — ACME can't issue for a fake domain)..."
if ! curl -sk -o /dev/null -w '%{http_code}' --resolve "grafana.smoketest.internal:443:127.0.0.1" \
  "https://grafana.smoketest.internal/login" | grep -qE '^(200|302)$'; then
  echo "Grafana was not reachable through Traefik" >&2
  docker compose logs traefik grafana || true
  exit 1
fi
log "Traefik -> Grafana routing: OK"

log "Checking Prometheus has registered its own scrape target as up..."
targets_json="$(docker compose exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets)"
if ! echo "${targets_json}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
active = data["data"]["activeTargets"]
prom_self = [t for t in active if t["labels"].get("job") == "prometheus" and t["health"] == "up"]
sys.exit(0 if prom_self else 1)
'; then
  echo "Prometheus self-scrape target is not up" >&2
  echo "${targets_json}"
  exit 1
fi
log "Prometheus targets: OK"

log "All smoke test checks passed."
