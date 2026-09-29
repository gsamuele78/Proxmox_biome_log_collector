.PHONY: up down logs lint validate test fetch-dashboards secrets bootstrap lab-up lab-test lab-destroy

## Bring the core stack up (does not include the pegaprox overlay).
up:
	docker compose up -d

## Tear the stack down, keeping named volumes.
down:
	docker compose down

logs:
	docker compose logs -f

## Full idempotent bootstrap: secrets, alertmanager render, pull, build, up.
bootstrap:
	scripts/bootstrap-monitoring-vm.sh

secrets:
	scripts/generate-secrets.sh

fetch-dashboards:
	scripts/fetch-community-dashboards.sh

## Everything tests/README.md documents for local lint.
lint:
	yamllint -c tests/lint/.yamllint.yml .
	hadolint --config tests/lint/.hadolint.yaml docker/cv4pve-diag/Dockerfile
	hadolint --config tests/lint/.hadolint.yaml docker/cv4pve-metrics-exporter/Dockerfile
	shellcheck -x scripts/*.sh scripts/node-setup/*.sh tests/integration/*.sh tests/e2e/*.sh tests/lab/*.sh tests/lab/provision/*.sh tests/lint/*.sh
	tests/lint/check-changelog.sh
	python3 tests/lint/check-drift.py
	npx markdownlint-cli2 --config tests/lint/.markdownlint.yaml '**/*.md' '!docs/research/**'

## Compose/Prometheus/Alertmanager config validation — see tests/README.md.
## Same checks as the compose-config, promtool and amtool CI jobs (the amtool
## render uses dummy SMTP values, like CI, not the local .env).
validate:
	docker compose config --quiet
	docker compose -f docker-compose.yml -f docker-compose.pegaprox.yml config --quiet
	docker run --rm --entrypoint promtool -v "$(CURDIR)/config/prometheus:/config:ro" \
	  prom/prometheus:v3.13.2 check config /config/prometheus.yml
	docker run --rm --entrypoint promtool -v "$(CURDIR)/config/prometheus:/config:ro" \
	  prom/prometheus:v3.13.2 check rules /config/rules/proxmox.rules.yml \
	  /config/rules/ceph.rules.yml /config/rules/monitoring.rules.yml
	ALERTMANAGER_SMTP_SMARTHOST=smtp.invalid:587 ALERTMANAGER_SMTP_FROM=a@smoketest.internal \
	  ALERTMANAGER_SMTP_USERNAME=x ALERTMANAGER_SMTP_PASSWORD=x ALERTMANAGER_SMTP_REQUIRE_TLS=true \
	  ALERTMANAGER_RECEIVER_EMAIL=b@smoketest.internal \
	  envsubst < config/alertmanager/alertmanager.yml.tmpl > /tmp/biome-alertmanager.yml
	docker run --rm --entrypoint amtool -v /tmp/biome-alertmanager.yml:/config/alertmanager.yml:ro \
	  prom/alertmanager:v0.33.1 check-config /config/alertmanager.yml

test:
	tests/integration/smoke-test.sh

## Local KVM/libvirt lab (tests/lab/README.md). TIER=0: monitoring VM only;
## TIER=1 (default): + a real PVE node; TIER=2: 3-node cluster + Ceph;
## TIER=3: + Keycloak (OIDC).
TIER ?= 1
lab-up:
	cd tests/lab && TIER=$(TIER) vagrant up --no-parallel

lab-test:
	TIER=$(TIER) tests/lab/run.sh

lab-destroy:
	cd tests/lab && TIER=3 vagrant destroy -f
