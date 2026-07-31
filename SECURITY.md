# Security Policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.
Instead, use GitHub's private [Security Advisories](../../security/advisories/new)
feature for this repository, or contact the maintainer directly. Include:

- Affected component/file and version (compose service, script, or config).
- Reproduction steps or a proof of concept.
- Impact assessment if known (e.g. credential exposure, privilege escalation,
  lateral movement into the monitoring VM or, worse, the Proxmox/Ceph cluster).

Expect an initial response within 5 business days.

## Scope

This repository ships **infrastructure configuration**, not application code:
Docker Compose definitions, Traefik/Prometheus/Loki/Grafana/Alertmanager configs,
and node-provisioning shell scripts. Vulnerabilities in the upstream container
images themselves (Traefik, Prometheus, Grafana, Loki, cv4pve-*, PDM, PegaProx)
should be reported to their respective upstream projects — this repo's CI runs
Trivy against pinned image tags and tracks known CVEs in `docs/hardening.md`,
but cannot fix upstream code.

## Baseline security posture (summary — full detail in `docs/hardening.md`)

- No component is reachable from outside the corporate perimeter except Traefik
  on 443 (and SSH on 22 to the host itself). Everything else — Grafana, Prometheus,
  Alertmanager, PDM, cv4pve-diag reports, PegaProx — sits behind Traefik or on a
  Docker-internal-only network.
- Authentication starts on local credentials (Traefik basic-auth, Grafana local
  admin) and is designed to migrate to Keycloak OIDC/MFA SSO — see
  `docs/keycloak-integration.md`. Local admin passwords must be rotated once
  Keycloak is live.
- Proxmox API access uses a dedicated, least-privilege API token
  (`PVEAuditor`-equivalent), never the `root@pam` password, per `.env.example`.
- All images are pinned (no `:latest` in `docker-compose.yml`), scanned by Trivy
  in CI, run with dropped capabilities, `no-new-privileges`, and — where the
  upstream image supports it — a read-only root filesystem and non-root user.
- Secrets never live in git: `.env` is gitignored, CI runs `gitleaks` on every
  push/PR to catch accidental commits.
- Node-level hardening (auditd rules, PVE firewall, Ceph network segregation)
  is documented in `docs/hardening.md` with the NIS2/CIS control it maps to —
  it is *documentation and scripts*, not something this repo can enforce on
  hosts it doesn't manage.

## Supported versions

This is an internal infrastructure repo tracked by tags in `CHANGELOG.md`; only
the latest tagged release is supported. There is no long-term-support branch.
