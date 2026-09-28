# Incident response runbook

This ties the stack's alerting into NIS2's incident-notification timeline.
It assumes an operational SOC/on-call process already exists — this
document covers what this repo's tooling gives that process to work with,
not the process itself.

## Alert → triage → escalate

1. **Alert fires** — Prometheus evaluates `config/prometheus/rules/*.yml`
   against scraped metrics, fires through Alertmanager
   (`config/alertmanager/alertmanager.yml.tmpl`), which routes to
   `ALERTMANAGER_RECEIVER_EMAIL` and/or `ALERTMANAGER_WEBHOOK_URL`
   (`.env`) — point the webhook at your SOC/SIEM ingest or a Slack/Teams
   connector.
2. **Triage** — the on-call responder opens Grafana
   (`https://grafana.${BASE_DOMAIN}/`) to correlate the firing alert with
   metrics (Prometheus datasource) and logs (Loki datasource, populated by
   Alloy from every node including `auditd` output). The alert's own
   labels (`job`, `instance`, `severity`) narrow which node/service to
   look at first.
3. **Classify severity** — use the alert's own `severity` label
   (`critical`/`warning`, set per-rule in
   `config/prometheus/rules/proxmox.rules.yml` /
   `ceph.rules.yml`) as the starting point, adjusted by the responder's
   own assessment of actual impact (a single-node `node_exporter` scrape
   failure is not the same severity as a Ceph `HEALTH_ERR` with degraded
   PGs, even if both fire as "critical" at the rule level).
4. **Contain / remediate** — cluster-level remediation (Ceph OSD
   recovery, PVE node investigation) happens on the Proxmox cluster
   itself, using PDM (`https://pdm.${BASE_DOMAIN}/`) or direct node
   access — this monitoring VM observes and alerts, it doesn't act on the
   cluster.
5. **Compliance evidence** — `cv4pve-diag`'s reports
   (`https://audit.${BASE_DOMAIN}/`) and Loki's retained audit
   logs are the evidentiary record referenced in the notification below.

## NIS2 notification timeline

For incidents that qualify as "significant" under NIS2 Article 23, the
regulation sets three deadlines to the competent authority/CSIRT — this
stack's tooling maps to each as follows:

| Deadline | What's required | What this repo's tooling gives you |
| --- | --- | --- |
| 24 hours — early warning | Initial notification, whether the incident is suspected to be unlawful/malicious, possible cross-border effect | Alertmanager's first-fired timestamp and the Grafana/Loki view assembled during triage (step 2-3 above) is the starting evidence for this notification — the alert itself is not the notification, a human still files it. |
| 72 hours — incident notification | Updated assessment, initial severity/impact, indicators of compromise if available | `auditd` logs shipped via Alloy (privileged config-file changes, auth events) and cv4pve-diag's most recent compliance report give the "what changed, what does the environment's compliance posture look like" context for this update. |
| 1 month — final report | Detailed description, root cause, mitigation applied | Prometheus's 30-day retention (`--storage.tsdb.retention.time=30d`) and Loki's retention (`config/loki/loki-config.yaml`) need to comfortably cover the incident window — verify retention settings are sufficient for your actual incident timeline before relying on this for a final report; extend `prometheus-data`'s retention if a slow-burn incident risks rolling past 30 days before it's fully closed out. |

This repo does not automate any of these notifications — NIS2 requires a
human-authored notification to a specific competent authority per member
state, which is out of scope for a monitoring stack. What's captured here
is the technical evidence trail (metrics, logs, compliance reports) that
notification is written from.

## Where things live

- **Alert rules**: `config/prometheus/rules/proxmox.rules.yml`,
  `config/prometheus/rules/ceph.rules.yml`.
- **Alert routing**: `config/alertmanager/alertmanager.yml.tmpl`.
- **Audit trail**: Loki, fed by Alloy from `auditd` on each node
  (`scripts/node-setup/configure-auditd.sh`).
- **Compliance snapshots**: `cv4pve-diag` reports, daily
  (`scripts/systemd/cv4pve-diag.timer`), retained in the
  `cv4pve-diag-reports` Docker volume and served at
  `https://audit.${BASE_DOMAIN}/`.
