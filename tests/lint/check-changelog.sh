#!/usr/bin/env bash
# CHANGELOG.md structure check (CI lint job, `make lint`):
#   - an "## [Unreleased]" section exists and comes first;
#   - release headings are "## [X.Y.Z] - YYYY-MM-DD", newest first;
#   - every vX.Y.Z git tag has its section (the release workflow needs it).
set -euo pipefail
cd "$(dirname "$0")/../.."

status=0
err() { echo "CHANGELOG.md: $*" >&2; status=1; }

mapfile -t headings < <(grep -E '^## \[' CHANGELOG.md)
[[ "${headings[0]:-}" == "## [Unreleased]" ]] || err "first section must be '## [Unreleased]'"

versions=()
for h in "${headings[@]:1}"; do
  if [[ "${h}" =~ ^##\ \[([0-9]+\.[0-9]+\.[0-9]+)\]\ -\ [0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    versions+=("${BASH_REMATCH[1]}")
  else
    err "malformed release heading: '${h}' (want '## [X.Y.Z] - YYYY-MM-DD')"
  fi
done

if ((${#versions[@]} > 1)) && [[ "$(printf '%s\n' "${versions[@]}" | sort -rV)" != "$(printf '%s\n' "${versions[@]}")" ]]; then
  err "release sections are not newest-first: ${versions[*]}"
fi

while read -r tag; do
  [[ -n "${tag}" ]] || continue
  printf '%s\n' "${versions[@]}" | grep -qxF "${tag#v}" || err "tag ${tag} has no '## [${tag#v}]' section"
done < <(git tag -l 'v[0-9]*.[0-9]*.[0-9]*')

((status == 0)) && echo "CHANGELOG.md: OK (${#versions[@]} releases)"
exit "${status}"
