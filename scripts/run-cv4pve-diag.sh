#!/usr/bin/env bash
# Runs a scheduled cv4pve-diag NIS2 compliance scan and writes a timestamped
# report into the cv4pve-diag-reports volume (served read-only by
# audit-report-server, routed via Traefik at audit.${BASE_DOMAIN}). Invoked
# by scripts/systemd/cv4pve-diag.timer -> cv4pve-diag.service on the
# monitoring VM host — not run inside the container's own scheduler, since
# the final image is distroless (no cron/shell to schedule with itself).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

if [[ ! -f .env ]]; then
  echo "No .env found — run scripts/bootstrap-monitoring-vm.sh first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
report_file="/reports/cv4pve-diag-${timestamp}.html"

echo "[cv4pve-diag] Running compliance scan -> ${report_file}"
# Root-level options first, then the `execute` subcommand (upstream's
# documented argument order).
docker compose run --rm --no-deps cv4pve-diag \
  --host="${CV4PVE_DIAG_HOSTS:?Set CV4PVE_DIAG_HOSTS in .env}" \
  --api-token="${PVE_API_TOKEN_ID:?Set PVE_API_TOKEN_ID in .env}=${PVE_API_TOKEN_SECRET:?Set PVE_API_TOKEN_SECRET in .env}" \
  --compliance=Nis2 \
  --output=Html \
  --output-file="${report_file}" \
  execute

echo "[cv4pve-diag] Report written. Available at https://audit.${BASE_DOMAIN}/$(basename "${report_file}")"
