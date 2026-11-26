#!/usr/bin/env bash
# bashx: test API for bash. Source it from a test file, write one test_*
# function per case, end the file with test::main.
#
#   source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"
#
#   test_should_add_two_numbers() {
#     assert "$(add 2 3)" == 5
#   }
#
#   test::main
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
_TEST_INITED=0
_TEST_FAIL_FLAG=""     # inside a case: the file an assertion creates when it fails
declare -A _TEST_RAN=()     # function → 1 once a test::run ran it
declare -A _TEST_TABLES=()  # function → its table (test::cases)

if [[ -n "${NO_COLOR:-}" ]]; then
  _TEST_RED="" _TEST_GREEN="" _TEST_YELLOW="" _TEST_DIM="" _TEST_RESET=""
else
  _TEST_RED=$'\033[0;31m' _TEST_GREEN=$'\033[0;32m' _TEST_YELLOW=$'\033[1;33m'
  _TEST_DIM=$'\033[2m' _TEST_RESET=$'\033[0m'
fi

# Exit status of a skipped case (test::skip): neither passed nor failed.
readonly _TEST_SKIP_STATUS=77

# ── Lifecycle ────────────────────────────────────────────────────────────────

# Runs every test_* function of the file not run yet, in the order they are
# defined (once per row for those with a table), then the summary. Make it the
# last line of the file. Not run from the EXIT trap on purpose: on bash 5.0, a
# `return` without argument anywhere under a trap returns the status from
# before the trap, so `check || return` in the code under test would pass.
# Usage: test::main
test::main() {
  local _line fn row
  local -a args
  while read -r _line fn; do
    [[ -z "${_TEST_RAN[${fn}]:-}" ]] || continue
    if [[ -z "${_TEST_TABLES[${fn}]+set}" ]]; then
      test::run "$(test::_describe "${fn}")" "${fn}"
      continue
    fi
    while IFS= read -r row; do
      row="${row#"${row%%[![:space:]]*}"}"
      [[ -n "${row}" && "${row}" != \#* ]] || continue
      eval "args=(${row})"
      test::run "$(test::_describe "${fn}") [${args[*]}]" "${fn}" "${args[@]}"
    done <<<"${_TEST_TABLES[${fn}]}"
  done < <(test::_discover | sort -n)
  test::summary
}

# Gives a case a table: test::main runs it once per line of stdin, with the
# words of the line (shell quoting) as arguments. Blank and # lines are skipped.
# Usage: test::cases <function> <<'EOF' ... EOF
test::cases() {
  _TEST_TABLES["$1"]="$(cat)"
}

# Starts a test file: resets the counters, prints its name, calls before_all.
# Implicit: the first test::run calls it.
# Usage: test::init
test::init() {
  _TEST_INITED=1
  _TEST_COUNT=0 _TEST_PASSED=0 _TEST_FAILED=0 _TEST_SKIPPED=0
  _TEST_START_US="$(test::_now_us)"
  _TEST_SUITE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bashx-suite.XXXXXX")"
  echo "🧪 $(test::_file_name)"
  ! declare -F before_all >/dev/null || before_all
}

# Runs one case: <function> [args...] in a subshell with errexit on, stdin
# closed, a private tmp dir and bin dir (see test::tmp_dir, mock), between
# before_each and after_each. Its output is shown only when it fails or is
# skipped, or always with BASHX_VERBOSE. With BASHX_FILTER, runs only the
# cases whose description contains it.
# Usage: test::run "<description>" <function> [args...]
test::run() {
  local -r name="$1"
  shift
  ((_TEST_INITED == 1)) || test::init
  _TEST_RAN["$1"]=1
  [[ -z "${BASHX_FILTER:-}" || "${name}" == *"${BASHX_FILTER}"* ]] || return 0
  _TEST_COUNT=$((_TEST_COUNT + 1))
  local start status=0 case_tmp
  start="$(test::_now_us)"
  case_tmp="$(mktemp -d "${TMPDIR:-/tmp}/bashx-case.XXXXXX")"
  mkdir -p "${case_tmp}/.bin"

  # Not `( … ) || status=1`: bash turns errexit off for the whole left side
  # of `||`, so a failed command mid-case would be ignored.
  set +e
  (
    set -e
    _TEST_TMP="${case_tmp}"
    _TEST_FAIL_FLAG="${case_tmp}/.failed"
    PATH="${case_tmp}/.bin:${PATH}"
    if declare -F after_each >/dev/null; then trap after_each EXIT; fi
    ! declare -F before_each >/dev/null || before_each
    "$@"
  ) >"${case_tmp}/.log" 2>&1 </dev/null
  status=$?
  set -e
  # An assertion that failed under `if`, `||` or in a $( ) left its flag.
  [[ ! -e "${case_tmp}/.failed" ]] || ((status == _TEST_SKIP_STATUS)) || status=1

  local ms=$((($(test::_now_us) - start) / 1000))
  local duration="${ms}ms" show_log=1
  ((ms < 300)) || duration="${_TEST_YELLOW}${ms}ms${_TEST_RESET}"
  ((ms < 1200)) || duration="${_TEST_RED}${ms}ms${_TEST_RESET}"
  if ((status == 0)); then
    _TEST_PASSED=$((_TEST_PASSED + 1))
    echo "│  ${_TEST_GREEN}✓${_TEST_RESET} ${name} (${duration})"
    [[ -n "${BASHX_VERBOSE:-}" ]] || show_log=0
  elif ((status == _TEST_SKIP_STATUS)); then
    _TEST_SKIPPED=$((_TEST_SKIPPED + 1))
    echo "│  ${_TEST_DIM}○ ${name} (skipped)${_TEST_RESET}"
  else
    _TEST_FAILED=$((_TEST_FAILED + 1))
    echo "│  ${_TEST_RED}✗${_TEST_RESET} ${name} (${duration})"
  fi
  ((show_log == 0)) || sed 's/^/│    /' "${case_tmp}/.log"
  [[ -z "${BASHX_CASES_FILE:-}" ]] || test::_record_case "${name}" "${status}" "${ms}" "$((show_log == 1))" "${case_tmp}/.log"
  rm -rf -- "${case_tmp:?}"
  return 0
}

# Ends the current case as skipped, with an optional reason.
# Usage: test::skip ["<reason>"]
test::skip() {
  [[ -z "${1:-}" ]] || echo "${_TEST_DIM}skipped: $1${_TEST_RESET}"
  exit "${_TEST_SKIP_STATUS}"
}

# Prints the file's tally; returns 1 when a case failed. test::main calls it.
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

# ── assert ───────────────────────────────────────────────────────────────────

# One assertion, read like a [[ ]]: <actual> <operator> [<expected>]. A failed
# one prints where and what, and ends the case wherever it runs: under `if`,
# `||`, `&&`, `!`, or in a $( ).
#
#   ==  !=  contains  !contains  matches  starts_with  ends_with  empty  !empty
#   -eq -ne -lt -le -gt -ge                         (integers)
#   is_file  is_dir  exists  !exists                (<actual> is a path)
#   has <text>  !has <text>  same_as <text or file> (<actual> is a file)
#
# Usage: assert <actual> <operator> [<expected>]
assert() {
  local -r actual="${1-}" op="${2-}"
  local expected="${3-}" ok=0 arity=3
  case "${op}" in
    empty | !empty | is_file | is_dir | exists | !exists) arity=2 ;;
  esac
  (($# <= arity)) || test::_assert_failed "assert: too many arguments for '${op}' ($#): $(printf '%q ' "$@")"
  case "${op}" in
    ==) [[ "${actual}" == "${expected}" ]] && ok=1 ;;
    !=) [[ "${actual}" != "${expected}" ]] && ok=1 ;;
    contains) [[ "${actual}" == *"${expected}"* ]] && ok=1 ;;
    !contains) [[ "${actual}" != *"${expected}"* ]] && ok=1 ;;
    matches) [[ "${actual}" =~ ${expected} ]] && ok=1 ;;
    starts_with) [[ "${actual}" == "${expected}"* ]] && ok=1 ;;
    ends_with) [[ "${actual}" == *"${expected}" ]] && ok=1 ;;
    empty) [[ -z "${actual}" ]] && ok=1 ;;
    !empty) [[ -n "${actual}" ]] && ok=1 ;;
    -eq | -ne | -lt | -le | -gt | -ge)
      [[ "${actual}" =~ ^-?[0-9]+$ && "${expected}" =~ ^-?[0-9]+$ ]] \
        || test::_assert_failed "assert: ${op} compares integers, got '${actual}' and '${expected}'"
      test "${actual}" "${op}" "${expected}" && ok=1 ;;
    is_file) [[ -f "${actual}" ]] && ok=1 ;;
    is_dir) [[ -d "${actual}" ]] && ok=1 ;;
    exists) [[ -e "${actual}" ]] && ok=1 ;;
    !exists) [[ ! -e "${actual}" ]] && ok=1 ;;
    has | !has | same_as)
      [[ -f "${actual}" ]] || test::_assert_failed "no file at: ${actual}"
      local content
      content="$(<"${actual}")"
      case "${op}" in
        has) [[ "${content}" == *"${expected}"* ]] && ok=1 ;;
        !has) [[ "${content}" != *"${expected}"* ]] && ok=1 ;;
        same_as)
          [[ ! -f "${expected}" ]] || expected="$(<"${expected}")"
          [[ "${content}" == "${expected}" ]] && ok=1
          ((ok == 1)) || test::_assert_failed "$(test::_compare "${expected}" "${content}")" ;;
      esac ;;
    *) test::_assert_failed "assert: unknown operator '${op}' (see docs/api.md#assert)" ;;
  esac
  ((ok == 0)) || return 0
  case "${op}" in
    ==) test::_assert_failed "$(test::_compare "${expected}" "${actual}")" ;;
    empty | !empty | is_file | is_dir | exists | !exists) test::_assert_failed "${op}, but got: ${actual}" ;;
    has | !has) test::_assert_failed "file: ${actual}" "${op}: ${expected}" ;;
    *) test::_assert_failed "actual: ${actual}" "${op}: ${expected}" ;;
  esac
}
test::assert() { assert "$@"; }

