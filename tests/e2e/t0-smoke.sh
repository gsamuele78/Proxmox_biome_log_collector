#!/usr/bin/env bash
# Tier 0, monitoring VM, as root: the CI smoke test on a real Docker daemon,
# plus generate-secrets.sh's root vs non-root file ownership.
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"

smoke=/opt/smoke
# The smoke test binds 80/443/3100 and the fixed monitoring-edge subnet, so
# the deployed stack (if a previous run left it up) must be stopped first.
if [[ -f "${REPO}/.env" ]]; then
  docker compose -f "${REPO}/docker-compose.yml" --project-directory "${REPO}" down --remove-orphans >/dev/null 2>&1 || true
fi

# A clean copy: smoke-test.sh refuses to run where a .env exists.
rm -rf "${smoke}"
rsync -a --exclude .env --exclude config/traefik/dynamic/.htpasswd \
  --exclude config/alertmanager/alertmanager.yml --exclude 'config/prometheus/targets/*.json' \
  "${REPO}/" "${smoke}/"

if (cd "${smoke}" && tests/integration/smoke-test.sh) > "${ARTIFACTS}/smoke-test.log" 2>&1; then
  pass "tests/integration/smoke-test.sh on a real Docker daemon"
else
  fail "tests/integration/smoke-test.sh (see artifacts/smoke-test.log)"
  tail -40 "${ARTIFACTS}/smoke-test.log"
fi
check "smoke test left no .env behind" test ! -e "${smoke}/.env"

# generate-secrets.sh file modes: 644 as a non-root docker user, 600 as root.
chown -R vagrant:vagrant "${smoke}"
cp "${smoke}/.env.example" "${smoke}/.env"
chown vagrant:vagrant "${smoke}/.env"
sudo -u vagrant "${smoke}/scripts/generate-secrets.sh" >/dev/null
check ".htpasswd is 644 when generated as non-root" \
  test "$(stat -c %a "${smoke}/config/traefik/dynamic/.htpasswd")" = 644
rm -f "${smoke}/config/traefik/dynamic/.htpasswd"
"${smoke}/scripts/generate-secrets.sh" >/dev/null
check ".htpasswd is root:root 600 when generated as root" \
  test "$(stat -c '%U:%G %a' "${smoke}/config/traefik/dynamic/.htpasswd")" = "root:root 600"
rm -rf "${smoke}"

summary
