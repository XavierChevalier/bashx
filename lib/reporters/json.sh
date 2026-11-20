#!/usr/bin/env bash
# JSON report: {"summary": {...}, "failed_files": [...], "output": "..."}.
# Usage: json.sh <report> <log> <passed> <failed> <skipped> <total> <files> [<failed file>...]
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

main() {
  local -r report="$1" log="$2" passed="$3" failed="$4" skipped="$5" total="$6" files="$7"
  shift 7
  local failed_json="" file
  for file in "$@"; do failed_json+="${failed_json:+, }$(json_string "${file}")"; done
  printf '{\n  "summary": {"passed": %d, "failed": %d, "skipped": %d, "total": %d, "files": %d},\n  "failed_files": [%s],\n  "output": %s\n}\n' \
    "${passed}" "${failed}" "${skipped}" "${total}" "${files}" "${failed_json}" "$(json_string "$(cat "${log}")")" >"${report}"
}

main "$@"