# expected / actual on two lines, or a unified diff when either has several.
test::_compare() {
  local -r expected="$1" actual="$2"
  if [[ "${actual}" == *$'\n'* || "${expected}" == *$'\n'* ]]; then
    echo "diff (- expected, + actual):"
    diff -u <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}") | sed '1,2d' || true
  else
    printf 'expected: %s\nactual:   %s\n' "${expected}" "${actual}"
  fi
}

# Prints the failing line and <message>..., flags the case as failed and
# ends it, even when errexit is off or inside a $( ).
test::_assert_failed() {
  {
    echo "${_TEST_RED}✗ $(test::_location)${_TEST_RESET}"
    local message
    for message in "$@"; do printf '%s\n' "${message}" | sed 's/^/  /'; done
  } >&2
  [[ -z "${_TEST_FAIL_FLAG}" ]] || : >"${_TEST_FAIL_FLAG}"
  exit 1
}

# "<file>:<line>  <source line>" of the first caller outside bashx, then
# "called from …" up to the case when that caller is a helper.
test::_location() {
  local i=1
  while [[ "${FUNCNAME[i]:-}" == test::* || "${FUNCNAME[i]:-}" == assert ]]; do i=$((i + 1)); done
  local file="${BASH_SOURCE[i]:-}" line="${BASH_LINENO[i - 1]:-0}"
  printf '%s:%s  %s\n' "${file##*/}" "${line}" "$(sed -n "${line}{s/^[[:space:]]*//;p;}" "${file}" 2>/dev/null)"
  while [[ "${FUNCNAME[i]:-}" != test_* && -n "${FUNCNAME[i + 1]:-}" \
    && "${FUNCNAME[i + 1]}" != test::* && "${FUNCNAME[i + 1]}" != main ]]; do
    i=$((i + 1))
    printf '  called from %s:%s (%s)\n' "${BASH_SOURCE[i]##*/}" "${BASH_LINENO[i - 1]}" "${FUNCNAME[i]}"
  done
}

# ── capture ──────────────────────────────────────────────────────────────────

# Runs a command in a subshell, stdin closed, and keeps what it did without
# stopping the case: STATUS, STDOUT and STDERR (trailing newlines dropped, as
# with $( )). Upper case: shellcheck does not flag them as never assigned.
# Usage: capture <command> [args...]
# shellcheck disable=SC2034 # read by the test file
capture() {
  local -r dir="$(mktemp -d "${_TEST_TMP:-${TMPDIR:-/tmp}}/capture.XXXXXX")"
  STATUS=0
  ("$@") >"${dir}/out" 2>"${dir}/err" </dev/null || STATUS=$?
  STDOUT="$(<"${dir}/out")"
  STDERR="$(<"${dir}/err")"
  rm -rf -- "${dir:?}"
}
test::capture() { capture "$@"; }

# ── mock ─────────────────────────────────────────────────────────────────────

# Replaces <name> until the end of the case, both for calls from the test's
# shell (a function, which also shadows a function of the code under test)
# and for calls from child processes (an executable first on PATH). Every
# call is recorded: see mock::calls and mock::count.
# Usage: mock <name> [--exit N] [--stdout TEXT] [--stderr TEXT]
#        mock <name> <<'EOF'   (a bash body; "$@" are the arguments)
mock() {
  local -r name="$1"
  shift
  [[ -n "${_TEST_TMP}" ]] || { echo "mock: works inside a case only" >&2; return 2; }
  [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9_:.-]*$ ]] || { echo "mock: invalid name '${name}'" >&2; return 2; }
  local code=0 out="" err="" body=""
  while (($#)); do
    case "$1" in
      --exit) code="$2"; shift 2 ;;
      --stdout) out="$2"; shift 2 ;;
      --stderr) err="$2"; shift 2 ;;
      *) echo "mock: unknown option $1" >&2; return 2 ;;
    esac
  done
  [[ -t 0 ]] || body="$(cat)"
  local -r dir="${_TEST_TMP}/.mocks/${name}"
  mkdir -p "${dir}"
  : >"${dir}/calls"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >>%q\n' "${dir}/calls"
    [[ -z "${out}" ]] || printf 'printf "%%s\\n" %q\n' "${out}"
    [[ -z "${err}" ]] || printf 'printf "%%s\\n" %q >&2\n' "${err}"
    [[ -z "${body}" ]] || printf '%s\n' "${body}"
    printf 'exit %q\n' "${code}"
  } >"${dir}/run"
  chmod +x "${dir}/run"
  ln -sf "${dir}/run" "${_TEST_TMP}/.bin/${name}"
  eval "${name}() { $(printf '%q' "${dir}/run") \"\$@\"; }"
}
test::mock() { mock "$@"; }

