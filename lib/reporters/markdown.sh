#!/usr/bin/env bash
# Markdown report: summary, failed files and cases, full output.
# Usage: markdown.sh <report> <log> <cases> <passed> <failed> <skipped> <total> <files> [<failed file>...]
set -euo pipefail

main() {
  local -r report="$1" log="$2" cases="$3" passed="$4" failed="$5" skipped="$6" total="$7" files="$8"
  shift 8
  local file status name
  {
    echo "# Test Report"
    echo
    echo "| Passed | Failed | Skipped | Total | Files |"
    echo "| ---: | ---: | ---: | ---: | ---: |"
    echo "| ${passed} | ${failed} | ${skipped} | ${total} | ${files} |"
    if (($# > 0)); then
      echo
      echo "## Failed test files"
      echo
      printf -- '- `%s`\n' "$@"
      echo
      echo "## Failed cases"
      echo
      while IFS=$'\t' read -r file status _ name _; do
        [[ "${status}" == failed ]] || continue
        printf -- '- `%s`: %s\n' "$(printf '%b' "${file}")" "$(printf '%b' "${name}")"
      done <"${cases}"
    fi
    echo
    echo "## Output"
    echo
    echo '```'
    sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g' "${log}"
    echo '```'
  } >"${report}"
}

main "$@"
