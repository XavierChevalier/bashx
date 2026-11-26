#!/usr/bin/env bash
# JSON report: {"summary": {...}, "failed_files": [...], "cases": [...], "output": "..."}.
# Usage: json.sh <report> <log> <cases> <passed> <failed> <skipped> <total> <files> [<failed file>...]
set -euo pipefail

# A JSON string literal of $1.
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\033'/\\u001b}"
  printf '"%s"' "${s}"
}

# One object per line of <cases> (runner::collect_cases), comma separated.
cases_json() {
  local file status ms name output sep=""
  while IFS=$'\t' read -r file status ms name output; do
    printf '%s\n    {"file": %s, "name": %s, "status": "%s", "duration_ms": %d, "output": %s}' "${sep}" \
      "$(json_string "$(printf '%b' "${file}")")" "$(json_string "$(printf '%b' "${name}")")" "${status}" "${ms}" \
      "$(json_string "$(printf '%b' "${output}")")"
    sep=","
  done <"$1"
  [[ -z "${sep}" ]] || printf '\n  '
}

main() {
  local -r report="$1" log="$2" cases="$3" passed="$4" failed="$5" skipped="$6" total="$7" files="$8"
  shift 8
  local failed_json="" file
  for file in "$@"; do failed_json+="${failed_json:+, }$(json_string "${file}")"; done
  printf '{\n  "summary": {"passed": %d, "failed": %d, "skipped": %d, "total": %d, "files": %d},\n  "failed_files": [%s],\n  "cases": [%s],\n  "output": %s\n}\n' \
    "${passed}" "${failed}" "${skipped}" "${total}" "${files}" "${failed_json}" "$(cases_json "${cases}")" \
    "$(json_string "$(cat "${log}")")" >"${report}"
}

main "$@"
