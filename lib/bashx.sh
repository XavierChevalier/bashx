#!/usr/bin/env bash
# bashx: test API for bash. Source it from a test file, write one function per
# case, run each case with test::run, end with test::summary.
#
#   source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"
#
#   test_should_add_two_numbers() {
#     test::assert_equals 5 "$(add 2 3)"
#   }
#
#   test::init
#   test::run "should add two numbers" test_should_add_two_numbers
#   test::summary
#
# Every case runs in a subshell with errexit on and its own tmp dir: a failing
# command or assertion fails the case, and nothing it changes (variables,
# functions, PATH, cwd) reaches the next one. See docs/writing-tests.md.

set -euo pipefail

BASHX_LIB="${BASHX_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

_TEST_COUNT=0
_TEST_PASSED=0
_TEST_FAILED=0
_TEST_SKIPPED=0
_TEST_START_US=""
_TEST_TMP=""
_TEST_SUITE_TMP=""
_TEST_SUMMARY_DONE=0

if [[ -n "${NO_COLOR:-}" ]]; then
  _TEST_RED="" _TEST_GREEN="" _TEST_YELLOW="" _TEST_DIM="" _TEST_RESET=""
else
  _TEST_RED=$'\033[0;31m' _TEST_GREEN=$'\033[0;32m' _TEST_YELLOW=$'\033[1;33m'
  _TEST_DIM=$'\033[2m' _TEST_RESET=$'\033[0m'
fi

# Exit status of a skipped case (test::skip): neither passed nor failed.
readonly _TEST_SKIP_STATUS=77

# ── Lifecycle ────────────────────────────────────────────────────────────────

# Starts a test file: resets the counters, prints its name.
# Usage: test::init
test::init() {
  _TEST_COUNT=0 _TEST_PASSED=0 _TEST_FAILED=0 _TEST_SKIPPED=0
  _TEST_START_US="$(test::_now_us)"
  _TEST_SUITE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bashx-suite.XXXXXX")"
  echo "🧪 $(test::_file_name)"
}

# Runs one case: <function> [args...] in a subshell with errexit on and a
# private tmp dir (see test::tmp_dir), removed afterwards.
# Usage: test::run "<description>" <function> [args...]
test::run() {
  local -r name="$1"
  shift
  _TEST_COUNT=$((_TEST_COUNT + 1))
  local start status=0
  start="$(test::_now_us)"
  local case_tmp
  case_tmp="$(mktemp -d "${TMPDIR:-/tmp}/bashx-case.XXXXXX")"

  # Not `( … ) || status=1`: bash turns errexit off for the whole left side
  # of `||`, so a failed command mid-case would be ignored.
  set +e
  (
    set -e
    _TEST_TMP="${case_tmp}"
    "$@"
  )
  status=$?
  set -e
  rm -rf -- "${case_tmp:?}"

  local ms=$((($(test::_now_us) - start) / 1000))
  local duration="${ms}ms"
  ((ms < 300)) || duration="${_TEST_YELLOW}${ms}ms${_TEST_RESET}"
  ((ms < 1200)) || duration="${_TEST_RED}${ms}ms${_TEST_RESET}"
  if ((status == 0)); then
    _TEST_PASSED=$((_TEST_PASSED + 1))
    echo "│  ${_TEST_GREEN}✓${_TEST_RESET} ${name} (${duration})"
  elif ((status == _TEST_SKIP_STATUS)); then
    _TEST_SKIPPED=$((_TEST_SKIPPED + 1))
    echo "│  ${_TEST_DIM}○ ${name} (skipped)${_TEST_RESET}"
  else
    _TEST_FAILED=$((_TEST_FAILED + 1))
    echo "│  ${_TEST_RED}✗${_TEST_RESET} ${name} (${duration})"
  fi
  return 0
}

