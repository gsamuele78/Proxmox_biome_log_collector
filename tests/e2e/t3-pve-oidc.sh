#!/usr/bin/env bash
# Tier 3, on pve1 as root: docs/keycloak-integration.md step 3 for real —
# add the OpenID realm with the documented pveum command, then complete a
# login: Keycloak form -> authorization code -> PVE ticket.
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
issuer=http://keycloak.biome.lab.test:8080/realms/lab
redirect=https://pve1.biome.lab.test:8006

pveum realm delete keycloak >/dev/null 2>&1 || true
# Exactly the command from docs/keycloak-integration.md step 3.
if pveum realm add keycloak --type openid --issuer-url "${issuer}" --client-id proxmox-monitoring \
  --client-key biome-lab-client-secret --username-claim preferred_username --autocreate 1; then
  pass "documented 'pveum realm add keycloak --type openid ...' works"
else
  fail "pveum realm add (documented flags)"
fi
auth_url="$(pvesh create /access/openid/auth-url --realm keycloak --redirect-url "${redirect}" \
  --output-format json 2>/dev/null | jq -r .)"
if [[ "${auth_url}" == "${issuer}/protocol/openid-connect/auth"* ]]; then
  pass "PVE resolved the issuer's discovery document (auth-url points at Keycloak)"
else
  fail "auth-url: ${auth_url:-<none>}"
fi

callback="$(python3 "$(dirname "$0")/oidc-login.py" "${auth_url}" --stop-prefix "${redirect}" 2>&1)"
code="$(python3 -c 'import sys,urllib.parse as u;q=u.parse_qs(u.urlparse(sys.argv[1]).query);print(q.get("code",[""])[0])' "${callback}")"
state="$(python3 -c 'import sys,urllib.parse as u;q=u.parse_qs(u.urlparse(sys.argv[1]).query);print(q.get("state",[""])[0])' "${callback}")"
check "Keycloak redirected back to PVE with an authorization code" test -n "${code}"
login="$(pvesh create /access/openid/login --code "${code}" --state "${state}" --redirect-url "${redirect}" \
  --output-format json 2>/dev/null)"
user="$(jq -r '.username // empty' <<<"${login}" 2>/dev/null)"
if [[ "${user}" == labuser@keycloak ]]; then
  pass "PVE issued a ticket for labuser@keycloak (autocreate)"
else
  fail "openid login: ${login}"
fi
check "user labuser@keycloak was autocreated" sh -c 'pveum user list --output-format json | jq -e ".[] | select(.userid==\"labuser@keycloak\")"'

summary
