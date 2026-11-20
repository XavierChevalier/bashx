#!/usr/bin/env bash
# Markdown report: summary, failed files, full output.
# Usage: markdown.sh <report> <log> <passed> <failed> <skipped> <total> <files> [<failed file>...]
set -euo pipefail

main() {
  local -r report="$1" log="$2" passed="$3" failed="$4" skipped="$5" total="$6" files="$7"
  shift 7
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
