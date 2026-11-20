#!/usr/bin/env bash
# JUnit XML report: one testcase per failed file (CI systems read the counts).
# Usage: junit.sh <report> <log> <passed> <failed> <skipped> <total> <files> [<failed file>...]
set -euo pipefail

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "${s}"
}

main() {
  local -r report="$1" passed="$3" failed="$4" skipped="$5" total="$6"
  shift 7
  local file
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo "<testsuites name=\"bashx\" tests=\"${total}\" failures=\"${failed}\" skipped=\"${skipped}\" errors=\"0\">"
    echo "  <testsuite name=\"bashx\" tests=\"${total}\" failures=\"${failed}\" skipped=\"${skipped}\" errors=\"0\">"
    for file in "$@"; do
      echo "    <testcase classname=\"bashx\" name=\"$(xml_escape "${file}")\">"
      echo "      <failure message=\"test file failed\">$(xml_escape "${file}")</failure>"
      echo "    </testcase>"
    done
    ((passed == 0)) || echo "    <testcase classname=\"bashx\" name=\"passed\"/>"
    echo "  </testsuite>"
    echo "</testsuites>"
  } >"${report}"
}

main "$@"
