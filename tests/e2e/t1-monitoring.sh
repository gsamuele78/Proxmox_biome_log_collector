#!/usr/bin/env bash
# Tier 1, monitoring VM as root, after t0-deploy.sh (with the real token)
# and t1-node.sh: scraping the real node, cv4pve against the real PVE API,
# logs arriving in Loki, the PDM firewall + route, the cv4pve-diag timer.
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
cd "${REPO}" || exit 1

# --- Prometheus -> real PVE node ---------------------------------------------
cat > config/prometheus/targets/proxmox-nodes.json <<'JSON'
[{"targets":["10.77.10.11:9100"],"labels":{"job":"proxmox-node-exporter","cluster":"biome-lab"}}]
JSON
wait_for "up{job=proxmox-node-exporter} == 1 for pve1 (file_sd reload)" 180 \
  prom_true 'up{job="proxmox-node-exporter",instance="10.77.10.11:9100"} == 1'

# --- cv4pve-metrics-exporter against the real API --------------------------
wait_for "up{job=cv4pve-metrics-exporter} == 1" 180 prom_true 'up{job="cv4pve-metrics-exporter"} == 1'
names="$(prom_query 'count by (__name__) ({__name__=~"cv4pve_.+"})' | jq -r '.[].metric.__name__' | sort)"
if [[ -n "${names}" ]]; then
  printf '%s\n' "${names}" > "${ARTIFACTS}/cv4pve-metric-names.txt"
  pass "cv4pve_* metrics present ($(wc -l <<<"${names}") names -> artifacts/cv4pve-metric-names.txt)"
  # One sample series per metric, with its labels: the input for
  # config/grafana/provisioning/dashboards/cv4pve/ and the guest alerts.
  prom_query 'topk by (__name__) (1, {__name__=~"cv4pve_.+"})' \
    | jq -r '.[].metric | tojson' | sort > "${ARTIFACTS}/cv4pve-metric-labels.jsonl"
else
  fail "no cv4pve_* metrics in Prometheus"
  docker compose logs --tail 30 cv4pve-metrics-exporter
fi

# --- The committed cv4pve dashboard against the real metrics -----------------
dash=config/grafana/provisioning/dashboards/cv4pve/cv4pve-overview.json
gf_user="$(sed -n 's/^GRAFANA_ADMIN_USER=//p' .env)"
gf_pass="$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' .env)"
dashboard_provisioned() {
  curl -sfk --max-time 15 --resolve "grafana.${DOMAIN}:443:127.0.0.1" -u "${gf_user}:${gf_pass}" \
    "https://grafana.${DOMAIN}/api/dashboards/uid/cv4pve-overview" | jq -e '.dashboard.panels | length > 0'
}
wait_for "Grafana provisioned the cv4pve-overview dashboard" 120 dashboard_provisioned
# Every panel query must be valid PromQL; the guest queries must return data.
bad=0 empty=0 total=0
while IFS= read -r expr; do
  total=$((total + 1))
  expr="${expr//\$node/.*}"
  resp="$(docker compose exec -T prometheus wget -qO- \
    "http://localhost:9090/api/v1/query?query=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "${expr}")" </dev/null)"
  if [[ "$(jq -r .status <<<"${resp}")" != success ]]; then
    bad=$((bad + 1)); echo "  invalid: ${expr}"
  elif [[ "$(jq '.data.result | length' <<<"${resp}")" -eq 0 ]]; then
    empty=$((empty + 1)); echo "  no data (yet): ${expr}"
  fi
done < <(jq -r '.panels[].targets[]?.expr' "${dash}")
if ((bad == 0)); then pass "all ${total} dashboard queries are valid PromQL (${empty} without data yet)"; else fail "${bad}/${total} dashboard queries rejected by Prometheus"; fi
guest_rows="cv4pve_guest_uptime_seconds * on(id) group_left(name, node, type, vmid) cv4pve_guest_info"
check "guest table query returns the lab LXC (metrics joined with cv4pve_guest_info)" prom_true "${guest_rows}"