# Ends the current case as skipped, with an optional reason.
# Usage: test::skip ["<reason>"]
test::skip() {
  [[ -z "${1:-}" ]] || echo "    ${_TEST_DIM}skipped: $1${_TEST_RESET}"
  exit "${_TEST_SKIP_STATUS}"
}

# Prints the file's tally; returns 1 when a case failed.
# Usage: test::summary
test::summary() {
  local ms=$((($(test::_now_us) - ${_TEST_START_US:-$(test::_now_us)}) / 1000))
  _TEST_SUMMARY_DONE=1
  test::_write_result_file "${ms}"
  local skipped=""
  ((_TEST_SKIPPED == 0)) || skipped=" / Skipped: ${_TEST_SKIPPED}"
  if ((_TEST_FAILED > 0)); then
    echo "└── ${_TEST_RED}✗ Failed: ${_TEST_FAILED} / Passed: ${_TEST_PASSED}${skipped} / Total: ${_TEST_COUNT} (${ms}ms)${_TEST_RESET}"
    return 1
  fi
  echo "└── ${_TEST_GREEN}✓ All ${_TEST_COUNT} tests passed${skipped} (${ms}ms)${_TEST_RESET}"
}

# ── Assertions ───────────────────────────────────────────────────────────────
# Each prints what differs and returns 1 on failure. The optional last
# argument is a message printed with the failure.

# Usage: test::assert_equals <expected> <actual> [message]
test::assert_equals() {
  [[ "$1" == "$2" ]] && return 0
  test::_fail "${3:-}" "Expected: $1" "Actual:   $2"
}

# Usage: test::assert_not_equals <unexpected> <actual> [message]
test::assert_not_equals() {
  [[ "$1" != "$2" ]] && return 0
  test::_fail "${3:-}" "Expected a value other than: $1"
}

# Usage: test::assert_contains <haystack> <needle> [message]
test::assert_contains() {
  [[ "$1" == *"$2"* ]] && return 0
  test::_fail "${3:-}" "Expected '$1' to contain '$2'"
}

# Usage: test::assert_not_contains <haystack> <needle> [message]
test::assert_not_contains() {
  [[ "$1" != *"$2"* ]] && return 0
  test::_fail "${3:-}" "Expected '$1' not to contain '$2'"
}

# Usage: test::assert_matches <string> <extended regex> [message]
test::assert_matches() {
  [[ "$1" =~ $2 ]] && return 0
  test::_fail "${3:-}" "Expected '$1' to match /$2/"
}

# Runs <command> (output discarded) and compares its exit code.
# Usage: test::assert_exit_code <expected code> <command> [args...]
test::assert_exit_code() {
  local -r expected="$1"
  shift
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  [[ "${expected}" == "${actual}" ]] && return 0
  test::_fail "" "Expected exit code ${expected}, got ${actual}: $*"
}

# Usage: test::assert_file_exists <file> [message]
test::assert_file_exists() {
  [[ -f "$1" ]] && return 0
  test::_fail "${2:-}" "Expected file to exist: $1"
}

# Usage: test::assert_file_not_exists <path> [message]
test::assert_file_not_exists() {
  [[ ! -e "$1" ]] && return 0
  test::_fail "${2:-}" "Expected no file at: $1"
}

# Usage: test::assert_file_contains <file> <needle> [message]
test::assert_file_contains() {
  test::assert_file_exists "$1" "${3:-}" || return 1
  test::assert_contains "$(cat "$1")" "$2" "${3:-}"
}

# Usage: test::assert_file_not_contains <file> <needle> [message]
test::assert_file_not_contains() {
  test::assert_file_exists "$1" "${3:-}" || return 1
  test::assert_not_contains "$(cat "$1")" "$2" "${3:-}"
}

# <expected> is a string, or a file whose content is expected.
# Usage: test::assert_file_equals <file> <expected> [message]
test::assert_file_equals() {
  test::assert_file_exists "$1" "${3:-}" || return 1
  local expected="$2"
  [[ ! -f "${expected}" ]] || expected="$(cat "${expected}")"
  test::assert_equals "${expected}" "$(cat "$1")" "${3:-}"
}

