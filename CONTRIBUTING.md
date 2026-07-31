# Contributing

This repo defines infrastructure (Docker Compose, service configs, node-provisioning
scripts) for a Proxmox VE + Ceph monitoring/audit/compliance stack. Changes should be
reviewable as diffs and validated by CI before merge — there is deliberately no
click-ops configuration (e.g. GUI-managed reverse proxy state) that CI can't see.

## Before you open a PR

1. Run the same checks CI runs, locally:

   ```bash
   make lint       # yamllint, shellcheck, markdownlint, hadolint
   make validate   # docker compose config, promtool, amtool
   make test       # tests/integration/smoke-test.sh
   ```

2. If you touch `docker-compose.yml` or anything under `config/`, re-read
   `docs/hardening.md` — new services must follow the same baseline (pinned image,
   dropped capabilities, resource limits, healthcheck, no unnecessary exposed ports).
3. If the change is an architectural decision (new component, replaced component,
   changed trust boundary), add an ADR under `docs/adr/` using `docs/adr/0000-template.md`.
   Don't silently change the architecture in a way future readers can't reconstruct.
4. Update `CHANGELOG.md` under `[Unreleased]`.
5. Never commit real secrets, IPs, or hostnames belonging to a real environment —
   `.env.example` and `config/prometheus/targets/*.json.example` are the pattern to
   follow; real values stay in the gitignored `.env` / `*.json` on the deployed host.

## Commit style

Small, logical commits. Prefer `type: summary` (`feat:`, `fix:`, `docs:`, `chore:`,
`ci:`, `security:`) — it's not enforced by tooling here, just a convention that keeps
`git log` scannable.

## Reporting a security issue

See [SECURITY.md](SECURITY.md) — do not open a public issue for vulnerabilities.
