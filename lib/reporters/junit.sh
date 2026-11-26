#!/usr/bin/env bash
# JUnit XML report: one testcase per case, the test file as its class, the
# output of a failed or skipped case in its <failure> or <skipped>.
# Usage: junit.sh <report> <log> <cases> <passed> <failed> <skipped> <total> <files> [<failed file>...]
set -euo pipefail

# $1 escaped for XML, without the control characters XML 1.0 refuses. The
# replacements are quoted: bash 5.2 reads a bare & in them as the match.
xml_escape() {
  local s
  s="$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037')"
  s="${s//&/"&amp;"}"
  s="${s//</"&lt;"}"
  s="${s//>/"&gt;"}"
  s="${s//\"/"&quot;"}"
  printf '%s' "${s}"
}

main() {
  local -r report="$1" cases="$3" failed="$5" skipped="$6" total="$7"
  local file status ms name output attrs
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo "<testsuites name=\"bashx\" tests=\"${total}\" failures=\"${failed}\" skipped=\"${skipped}\" errors=\"0\">"
    echo "  <testsuite name=\"bashx\" tests=\"${total}\" failures=\"${failed}\" skipped=\"${skipped}\" errors=\"0\">"
    while IFS=$'\t' read -r file status ms name output; do
      attrs="classname=\"$(xml_escape "$(printf '%b' "${file}")")\" name=\"$(xml_escape "$(printf '%b' "${name}")")\""
      attrs+=" time=\"$(awk -v ms="${ms}" 'BEGIN { printf "%.3f", ms / 1000 }')\""
      output="$(xml_escape "$(printf '%b' "${output}")")"
      case "${status}" in
        failed) printf '    <testcase %s>\n      <failure message="test failed">%s</failure>\n    </testcase>\n' "${attrs}" "${output}" ;;
        skipped) printf '    <testcase %s>\n      <skipped>%s</skipped>\n    </testcase>\n' "${attrs}" "${output}" ;;
        *) printf '    <testcase %s/>\n' "${attrs}" ;;
      esac
    done <"${cases}"
    echo "  </testsuite>"
    echo "</testsuites>"
  } >"${report}"
}

main "$@"
