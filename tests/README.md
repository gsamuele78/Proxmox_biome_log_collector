# Tests

This mirrors what CI runs (`.github/workflows/`). Run these locally before
opening a PR.

## Lint

```bash
# YAML style (compose files, config/**/*.yml)
yamllint -c tests/lint/.yamllint.yml .

# Dockerfiles
hadolint --config tests/lint/.hadolint.yaml docker/*/Dockerfile

# Shell scripts
shellcheck scripts/*.sh scripts/node-setup/*.sh

# Markdown
npx markdownlint-cli2 --config tests/lint/.markdownlint.yaml '**/*.md' '!docs/research/**'

# Secrets
gitleaks detect --source . --config .gitleaks.toml
```

## Config validation

```bash
# Compose file(s) parse and merge correctly
docker compose config --quiet
docker compose -f docker-compose.yml -f docker-compose.pegaprox.yml config --quiet

# Prometheus config + alert rules
docker run --rm -v "$PWD/config/prometheus:/config:ro" prom/prometheus:v3.13.2 \
  promtool check config /config/prometheus.yml
docker run --rm -v "$PWD/config/prometheus:/config:ro" prom/prometheus:v3.13.2 \
  promtool check rules /config/rules/*.yml

# Alertmanager config (render the template first — it uses envsubst, not
# native ${VAR} substitution, see config/alertmanager/alertmanager.yml.tmpl)
export $(grep -v '^#' .env | xargs) 2>/dev/null || true
envsubst < config/alertmanager/alertmanager.yml.tmpl > /tmp/alertmanager.yml
docker run --rm -v /tmp/alertmanager.yml:/config/alertmanager.yml:ro \
  prom/alertmanager:v0.33.1 amtool check-config /config/alertmanager.yml
```

## Integration smoke test

```bash
tests/integration/smoke-test.sh
```

Brings the core stack up with a throwaway `.env`, waits for container
healthchecks, curls a Traefik-routed path, checks Prometheus's own
`/api/v1/targets` reports registered scrape jobs, then tears everything
down. It does **not** test against real Proxmox/Ceph nodes — there are none
in CI — so PVE/Ceph-specific scrape targets and cv4pve API calls are outside
its scope. See `docs/deployment-guide.md` for how to validate those against
real hardware.

## What's verified vs. documented-only

Everything above runs in CI against the real container images. What it does
**not** cover: actual Proxmox VE/Ceph API behavior, real Let's Encrypt
issuance, Keycloak OIDC flows, or node-setup scripts (`scripts/node-setup/*.sh`,
`scripts/systemd/*`) — those require real Proxmox nodes and are documented,
not automated. See `docs/troubleshooting.md` if something documented doesn't
match what you observe on real hardware.