# The arguments of every call of a mock, one call per line.
# Usage: mock::calls <name>
mock::calls() { cat "${_TEST_TMP}/.mocks/$1/calls"; }

# How many times a mock was called.
# Usage: mock::count <name>
mock::count() { wc -l <"${_TEST_TMP}/.mocks/$1/calls" | tr -d ' '; }

# ── Assertions (v1) ──────────────────────────────────────────────────────────
# Kept as they were: each prints what differs and returns 1 on failure (they
# rely on errexit to end the case, unlike assert). The optional last argument
# is a message printed with the failure.

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
# dir: prepend it to PATH inside the case to replace the real command. `mock`
# does this and records the calls.
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

# v1 assertions' failure. Usage: test::_fail <message> <line>...
test::_fail() {
  local -r message="$1"
  shift
  echo "${_TEST_RED}✗ Assertion failed${_TEST_RESET}  $(test::_location | head -n 1)"
  local line
  for line in "$@"; do echo "  ${line}"; done
  [[ -z "${message}" ]] || echo "  Message:  ${message}"
  return 1
}

# "<line> <function>" for each test_* function of the file, unsorted.
test::_discover() {
  local name
  shopt -s extdebug
  while read -r _ _ name; do
    [[ "${name}" == test_* ]] || continue
    declare -F "${name}" | awk '{ print $2, $1 }'
  done < <(declare -F)
  shopt -u extdebug
}

