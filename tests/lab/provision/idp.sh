#!/usr/bin/env bash
# idp VM: Keycloak (dev mode, plain HTTP on the mgmt LAN) with the lab realm
# imported from tests/lab/keycloak/lab-realm.json. Stands in for the
# organisation's existing Keycloak that docs/keycloak-integration.md wires to.
set -euo pipefail
realm_dir=/opt/proxmox-biome/tests/lab/keycloak
if ! docker inspect lab-keycloak >/dev/null 2>&1; then
  docker run -d --name lab-keycloak --restart unless-stopped \
    -p 10.77.10.20:8080:8080 -p 10.77.10.20:9000:9000 \
    -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=biome-lab-admin \
    -e KC_HEALTH_ENABLED=true \
    -v "${realm_dir}:/opt/keycloak/data/import:ro" \
    quay.io/keycloak/keycloak:26.7.4 \
    start-dev --import-realm --http-port 8080 --hostname http://keycloak.biome.lab.test:8080 >/dev/null
fi
for _ in $(seq 60); do
  curl -sf http://10.77.10.20:9000/health/ready >/dev/null && break
  sleep 5
done
curl -sf http://keycloak.biome.lab.test:8080/realms/lab/.well-known/openid-configuration | jq -r .issuer
