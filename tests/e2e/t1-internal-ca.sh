#!/usr/bin/env bash
# Tier 1, monitoring VM as root, after t0-deploy.sh: the internal-CA TLS
# path of docs/deployment-guide.md ("TLS certificates") done exactly as
# documented: certificate and key in config/traefik/certs/, the three lines
# in config/traefik/dynamic/tls-options.yml uncommented. Traefik must then
# serve that certificate (verified against the CA) and stop asking Let's
# Encrypt. Restores the default (ACME) configuration afterwards.
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
cd "${REPO}" || exit 1

certs=config/traefik/certs
tls=config/traefik/dynamic/tls-options.yml
work="$(mktemp -d)"
cp "${tls}" "${work}/tls-options.yml.orig"

restore() {
  cp "${work}/tls-options.yml.orig" "${tls}"
  rm -f "${certs}/monitoring-vm.crt" "${certs}/monitoring-vm.key"
  docker compose restart traefik >/dev/null 2>&1
  rm -rf "${work}"
}
trap restore EXIT

# --- An internal CA and a wildcard certificate for the lab domain -----------
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=biome lab internal CA" \
  -keyout "${work}/ca.key" -out "${work}/ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=*.${DOMAIN}" \
  -keyout "${certs}/monitoring-vm.key" -out "${work}/mv.csr" 2>/dev/null
printf 'subjectAltName=DNS:*.%s,DNS:%s\n' "${DOMAIN}" "${DOMAIN}" > "${work}/san.ext"
openssl x509 -req -in "${work}/mv.csr" -CA "${work}/ca.crt" -CAkey "${work}/ca.key" \
  -CAcreateserial -days 2 -extfile "${work}/san.ext" -out "${certs}/monitoring-vm.crt" 2>/dev/null
chmod 600 "${certs}/monitoring-vm.key"
cp "${work}/ca.crt" "${ARTIFACTS}/internal-ca.crt"
check "certificate and key generated in ${certs}/" test -s "${certs}/monitoring-vm.crt"

# --- The documented edit: uncomment the three lines -------------------------
sed -i -E 's/^  # (certificates:|  - certFile:|    keyFile:)/  \1/' "${tls}"
check "tls-options.yml now has a tls.certificates entry" grep -q '^  certificates:' "${tls}"

since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker compose restart traefik >/dev/null 2>&1
traefik_healthy() {
  [[ "$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q traefik)")" == healthy ]]
}
wait_for "Traefik healthy with the internal certificate" 120 traefik_healthy

verified() {  # verified <host>: TLS verified against the internal CA only
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "${work}/ca.crt" \
    --resolve "$1.${DOMAIN}:443:127.0.0.1" "https://$1.${DOMAIN}/")" =~ ^(200|302|401)$ ]]
}
for host in grafana prometheus audit pdm; do
  wait_for "${host}.${DOMAIN} serves the internal certificate (verified with --cacert)" 60 verified "${host}"
done

# The routers keep `tls.certresolver=letsencrypt` in docker-compose.yml. With a
# matching certificate in the store, Traefik must not ask Let's Encrypt.
sleep 60
acme="$(docker compose logs --since "${since}" traefik 2>&1 | grep -c 'Obtaining bundled SAN certificate')"
if [[ "${acme}" -eq 0 ]]; then
  pass "no ACME request in 60s with the internal certificate (certresolver labels can stay)"
else
  fail "${acme} ACME requests despite the internal certificate: the certresolver labels must go"
fi

summary
