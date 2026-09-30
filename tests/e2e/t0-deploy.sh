#!/usr/bin/env bash
# Tier 0, monitoring VM, as root: the documented deployment path
# (bootstrap-monitoring-vm.sh with tests/lab/lab.env), then checks that the
# deployed stack is healthy, authenticated and bound where it should be.
# Optional env: PVE_TOKEN_SECRET (real token from pve1, tier >= 1).
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
cd "${REPO}" || exit 1

# Fresh deployment config every run (volumes are kept).
docker compose down --remove-orphans >/dev/null 2>&1 || true
rm -f .env config/traefik/dynamic/.htpasswd config/alertmanager/alertmanager.yml config/prometheus/targets/*.json
cp tests/lab/lab.env .env
if [[ -n "${PVE_TOKEN_SECRET:-}" ]]; then
  sed -i "s/^PVE_API_TOKEN_SECRET=.*/PVE_API_TOKEN_SECRET=${PVE_TOKEN_SECRET}/" .env
fi

if scripts/bootstrap-monitoring-vm.sh > "${ARTIFACTS}/bootstrap.log" 2>&1; then
  pass "scripts/bootstrap-monitoring-vm.sh"
else
  fail "scripts/bootstrap-monitoring-vm.sh (see artifacts/bootstrap.log)"
  tail -40 "${ARTIFACTS}/bootstrap.log"
fi
password="$(sed -n 's/.*bootstrap admin password: //p' "${ARTIFACTS}/bootstrap.log" | tail -1)"
printf 'admin:%s' "${password}" > /var/lib/biome-lab/basic-auth
chmod 600 /var/lib/biome-lab/basic-auth

check "alertmanager.yml is root:65534 640" \
  test "$(stat -c '%U:%g %a' config/alertmanager/alertmanager.yml)" = "root:65534 640"
check ".htpasswd is root:root 600" \
  test "$(stat -c '%U:%G %a' config/traefik/dynamic/.htpasswd)" = "root:root 600"

wait_for "all healthchecked services healthy (incl. alertmanager reading its 640 config)" 240 all_healthy

expect_code "Prometheus via Traefik without credentials -> 401" 401 prometheus /-/healthy
expect_code "Prometheus via Traefik with basic auth -> 200 (Traefik reads the 600 .htpasswd)" 200 \
  prometheus /-/healthy -u "$(basic_auth)"
expect_code "Grafana via Traefik -> 200" 200 grafana /login
expect_code "audit reports via Traefik with basic auth -> 200" 200 audit / -u "$(basic_auth)"
http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  --resolve "grafana.${DOMAIN}:80:127.0.0.1" "http://grafana.${DOMAIN}/" || true)"
# Traefik v3's permanent redirect answers GET with 301 (308 for other methods).
if [[ "${http_code}" == 301 || "${http_code}" == 308 ]]; then pass "plain HTTP redirects to HTTPS (${http_code})"; else fail "HTTP :80 returned ${http_code}, want 301/308"; fi

loki_listen="$(ss -Hltn 'sport = :3100' | awk '{print $4}' | sort -u | tr '\n' ' ')"
if [[ "${loki_listen}" == "10.77.10.10:3100 " ]]; then
  pass "Loki published only on LOKI_BIND_ADDR (10.77.10.10:3100)"
else
  fail "Loki listening on: ${loki_listen:-nothing} (want only 10.77.10.10:3100)"
fi
check "Loki /ready answers on the management address" curl -sf --max-time 5 http://10.77.10.10:3100/ready

for job in prometheus monitoring-vm-node alertmanager loki grafana traefik; do
  wait_for "Prometheus target job=${job} is up" 120 prom_true "up{job=\"${job}\"} == 1"
done
# Alertmanager -> SMTP -> Mailpit, without waiting for a real rule: inject
# a synthetic alert straight into Alertmanager (group_wait is 30s).
curl -sf -X DELETE http://10.77.10.10:8025/api/v1/messages >/dev/null || true
# A unique label per run: an identical alert fired again within
# repeat_interval (1h for critical) is deduplicated, correctly, and a re-run
# on the same VM would wait for a mail that never comes. The group may also
# already exist, so allow for one group_interval (5m) flush.
docker compose exec -T alertmanager amtool alert add LabSyntheticAlert severity=critical \
  instance=lab run="$(date +%s)" 'summary="biome lab SMTP path"' --alertmanager.url=http://localhost:9093 >/dev/null
wait_for "Alertmanager delivered a mail to the SMTP sink (rendered smtp_* settings work)" 360 \
  mailpit_has LabSyntheticAlert

rules_loaded() {
  docker compose exec -T prometheus wget -qO- http://localhost:9090/api/v1/rules \
    | jq -e '[.data.groups[].name] | index("monitoring-stack") != null'
}
check "monitoring.rules.yml loaded (group monitoring-stack)" rules_loaded

# Loki push -> query round trip on the management address: the same API the
# nodes' Alloy agents use, so a broken ingest path fails here, not in tier 1.
probe="t0-probe-${RANDOM}${RANDOM}"
check "Loki accepts a push on LOKI_BIND_ADDR" curl -sf --max-time 10 -X POST \
  -H 'Content-Type: application/json' http://10.77.10.10:3100/loki/api/v1/push \
  --data "{\"streams\":[{\"stream\":{\"job\":\"t0-probe\"},\"values\":[[\"$(date +%s%N)\",\"${probe}\"]]}]}"
wait_for "pushed log line is queryable from Loki" 60 loki_has "{job=\"t0-probe\"} |= \"${probe}\""

# Grafana's provisioned datasources must actually reach Prometheus and Loki.
# The lab rewrites .env (new password) on every run while grafana-data keeps
# the admin user from the first run, so align the DB with .env first.
gf_user="$(sed -n 's/^GRAFANA_ADMIN_USER=//p' .env)"
gf_pass="$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' .env)"
docker compose exec -T grafana grafana cli admin reset-admin-password "${gf_pass}" >/dev/null 2>&1 || true
gf_api() {
  curl -sfk --max-time 15 --resolve "grafana.${DOMAIN}:443:127.0.0.1" \
    -u "${gf_user}:${gf_pass}" "https://grafana.${DOMAIN}$1"
}
datasource_ok() {
  local uid
  uid="$(gf_api "/api/datasources/name/$1" | jq -er .uid)" || return 1
  gf_api "/api/datasources/uid/${uid}/health" | jq -e '.status == "OK"'
}
check "Grafana admin login with the .env credentials" gf_api /api/user
wait_for "Grafana datasource Prometheus is healthy" 60 datasource_ok Prometheus
wait_for "Grafana datasource Loki is healthy" 60 datasource_ok Loki

summary
