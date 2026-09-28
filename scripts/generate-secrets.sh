#!/usr/bin/env bash
# Generates random values for the secret-type variables in .env that don't
# require a human decision (passwords, cookie secrets) — NOT the ones that
# need real infrastructure info (PVE_API_TOKEN_*, KEYCLOAK_*, SMTP_*), which
# you must fill in yourself. Idempotent: only fills placeholders that still
# contain "CHANGEME", never overwrites a value you've already set.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${repo_root}/.env"
env_example="${repo_root}/.env.example"

if [[ ! -f "${env_file}" ]]; then
  echo "No .env found — creating from .env.example" >&2
  cp "${env_example}" "${env_file}"
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}
require_cmd python3
require_cmd htpasswd

random_b64() {
  python3 -c 'import secrets, base64; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())'
}

set_if_changeme() {
  local key="$1" value="$2"
  if grep -qE "^${key}=(.*CHANGEME.*)?$" "${env_file}"; then
    # Escape sed metacharacters that can plausibly appear in generated values.
    local escaped
    escaped=$(printf '%s' "${value}" | sed -e 's/[\/&]/\\&/g')
    sed -i "s/^${key}=.*/${key}=${escaped}/" "${env_file}"
    echo "Set ${key}"
  else
    echo "Skipped ${key} (already set)"
  fi
}

set_if_changeme "GRAFANA_ADMIN_PASSWORD" "$(random_b64)"
set_if_changeme "OAUTH2_PROXY_COOKIE_SECRET" "$(random_b64)"

if grep -qE '^TRAEFIK_BASIC_AUTH_USERS=.*CHANGEME' "${env_file}"; then
  bootstrap_password="$(random_b64)"
  htpasswd_line="$(htpasswd -nbB admin "${bootstrap_password}")"
  # docker-compose environment interpolation needs every literal '$' doubled.
  htpasswd_escaped="${htpasswd_line//\$/\$\$}"
  escaped=$(printf '%s' "${htpasswd_escaped}" | sed -e 's/[\/&]/\\&/g')
  sed -i "s/^TRAEFIK_BASIC_AUTH_USERS=.*/TRAEFIK_BASIC_AUTH_USERS=${escaped}/" "${env_file}"
  echo "Set TRAEFIK_BASIC_AUTH_USERS — bootstrap admin password: ${bootstrap_password}"
  echo "Save this password now; it is not stored anywhere else in plaintext."
else
  echo "Skipped TRAEFIK_BASIC_AUTH_USERS (already set)"
fi

# Traefik's basicAuth middleware reads a real htpasswd file, not the .env
# string form (see config/traefik/dynamic/middlewares.yml) — keep both in
# sync from the single .env source of truth.
htpasswd_users="$(grep -E '^TRAEFIK_BASIC_AUTH_USERS=' "${env_file}" | cut -d= -f2- | sed 's/\$\$/\$/g')"
htpasswd_file="${repo_root}/config/traefik/dynamic/.htpasswd"
(umask 077 && printf '%s\n' "${htpasswd_users}" > "${htpasswd_file}")
# Traefik runs as uid 0 inside its container but with every capability
# dropped (no CAP_DAC_OVERRIDE), so it can read a 600 file only if the file
# is owned by uid 0 on the host too.
if [[ "${EUID}" -eq 0 ]]; then
  chown root:root "${htpasswd_file}"
  chmod 600 "${htpasswd_file}"
else
  chmod 644 "${htpasswd_file}"
  echo "Note: not running as root, so .htpasswd is 644 (bcrypt hashes only) so Traefik can read it; re-run as root for 600."
fi
echo "Wrote config/traefik/dynamic/.htpasswd"

cat <<'EOF'

Still need to be filled in manually (real infra values, not generatable):
  PVE_API_TOKEN_ID, PVE_API_TOKEN_SECRET
  CV4PVE_DIAG_HOSTS, CV4PVE_EXPORTER_HOSTS
  ALERTMANAGER_SMTP_* / ALERTMANAGER_RECEIVER_EMAIL
  KEYCLOAK_* (Phase 2 only — leave blank until your realm/client exist)
See docs/deployment-guide.md.
EOF