# test_should_add_two_integers → "should add two integers"
test::_describe() {
  local d="${1#test_}"
  echo "${d//_/ }"
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

# One line per case for the runner's reports (bashx test):
# <status> TAB <ms> TAB <name> TAB <output>, status passed, failed or skipped,
# fields escaped by test::_escape, colors stripped. The output is the one the
# console shows: failed and skipped cases, every case with BASHX_VERBOSE.
# Usage: test::_record_case <name> <exit status> <ms> <1 to keep the log> <log>
test::_record_case() {
  local -r name="$1" status="$2" ms="$3" keep_log="$4" log="$5"
  local state=failed output=""
  ((status != 0)) || state=passed
  ((status != _TEST_SKIP_STATUS)) || state=skipped
  ((keep_log == 0)) || output="$(sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g' "${log}")"
  printf '%s\t%s\t%s\t%s\n' "${state}" "${ms}" "$(test::_escape "${name}")" "$(test::_escape "${output}")" \
    >>"${BASHX_CASES_FILE}"
}

# <text> on one line: backslash, tab, newline and carriage return written \\,
# \t, \n and \r (printf %b reads it back).
# Usage: test::_escape <text>
test::_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '%s' "${s}"
}

# Counts for the runner (bashx test); the exit code stays the pass/fail signal.
test::_write_result_file() {
  [[ -n "${BASHX_RESULT_FILE:-}" ]] || return 0
  printf 'passed=%s\nfailed=%s\nskipped=%s\ntotal=%s\nduration_ms=%s\n' \
    "${_TEST_PASSED}" "${_TEST_FAILED}" "${_TEST_SKIPPED}" "${_TEST_COUNT}" "$1" >"${BASHX_RESULT_FILE}"
}

# On exit: a file that defines test_* cases but never ran them (test::main
# forgotten) fails, saying why; a file that ran cases but forgot test::summary
# gets it. Only in the file's own shell: a library that chains EXIT traps can
# hand this handler to a case's subshell.
test::_on_exit() {
  local status=$?
  [[ "${BASHPID}" == "$$" ]] || exit "${status}"
  if ((status == 0 && _TEST_SUMMARY_DONE == 0)); then
    local _line fn missing=0
    while read -r _line fn; do
      [[ -n "${_TEST_RAN[${fn}]:-}" ]] || missing=$((missing + 1))
    done < <(test::_discover)
    if ((missing > 0)); then
      echo "${_TEST_RED}✗ ${missing} test_* function(s) never ran: end the file with test::main${_TEST_RESET}" >&2
      status=1
    fi
  fi
  if ((_TEST_COUNT > 0 && _TEST_SUMMARY_DONE == 0)); then
    test::summary || status=1
  fi
  ((_TEST_FAILED == 0)) || status=1
  [[ -z "${_TEST_SUITE_TMP}" ]] || rm -rf -- "${_TEST_SUITE_TMP}"
  exit "${status}"
}
trap test::_on_exit EXIT
