#!/usr/bin/env bash
# Tiny assertion helpers for the lab e2e tests. Source it; call summary last.
# shellcheck disable=SC2034  # REPO/ARTIFACTS/DOMAIN are used by the sourcing scripts
PASS=0
FAIL=0
# vagrant ssh forwards the host's LC_* (e.g. it_IT) which the guests lack;
# Perl tools (pvesh, pveum) then print locale warnings into captured output.
export LC_ALL=C.UTF-8
REPO=/opt/proxmox-biome
ARTIFACTS=/var/lib/biome-lab/artifacts
DOMAIN=biome.lab.test

pass() { echo "PASS  $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $*"; FAIL=$((FAIL + 1)); }

# check "description" command...   — passes when the command exits 0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "${desc}"; else fail "${desc}"; fi
}

# check_not "description" command... — passes when the command FAILS
check_not() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "${desc}"; else pass "${desc}"; fi
}

# wait_for "description" timeout_seconds command...
wait_for() {
  local desc="$1" timeout="$2"; shift 2
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= end)); then fail "${desc} (timeout ${timeout}s)"; return 1; fi
    sleep 5
  done
  pass "${desc}"
}

# https_code host path [curl args...] — HTTP status via Traefik on this VM
https_code() {
  local host="$1" path="$2"; shift 2
  curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "${host}.${DOMAIN}:443:127.0.0.1" "$@" "https://${host}.${DOMAIN}${path}"
}

# expect_code "description" expected host path [curl args...]
expect_code() {
  local desc="$1" expected="$2"; shift 2
  local got
  got="$(https_code "$@" || true)"
  if [[ "${got}" == "${expected}" ]]; then pass "${desc}"; else fail "${desc} (got HTTP ${got}, want ${expected})"; fi
}

# prom_query 'promql' — prints the JSON result array
prom_query() {
  docker compose -f "${REPO}/docker-compose.yml" --project-directory "${REPO}" exec -T prometheus \
    wget -qO- "http://localhost:9090/api/v1/query?query=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")" \
    | jq -c '.data.result'
}

# prom_true 'promql' — succeeds when the query returns at least one series
prom_true() { [[ "$(prom_query "$1" | jq 'length')" -gt 0 ]]; }

# loki_has 'logql' — succeeds when Loki holds matching lines from the last hour
loki_has() {
  curl -sf --max-time 10 -G "http://10.77.10.10:3100/loki/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode "since=1h" --data-urlencode "limit=5" \
    | jq -e '.data.result | length > 0'
}

# all_healthy — every healthchecked core service reports healthy
all_healthy() {
  local s id
  for s in traefik prometheus alertmanager node-exporter loki grafana audit-report-server; do
    id="$(docker compose -f "${REPO}/docker-compose.yml" --project-directory "${REPO}" ps -q "${s}")"
    [[ -n "${id}" ]] || return 1
    [[ "$(docker inspect --format '{{.State.Health.Status}}' "${id}")" == healthy ]] || return 1
  done
}

basic_auth() { cat /var/lib/biome-lab/basic-auth; }

# mailpit_has 'text' — succeeds when the lab SMTP sink holds a matching mail
mailpit_has() {
  curl -sf --max-time 10 -G http://10.77.10.10:8025/api/v1/search --data-urlencode "query=$1" \
    | jq -e '.messages_count > 0'
}

# alert_firing 'AlertName' — succeeds while Prometheus reports it firing
alert_firing() { prom_true "ALERTS{alertname=\"$1\",alertstate=\"firing\"}"; }

summary() {
  echo "== ${0##*/}: ${PASS} passed, ${FAIL} failed"
  [[ "${FAIL}" -eq 0 ]]
}