# ── Fixtures ─────────────────────────────────────────────────────────────────

# A new empty directory, removed with the case (or with the file outside one).
# Usage: dir="$(test::tmp_dir)"
test::tmp_dir() {
  mktemp -d "${_TEST_TMP:-${_TEST_SUITE_TMP:-${TMPDIR:-/tmp}}}/tmp.XXXXXX"
}

# One directory for the whole file (built once, read by every case),
# removed when the file exits. Needs test::init first.
# Usage: dir="$(test::suite_tmp_dir)"
test::suite_tmp_dir() {
  [[ -n "${_TEST_SUITE_TMP}" ]] || {
    echo "test::suite_tmp_dir needs test::init first" >&2
    return 1
  }
  echo "${_TEST_SUITE_TMP}"
}

# Writes an executable <name> running <script> into a bin dir and prints the
# dir: prepend it to PATH inside the case to replace the real command.
# Usage: PATH="$(test::mock_command curl 'echo "{}"'):${PATH}"
test::mock_command() {
  local -r name="$1" script="$2"
  local bin_dir="${3:-}"
  [[ -n "${bin_dir}" ]] || bin_dir="$(test::tmp_dir)"
  mkdir -p "${bin_dir}"
  printf '#!/usr/bin/env bash\n%s\n' "${script}" >"${bin_dir}/${name}"
  chmod +x "${bin_dir}/${name}"
  echo "${bin_dir}"
}

# ── Internals ────────────────────────────────────────────────────────────────

# Microseconds since the epoch (bash 5 EPOCHREALTIME, any locale separator).
test::_now_us() {
  local now="${EPOCHREALTIME}"
  echo "${now//[!0-9]/}"
}

# Usage: test::_fail <message> <line>...
test::_fail() {
  local -r message="$1"
  shift
  echo "    ${_TEST_RED}✗ Assertion failed${_TEST_RESET}"
  local line
  for line in "$@"; do echo "      ${line}"; done
  [[ -z "${message}" ]] || echo "      Message:  ${message}"
  return 1
}

# The test file's path, relative to the git root (or the cwd) when inside it.
test::_file_name() {
  local file="${BASH_SOURCE[-1]}" dir root
  # Physical paths: git prints them (macOS: /var is /private/var).
  dir="$(cd "$(dirname "${file}")" && pwd -P)"
  file="${dir}/$(basename "${file}")"
  root="$(git -C "${dir}" rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  file="${file#"${root}"/}"
  echo "./${file#./}"
}

# Counts for the runner (bashx test); the exit code stays the pass/fail signal.
test::_write_result_file() {
  [[ -n "${BASHX_RESULT_FILE:-}" ]] || return 0
  printf 'passed=%s\nfailed=%s\nskipped=%s\ntotal=%s\nduration_ms=%s\n' \
    "${_TEST_PASSED}" "${_TEST_FAILED}" "${_TEST_SKIPPED}" "${_TEST_COUNT}" "$1" >"${BASHX_RESULT_FILE}"
}

# A file that runs cases but forgets test::summary would exit 0 whatever its
# cases did: summarise on exit instead. Only in the file's own shell: a library
# that chains EXIT traps can hand this handler to a case's subshell.
test::_on_exit() {
  local status=$?
  [[ "${BASHPID}" == "$$" ]] || exit "${status}"
  if ((_TEST_COUNT > 0 && _TEST_SUMMARY_DONE == 0)); then
    test::summary || status=1
  fi
  ((_TEST_FAILED == 0)) || status=1
  [[ -z "${_TEST_SUITE_TMP}" ]] || rm -rf -- "${_TEST_SUITE_TMP}"
  exit "${status}"
}
trap test::_on_exit EXIT
