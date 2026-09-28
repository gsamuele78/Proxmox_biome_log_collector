#!/usr/bin/env bash
# Tier 2, monitoring VM as root: an alert rule fires and its mail reaches the
# SMTP sink, or (with "resolved") stops firing.
#   t2-alert.sh <AlertName> firing|resolved [timeout_seconds]
set -uo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
name="${1:?alert name}" want="${2:?firing|resolved}" timeout="${3:-600}"

if [[ "${want}" == firing ]]; then
  wait_for "${name} firing in Prometheus" "${timeout}" alert_firing "${name}"
  wait_for "${name} mail delivered via Alertmanager" 180 mailpit_has "${name}"
else
  not_firing() { ! alert_firing "${name}"; }
  wait_for "${name} no longer firing" "${timeout}" not_firing
fi
summary