# --- Logs from pve1 in Loki ---------------------------------------------------
wait_for "Loki has {job=\"auditd\",host=\"pve1\"}" 180 loki_has '{job="auditd",host="pve1"}'
wait_for "Loki has {job=\"systemd-journal\",host=\"pve1\"}" 180 loki_has '{job="systemd-journal",host="pve1"}'
wait_for "Loki has the journal marker line" 120 loki_has '{job="systemd-journal",host="pve1"} |= "journal marker for the e2e test"'

# --- PDM: firewall script, then route through Traefik ------------------------
if scripts/configure-pdm-firewall.sh > "${ARTIFACTS}/configure-pdm-firewall.log" 2>&1; then
  pass "scripts/configure-pdm-firewall.sh"
else
  fail "scripts/configure-pdm-firewall.sh"; tail -20 "${ARTIFACTS}/configure-pdm-firewall.log"
fi
check "nft table inet proxmox_biome_pdm loaded" nft list table inet proxmox_biome_pdm
nft_conf_kept() {
  local orig=/var/lib/biome-lab/nftables.conf.orig
  [[ "$(head -c "$(stat -c %s "${orig}")" /etc/nftables.conf)" == "$(cat "${orig}")" ]] \
    && [[ "$(grep -c 'nftables.d/\*.nft' /etc/nftables.conf)" == 1 ]]
}
check "/etc/nftables.conf kept its original content + exactly one include line" nft_conf_kept
check "configure-pdm-firewall.sh is idempotent (2nd run)" scripts/configure-pdm-firewall.sh
check "include line still present exactly once after 2nd run" nft_conf_kept
check "PDM table holds exactly 3 rules after 2nd run (no duplicates)" \
  test "$(nft list chain inet proxmox_biome_pdm input | grep -c 'dport 8443')" = 3
docker_nat_ok() {
  docker run --rm --network monitoring-backend curlimages/curl:8.11.1 \
    -sk -o /dev/null --max-time 5 https://10.77.10.11:8006/
}
check "containers still reach the PVE API after the firewall script (Docker rules intact)" docker_nat_ok
check "PDM answers on loopback :8443" curl -sk -o /dev/null --max-time 5 https://127.0.0.1:8443/
expect_code "PDM via Traefik (pdm.yml Go-template rule) with basic auth -> 200" 200 pdm / -u "$(basic_auth)"
expect_code "PDM via Traefik without credentials -> 401" 401 pdm /

# --- cv4pve-diag via the systemd units ----------------------------------------
cp scripts/systemd/cv4pve-diag.service scripts/systemd/cv4pve-diag.timer /etc/systemd/system/
systemctl daemon-reload
if systemctl start cv4pve-diag.service; then
  pass "systemctl start cv4pve-diag.service (oneshot scan against pve1)"
else
  fail "cv4pve-diag.service failed"; journalctl -u cv4pve-diag.service -n 40 --no-pager
fi
journalctl -u cv4pve-diag.service -n 200 --no-pager > "${ARTIFACTS}/cv4pve-diag.journal.log"
check "cv4pve-diag.timer enables" systemctl enable --now cv4pve-diag.timer
report="$(curl -sk --max-time 10 --resolve "audit.${DOMAIN}:443:127.0.0.1" -u "$(basic_auth)" \
  "https://audit.${DOMAIN}/" | grep -o 'cv4pve-diag-[0-9TZ]*\.html' | sort | tail -1)"
if [[ -n "${report}" ]]; then
  pass "timestamped report listed by audit-report-server (${report})"
  expect_code "report ${report} is served" 200 audit "/${report}" -u "$(basic_auth)"
  curl -sk --resolve "audit.${DOMAIN}:443:127.0.0.1" -u "$(basic_auth)" \
    "https://audit.${DOMAIN}/${report}" -o "${ARTIFACTS}/${report}"
else
  fail "no cv4pve-diag-*.html in the audit-report-server listing"
fi

summary
