#!/usr/bin/env bash
# Tier 3, monitoring VM as root: docs/keycloak-integration.md step 4 for
# real. The keycloak profile starts oauth2-proxy; the lab overlay swaps the
# audit router to oauth2-proxy-auth (step 4.3). A scripted browser then logs
# in through Keycloak and must land on the reports.
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
cd "${REPO}" || exit 1
compose=(docker compose -f docker-compose.yml -f tests/lab/docker-compose.lab.yml --profile keycloak)

check "Keycloak discovery reachable from the monitoring VM" \
  curl -sf --max-time 10 http://keycloak.biome.lab.test:8080/realms/lab/.well-known/openid-configuration
check "OAUTH2_PROXY_COOKIE_SECRET was generated" grep -qE '^OAUTH2_PROXY_COOKIE_SECRET=.+' .env
if "${compose[@]}" up -d > "${ARTIFACTS}/t3-compose-up.log" 2>&1; then
  pass "docker compose --profile keycloak up -d (with lab overlay)"
else
  fail "compose up with keycloak profile"; tail -20 "${ARTIFACTS}/t3-compose-up.log"
fi
oauth_healthy() {
  [[ "$(docker inspect --format '{{.State.Health.Status}}' "$("${compose[@]}" ps -q oauth2-proxy)")" == healthy ]]
}
wait_for "oauth2-proxy healthy (alpine image healthcheck)" 120 oauth_healthy

redirects_to_keycloak() {
  local location
  location="$(curl -sk -o /dev/null -w '%{redirect_url}' -H 'Accept: text/html' --max-time 10 \
    --resolve "audit.${DOMAIN}:443:127.0.0.1" "https://audit.${DOMAIN}/")"
  [[ "${location}" == http://keycloak.${DOMAIN}:8080/realms/lab/protocol/openid-connect/auth* ]]
}
# The label change recreates audit-report-server; Traefik needs a moment to
# pick up the new router, during which it answers 404.
wait_for "unauthenticated request is redirected to Keycloak (forwardAuth -> static://202 root)" 60 \
  redirects_to_keycloak
check "the Keycloak redirect uses PKCE (code_challenge_method=S256)" sh -c \
  "curl -sk -o /dev/null -w '%{redirect_url}' -H 'Accept: text/html' --resolve audit.${DOMAIN}:443:127.0.0.1 https://audit.${DOMAIN}/ | grep -q code_challenge_method=S256"
expect_code "basic-auth credentials no longer open the audit site" 302 audit / -u "$(basic_auth)" -H 'Accept: text/html'

result="$(python3 "$(dirname "$0")/oidc-login.py" "https://audit.${DOMAIN}/" \
  --resolve "audit.${DOMAIN}=127.0.0.1" --body "${ARTIFACTS}/t3-audit-after-login.html" 2>&1)"
if [[ "${result}" == "200 https://audit.${DOMAIN}/" ]] && grep -q 'Index of' "${ARTIFACTS}/t3-audit-after-login.html"; then
  pass "Keycloak login -> /oauth2/callback -> back on the report index (200)"
else
  fail "login flow ended at: ${result}"
fi
expect_code "prometheus still on basic auth (only audit was migrated)" 200 prometheus /-/healthy -u "$(basic_auth)"

summary
