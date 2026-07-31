# ADR-0004: Grafana Alloy for node log shipping, not Promtail

Status: Accepted
Date: 2026-07-31

## Context

The original chat-transcript research
(`docs/research/original-chat-transcript.md`) proposed Promtail as the
per-node log-shipping agent pushing into Loki. Grafana Labs has deprecated
Promtail, with end-of-life in March 2026 — it receives no further feature
work and only a limited maintenance/security-fix window beyond that.
Building a new, 2026-dated production repo on a component already past its
support horizon is not a defensible default.

## Decision

Use **Grafana Alloy** (River-syntax config,
`config/alloy/config.alloy.tmpl`) as the node-side agent instead of
Promtail, for both systemd journal shipping and file-based log shipping
(PVE firewall log, auditd log).

## Consequences

- Config is River syntax (`loki.write`, `loki.relabel`,
  `loki.source.journal`, `local.file_match`, `loki.source.file`
  components), not Promtail's YAML scrape-config format — a different
  mental model to document (`docs/deployment-guide.md`,
  `docs/troubleshooting.md`), but one with a real future rather than a
  sunsetting one.
- Alloy is a single agent binary that also supports metrics/traces
  pipelines, not just logs — leaves room to consolidate more of the
  node-side collection story onto it later (see `docs/roadmap.md`) without
  introducing yet another agent.
- `scripts/node-setup/install-alloy-agent.sh` renders the `.tmpl` file by
  substituting `__LOKI_PUSH_URL__` (Alloy's config file has no native
  `${VAR}` templating any more than Traefik's or Alertmanager's do — see
  ADR-0007's sibling reasoning applied here too), rather than shipping a
  static config with a hardcoded Loki hostname.

## Alternatives considered

- **Promtail** — rejected: EOL March 2026, would be shipping a
  soon-unsupported component in a repo dated 2026.
- **Vector** — a credible general-purpose alternative; not chosen because
  Alloy is Grafana's own first-party, LGTM-stack-native agent with direct
  Loki/Prometheus component support, keeping one vendor's tooling
  consistent end-to-end rather than mixing agent ecosystems.
- **rsyslog/syslog-ng forwarding directly to Loki** — rejected: Loki's
  native ingestion path (and this stack's label/relabel strategy for
  `unit`/`level`/`host`) is built around an agent that understands Loki's
  push API and relabeling model, which plain syslog forwarding doesn't
  give you without extra glue.
