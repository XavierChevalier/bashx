# shellcheck shell=bash
# BASH_ENV hook of `bashx test --coverage=DIR`: every bash process a test
# starts (the test file, the scripts it runs, their `bash -c`) writes its
# starting directory, then "+<file>:<line>: <command>" for each command it
# runs, to its own ${BASHX_COVERAGE_TRACE_DIR}/<pid>.trace. A separate fd keeps
# stderr untouched, so tests that assert on it still pass. The { } group
# matters: a bare `exec {fd}>>f 2>/dev/null` would silence the shell's stderr.
if [[ -n "${BASHX_COVERAGE_TRACE_DIR:-}" ]] \
  && { exec {__bashx_coverage_fd}>>"${BASHX_COVERAGE_TRACE_DIR}/${BASHPID}.trace"; } 2>/dev/null; then
  printf '#cwd %s\n' "${PWD}" >&"${__bashx_coverage_fd}"
  BASH_XTRACEFD="${__bashx_coverage_fd}"
  PS4='+${BASH_SOURCE[0]-}:${LINENO}: '
  set -o xtrace
fi
