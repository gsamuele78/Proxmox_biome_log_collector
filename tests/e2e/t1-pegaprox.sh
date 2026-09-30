#!/usr/bin/env bash
# Tier 1, monitoring VM as root, after t0-deploy.sh: the opt-in PegaProx
# overlay (ADR-0008) for real. It must come up healthy with the image's own
# volumes, answer through Traefik behind basic auth, and keep its config
# across a recreate. Leaves the overlay stopped (volumes kept).
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
cd "${REPO}" || exit 1

overlay=(docker compose -f docker-compose.yml -f docker-compose.pegaprox.yml)

if "${overlay[@]}" up -d pegaprox > "${ARTIFACTS}/pegaprox-up.log" 2>&1; then
  pass "pegaprox overlay up"
else
  fail "pegaprox overlay up (see artifacts/pegaprox-up.log)"; tail -20 "${ARTIFACTS}/pegaprox-up.log"
fi

pegaprox_healthy() {
  [[ "$(docker inspect --format '{{.State.Health.Status}}' "$("${overlay[@]}" ps -q pegaprox)")" == healthy ]]
}
wait_for "pegaprox container healthy (python healthcheck on /api/health)" 300 pegaprox_healthy \
  || "${overlay[@]}" logs --tail 40 pegaprox

mounts="$(docker inspect --format '{{range .Mounts}}{{.Destination}}={{.Name}} {{end}}' "$("${overlay[@]}" ps -q pegaprox)")"
if [[ "${mounts}" == *"/app/config="*pegaprox-config* && "${mounts}" == *"/app/logs="*pegaprox-logs* ]]; then
  pass "/app/config and /app/logs are the named volumes"
else
  fail "pegaprox mounts: ${mounts}"
fi

# Traefik adds a container's router only once it is healthy, so wait.
code_is() { [[ "$(https_code pegaprox /api/health "${@:2}")" == "$1" ]]; }
wait_for "PegaProx via Traefik without credentials -> 401" 60 code_is 401
wait_for "PegaProx /api/health via Traefik with basic auth -> 200 (plain HTTP backend, not 502)" 60 \
  code_is 200 -u "$(basic_auth)"

config_files() { "${overlay[@]}" exec -T pegaprox sh -c 'ls -A /app/config' 2>/dev/null | sort; }
before="$(config_files)"
check "PegaProx wrote its config into /app/config" test -n "${before}"
"${overlay[@]}" up -d --force-recreate pegaprox >/dev/null 2>&1
wait_for "pegaprox healthy again after recreate" 300 pegaprox_healthy
after="$(config_files)"
if [[ -n "${before}" && "$(comm -23 <(echo "${before}") <(echo "${after}"))" == "" ]]; then
  pass "config survived the recreate (${before//$'\n'/ })"
else
  fail "config lost on recreate: before [${before//$'\n'/ }] after [${after//$'\n'/ }]"
fi

"${overlay[@]}" logs --no-color pegaprox > "${ARTIFACTS}/pegaprox.log" 2>&1
"${overlay[@]}" rm -sf pegaprox >/dev/null 2>&1
check "overlay stopped again, core stack untouched" all_healthy

summary
