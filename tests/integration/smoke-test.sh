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

# This test writes a throwaway .env, regenerates the htpasswd file and the
# rendered alertmanager.yml, and ends with `docker compose down -v`. Run in a
# checkout that holds a real deployment it would overwrite those files and
# DELETE the stack's volumes (Prometheus/Loki/Grafana data). Refuse instead.
if [[ -f .env ]]; then
  echo "Refusing to run: ${repo_root}/.env exists (looks like a real deployment)." >&2
  echo "Run the smoke test from a separate, clean checkout." >&2
  exit 1
fi

generated_files=(
  .env
  config/traefik/dynamic/.htpasswd
  config/alertmanager/alertmanager.yml
  config/prometheus/targets/proxmox-nodes.json
  config/prometheus/targets/ceph-mgr.json
)
preexisting=()
for f in "${generated_files[@]}"; do
  [[ -e "${f}" ]] && preexisting+=("${f}")
done

cleanup() {
  log "Tearing down..."
  docker compose down -v --remove-orphans || true
  # Remove only the files this run created; leave anything that was there.
  for f in "${generated_files[@]}"; do
    if [[ " ${preexisting[*]} " != *" ${f} "* ]]; then
      rm -f "${f}"
    fi
  done
}
trap cleanup EXIT

log "Writing throwaway .env with CI-safe dummy values..."
cp .env.example .env
cat >> .env <<'EOF'

# --- smoke-test overrides (throwaway, not real infra) ---
BASE_DOMAIN=smoketest.internal
ACME_EMAIL=smoketest@example.com
PVE_API_TOKEN_ID=smoketest@pve!smoketest
PVE_API_TOKEN_SECRET=00000000-0000-0000-0000-000000000000
CV4PVE_EXPORTER_HOSTS=pve-smoketest.invalid
CV4PVE_DIAG_HOSTS=pve-smoketest.invalid
ALERTMANAGER_SMTP_SMARTHOST=smtp.invalid:587
ALERTMANAGER_SMTP_FROM=alerts@smoketest.internal
ALERTMANAGER_SMTP_USERNAME=smoketest
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

log "Building custom images (incl. the tools-profile cv4pve-diag)..."
docker compose --profile tools build

log "Checking the distroless cv4pve-diag binary starts..."
docker compose run --rm --no-deps cv4pve-diag --help >/dev/null

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

log "Checking cv4pve-metrics-exporter starts and uses its arguments (no healthcheck — distroless, see docker-compose.yml)..."
# There is no PVE here, so the exporter exits on "No reachable hosts" and
# Docker restarts it: its state flips between running and restarting, and
# checking it was flaky. What this can prove is that the binary starts and
# tries the host it was given; the real API path is lab tier 1.
exporter_ok() {
  docker compose logs cv4pve-metrics-exporter 2>&1 | grep -q "pve-smoketest.invalid"
}
deadline=$((SECONDS + 60))
until exporter_ok; do
  if [[ "${SECONDS}" -ge "${deadline}" ]]; then
    echo "cv4pve-metrics-exporter never tried CV4PVE_EXPORTER_HOSTS (binary or arguments broken)" >&2
    docker compose logs cv4pve-metrics-exporter || true
    exit 1
  fi
  sleep 3
done
log "cv4pve-metrics-exporter: started, tried pve-smoketest.invalid"

log "Curling Grafana through Traefik (self-signed fallback cert expected — ACME can't issue for a fake domain)..."
if ! curl -sk -o /dev/null -w '%{http_code}' --resolve "grafana.smoketest.internal:443:127.0.0.1" \
  "https://grafana.smoketest.internal/login" | grep -qE '^(200|302)$'; then
  echo "Grafana was not reachable through Traefik" >&2
  docker compose logs traefik grafana || true
  exit 1
fi
log "Traefik -> Grafana routing: OK"

log "Checking Loki's log-ingest port is published on the host (Alloy push path)..."
if ! curl -sf -o /dev/null "http://127.0.0.1:3100/ready"; then
  echo "Loki is not reachable on host port 3100 — PVE nodes could not push logs" >&2
  docker compose logs loki || true
  exit 1
fi
log "Loki host port 3100: OK"

# Every in-stack scrape job must be up. PVE/Ceph jobs are excluded — their
# targets are the .example placeholders, unreachable by design here.
expected_jobs="prometheus monitoring-vm-node alertmanager loki grafana traefik"
log "Waiting for Prometheus self-monitoring targets (${expected_jobs}) to be up (timeout 120s)..."
deadline=$((SECONDS + 120))
while true; do
  targets_json="$(docker compose exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets)"
  if missing="$(echo "${targets_json}" | EXPECTED_JOBS="${expected_jobs}" python3 -c '
import json, os, sys
active = json.load(sys.stdin)["data"]["activeTargets"]
up = {t["labels"].get("job") for t in active if t["health"] == "up"}
missing = [j for j in os.environ["EXPECTED_JOBS"].split() if j not in up]
print(" ".join(missing))
sys.exit(1 if missing else 0)
')"; then
    break
  fi
  if [[ "${SECONDS}" -ge "${deadline}" ]]; then
    echo "Prometheus targets not up: ${missing}" >&2
    echo "${targets_json}"
    exit 1
  fi
  sleep 5
done
log "Prometheus targets: OK"

log "All smoke test checks passed."
