#!/usr/bin/env bash
# Tier 3, monitoring VM as root: an OpenID realm on the native PDM.
# proxmox-datacenter-manager-admin has no realm commands (verified in the
# lab, PDM 1.x), so this goes through PDM's API, which is what the web UI's
# "Authentication Realms -> Add -> OpenID Connect" uses. Then a full login.
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
api=https://127.0.0.1:8443/api2/json
issuer=http://keycloak.biome.lab.test:8080/realms/lab
redirect=https://pdm.${DOMAIN}/
jar="$(mktemp)"

check_not "proxmox-datacenter-manager-admin has no 'realm' command (docs must not claim one)" \
  /usr/sbin/proxmox-datacenter-manager-admin realm --help
csrf="$(curl -sk -c "${jar}" "${api}/access/ticket" -d username=root@pam -d password=biome-lab-root \
  | jq -r '.data.CSRFPreventionToken // empty')"
check "root@pam API login (HttpOnly ticket cookie + CSRF token)" test -n "${csrf}"
pdm() { curl -sk -b "${jar}" -H "CSRFPreventionToken: ${csrf}" "$@"; }

pdm -X DELETE "${api}/config/access/openid/keycloak" >/dev/null
created="$(pdm -X POST "${api}/config/access/openid" -d realm=keycloak --data-urlencode "issuer-url=${issuer}" \
  -d client-id=proxmox-monitoring -d client-key=biome-lab-client-secret \
  -d username-claim=preferred_username -d autocreate=true)"
echo "${created}" > "${ARTIFACTS}/t3-pdm-realm-create.json"
check "POST /config/access/openid created realm 'keycloak'" \
  sh -c "curl -sk -b '${jar}' '${api}/config/access/openid' | jq -e '.data[] | select(.realm==\"keycloak\")'"
check "realm listed in /access/domains (login screen)" \
  sh -c "curl -sk '${api}/access/domains' | jq -e '.data[] | select(.realm==\"keycloak\" and .type==\"openid\")'"

auth_url="$(curl -sk -X POST "${api}/access/openid/auth-url" -d realm=keycloak \
  --data-urlencode "redirect-url=${redirect}" | jq -r '.data // empty')"
if [[ "${auth_url}" == "${issuer}/protocol/openid-connect/auth"* ]]; then
  pass "PDM resolved the issuer's discovery document (auth-url points at Keycloak)"
else
  fail "PDM auth-url: ${auth_url:-<none>}"
fi
callback="$(python3 "$(dirname "$0")/oidc-login.py" "${auth_url}" --stop-prefix "https://pdm.${DOMAIN}" 2>&1)"
qs() { python3 -c 'import sys,urllib.parse as u;print(u.parse_qs(u.urlparse(sys.argv[1]).query).get(sys.argv[2],[""])[0])' "$1" "$2"; }
code="$(qs "${callback}" code)" state="$(qs "${callback}" state)"
check "Keycloak redirected back to PDM with an authorization code" test -n "${code}"
login="$(curl -sk -X POST "${api}/access/openid/login" -d "code=${code}" -d "state=${state}" \
  --data-urlencode "redirect-url=${redirect}")"
echo "${login}" > "${ARTIFACTS}/t3-pdm-openid-login.json"
if [[ "$(jq -r '.data.username // empty' <<<"${login}")" == labuser@keycloak ]]; then
  pass "PDM issued a ticket for labuser@keycloak (autocreate)"
else
  fail "PDM openid login: $(head -c 300 <<<"${login}")"
fi
rm -f "${jar}"
summary
