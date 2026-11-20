#!/usr/bin/env bash
# Spike of the expect API proposed in docs/proposals/expect.md. Not a release:
# it loads lib/bashx.sh and adds the new verbs on top, to try them on real
# files.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/expect.sh"
#   test_should_add() { expect "$(calc::add 2 3)" to_be 5; }
#   test::main   # last line: runs every test_* function, then the summary

# shellcheck source=../../../lib/bashx.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)/bashx.sh"

_TEST_FAIL_FLAG=""    # file: an assertion failed somewhere in the case
_TEST_INITED=0
_TEST_DEFAULT_DESC=""

# ── Lifecycle ────────────────────────────────────────────────────────────────

test::init() {
  _TEST_INITED=1
  _TEST_COUNT=0 _TEST_PASSED=0 _TEST_FAILED=0 _TEST_SKIPPED=0
  _TEST_START_US="$(test::_now_us)"
  _TEST_SUITE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bashx-suite.XXXXXX")"
  echo "🧪 $(test::_file_name)"
  ! declare -F before_all >/dev/null || before_all
}

# Same contract as v1, plus: hooks, output shown only on failure, a failed
# assertion fails the case even under `if`, `||` or `$( )`, --filter.
test::run() {
  local -r name="$1"
  shift
  [[ "${_TEST_INITED}" == 1 ]] || test::init
  [[ "${FUNCNAME[1]}" == test::main ]] || _TEST_RAN["$1"]=1
  if [[ -n "${BASHX_FILTER:-}" && "${name}" != *"${BASHX_FILTER}"* ]]; then
    return 0
  fi
  _TEST_COUNT=$((_TEST_COUNT + 1))
  local start status=0 case_tmp
  start="$(test::_now_us)"
  case_tmp="$(mktemp -d "${TMPDIR:-/tmp}/bashx-case.XXXXXX")"

  set +e
  (
    set -e
    _TEST_TMP="${case_tmp}"
    _TEST_FAIL_FLAG="${case_tmp}/.failed"
    mkdir -p "${case_tmp}/.bin"
    PATH="${case_tmp}/.bin:${PATH}"
    if declare -F after_each >/dev/null; then trap 'after_each' EXIT; fi
    ! declare -F before_each >/dev/null || before_each
    "$@"
  ) >"${case_tmp}/.log" 2>&1 </dev/null
  status=$?
  set -e
  [[ ! -e "${case_tmp}/.failed" ]] || ((status == _TEST_SKIP_STATUS)) || status=1

  local ms=$((($(test::_now_us) - start) / 1000))
  if ((status == 0)); then
    _TEST_PASSED=$((_TEST_PASSED + 1))
    echo "│  ${_TEST_GREEN}✓${_TEST_RESET} ${name} (${ms}ms)"
    [[ -z "${BASHX_VERBOSE:-}" ]] || sed 's/^/│    /' "${case_tmp}/.log"
  elif ((status == _TEST_SKIP_STATUS)); then
    _TEST_SKIPPED=$((_TEST_SKIPPED + 1))
    echo "│  ${_TEST_DIM}○ ${name} (skipped)${_TEST_RESET}"
    sed 's/^/│    /' "${case_tmp}/.log"
  else
    _TEST_FAILED=$((_TEST_FAILED + 1))
    echo "│  ${_TEST_RED}✗${_TEST_RESET} ${name} (${ms}ms)"
    sed 's/^/│    /' "${case_tmp}/.log"
  fi
  rm -rf -- "${case_tmp:?}"
  return 0
}

# The test_* functions of the file, in the order they are defined.
test::_discover() {
  local line name
  shopt -s extdebug
  while read -r line; do
    name="${line##* }"
    [[ "${name}" == test_* ]] || continue
    declare -F "${name}" | awk '{print $2, $1}' 
  done < <(declare -F)
  shopt -u extdebug
}

# test_should_add_two_integers → "should add two integers"
test::_describe() {
  local d="${1#test_}"
  echo "${d//_/ }"
}

# Runs every test_* function not run yet, then the summary. The last line of
# the file. Not run from the EXIT trap: on bash 5.0, a `return` without
# argument anywhere under a trap returns the status from before the trap (0),
# so `check || return` in the code under test would pass.
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
      [[ -n "${row// /}" && "${row}" != \#* ]] || continue
      eval "args=(${row})"
      test::run "$(test::_describe "${fn}") [${args[*]}]" "${fn}" "${args[@]}"
    done <<<"${_TEST_TABLES[${fn}]}"
  done < <(test::_discover | sort -n)
  test::summary
}

# ── Tables ───────────────────────────────────────────────────────────────────

declare -A _TEST_TABLES=()   # function → its table (one case per line)
declare -A _TEST_RAN=()      # functions already run by an explicit test::run

# Gives a case function a table: it runs once per line of stdin, the words
# of the line (shell quoting) as its arguments.
# Usage: test::cases <function> <<'EOF' ... EOF
test::cases() {
  _TEST_TABLES["$1"]="$(cat)"
}

# ── run ──────────────────────────────────────────────────────────────────────

# Runs a command and keeps what it did, without stopping the case, for
# expect_status, expect_stdout and expect_stderr. Trailing newlines are
# dropped, as with $( ).
# Usage: run <command> [args...]
# shellcheck disable=SC2034 # read by the expect_* functions and the test file
run() {
  local -r dir="$(mktemp -d "${_TEST_TMP:-${TMPDIR:-/tmp}}/run.XXXXXX")"
  STATUS=0
  ( "$@" ) >"${dir}/out" 2>"${dir}/err" </dev/null || STATUS=$?
  STDOUT="$(<"${dir}/out")"
  STDERR="$(<"${dir}/err")"
  _TEST_LAST_RUN="$*"
}

# ── expect ───────────────────────────────────────────────────────────────────

# expect <value> [not] <matcher> [<expected>...]
expect() { test::_expect "value" "${1-}" "${@:2}"; }

# expect_status / expect_stdout / expect_stderr [not] <matcher> [<expected>]
# Read what the last `run` kept.
expect_status() { local _TEST_SHOW_RUN=1; test::_need_run expect_status && test::_expect "status" "${STATUS}" "$@"; }
expect_stdout() { local _TEST_SHOW_RUN=1; test::_need_run expect_stdout && test::_expect "stdout" "${STDOUT}" "$@"; }
expect_stderr() { local _TEST_SHOW_RUN=1; test::_need_run expect_stderr && test::_expect "stderr" "${STDERR}" "$@"; }

# expect_file <path> [not] <matcher> [<expected>]
# to_exist, to_be_a_directory, and every value matcher on the file's content;
# to_have_same_content_as <golden file>.
expect_file() {
  local -r path="$1"
  shift
  local negate=""
  [[ "${1-}" != not ]] || { negate=not; shift; }
  local -r matcher="${1-}"
  shift || true
  case "${matcher}" in
    to_exist | to_be_a_directory)
      local ok=0
      if [[ "${matcher}" == to_exist ]]; then [[ -e "${path}" ]] && ok=1; else [[ -d "${path}" ]] && ok=1; fi
      [[ -z "${negate}" ]] || ok=$((1 - ok))
      ((ok == 0)) || return 0
      test::_expect_failed "expected file ${path} ${negate:+not }$(test::_words "${matcher}")" ;;
    *)
      [[ -f "${path}" ]] || test::_expect_failed "expected file ${path} to exist, to check its content"
      if [[ "${matcher}" == to_have_same_content_as ]]; then
        test::_expect "file ${path}" "$(<"${path}")" ${negate:+not} to_be "$(<"$1")"
      else
        test::_expect "file ${path}" "$(<"${path}")" ${negate:+not} "${matcher}" "$@"
      fi ;;
  esac
}

# expect_mock <name> [not] to_have_been_called [<n> times]
# expect_mock <name> [not] to_have_been_called_with <args...>
# expect_mock <name> to_have_been_last_called_with <args...>
# "with" means: one call's arguments contain these, in this order.
expect_mock() {
  local -r name="$1"
  shift
  local -r file="${_TEST_TMP:-}/.mocks/${name}/calls"
  [[ -f "${file}" ]] || test::_expect_failed "expect_mock: no mock named ${name} (mock ${name} first)"
  local negate=""
  [[ "${1-}" != not ]] || { negate=not; shift; }
  local -r matcher="${1-}"
  shift || true
  local -r count="$(wc -l <"${file}" | tr -d ' ')" calls="$(<"${file}")"
  local ok=0 detail=""
  case "${matcher}" in
    to_have_been_called)
      if [[ "${1-}" =~ ^[0-9]+$ ]]; then
        ((count == $1)) && ok=1
        detail="${1} time(s)"
      else
        ((count > 0)) && ok=1
      fi ;;
    to_have_been_called_with)
      local line
      while IFS= read -r line; do [[ " ${line} " == *" $* "* ]] && ok=1; done <<<"${calls}"
      detail="$*" ;;
    to_have_been_last_called_with)
      [[ " $(tail -n 1 "${file}") " == *" $* "* ]] && ok=1
      detail="$*" ;;
    *) test::_expect_failed "expect_mock: unknown matcher '${matcher}'" ;;
  esac
  [[ -z "${negate}" ]] || ok=$((1 - ok))
  ((ok == 0)) || return 0
  test::_expect_failed "expected ${name} ${negate:+not }$(test::_words "${matcher}")${detail:+ ${detail}}" \
    "calls (${count}):" "$(sed 's/^/  /' <<<"${calls:-  (none)}")"
}

# The matchers on a value. Usage: test::_expect <label> <actual> [not] <matcher> [<expected>]
test::_expect() {
  local -r label="$1" actual="$2"
  shift 2
  local negate=""
  [[ "${1-}" != not ]] || { negate=not; shift; }
  local -r matcher="${1-}"
  shift || true
  local -r expected="${1-}"
  local ok=0
  case "${matcher}" in
    to_be) [[ "${actual}" == "${expected}" ]] && ok=1 ;;
    to_contain) [[ "${actual}" == *"${expected}"* ]] && ok=1 ;;
    to_match) [[ "${actual}" =~ ${expected} ]] && ok=1 ;;
    to_start_with) [[ "${actual}" == "${expected}"* ]] && ok=1 ;;
    to_end_with) [[ "${actual}" == *"${expected}" ]] && ok=1 ;;
    to_be_empty) [[ -z "${actual}" ]] && ok=1 ;;
    to_be_greater_than) ((actual > expected)) && ok=1 ;;
    to_be_less_than) ((actual < expected)) && ok=1 ;;
    to_be_at_least) ((actual >= expected)) && ok=1 ;;
    to_be_at_most) ((actual <= expected)) && ok=1 ;;
    to_have_lines)
      local n=0
      [[ -z "${actual}" ]] || n="$(printf '%s\n' "${actual}" | wc -l | tr -d ' ')"
      ((n == expected)) && ok=1 ;;
    *) test::_expect_failed "expect: unknown matcher '${matcher}'" ;;
  esac
  [[ -z "${negate}" ]] || ok=$((1 - ok))
  ((ok == 0)) || return 0
  local -r what="expected ${label} ${negate:+not }$(test::_words "${matcher}")"
  if [[ "${matcher}" == to_be && -z "${negate}" && ("${actual}" == *$'\n'* || "${expected}" == *$'\n'*) ]]; then
    test::_expect_failed "${what}:" \
      "$(diff -u --label expected --label actual <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}") | sed '1,2d')"
  elif [[ "${matcher}" == to_be_empty ]]; then
    test::_expect_failed "${what}" "but it was: ${actual}"
  else
    test::_expect_failed "${what}: ${expected}" "but it was: ${actual}"
  fi
}

# to_be_greater_than → "to be greater than"
test::_words() { echo "${1//_/ }"; }

test::_need_run() {
  [[ -n "${STATUS+set}" ]] && return 0
  test::_expect_failed "$1 needs a \`run <command>\` before it"
}

# Prints where and what, flags the case as failed, and ends it, even when
# errexit is off (if, ||, &&, !) or inside $( ).
test::_expect_failed() {
  local i=1
  while [[ "${FUNCNAME[i]:-}" == expect* || "${FUNCNAME[i]:-}" == test::* ]]; do i=$((i + 1)); done
  local -r file="${BASH_SOURCE[i]}" line="${BASH_LINENO[i - 1]}"
  {
    echo "${_TEST_RED}✗ ${file##*/}:${line}${_TEST_RESET}  $(sed -n "${line}{s/^[[:space:]]*//;p}" "${file}" 2>/dev/null)"
    while [[ "${FUNCNAME[i]:-}" != test_* && -n "${FUNCNAME[i + 1]:-}" && "${FUNCNAME[i + 1]}" != test::* ]]; do
      i=$((i + 1))
      echo "  called from ${BASH_SOURCE[i]##*/}:${BASH_LINENO[i - 1]} (${FUNCNAME[i]})"
    done
    [[ -z "${_TEST_LAST_RUN:-}" || -z "${_TEST_SHOW_RUN:-}" ]] || echo "  after: run ${_TEST_LAST_RUN}"
    local msg
    for msg in "$@"; do printf '%s\n' "${msg}" | sed 's/^/  /'; done
  } >&2
  [[ -z "${_TEST_FAIL_FLAG}" ]] || : >"${_TEST_FAIL_FLAG}"
  exit 1
}

# ── mock ─────────────────────────────────────────────────────────────────────

# Replaces <name> for the rest of the case, for calls from this shell (a
# function) and from child processes (an executable first on PATH). Records
# every call; see mock::calls.
# Usage: mock <name> [--exit N] [--stdout TEXT] [--stderr TEXT]
#        mock <name> <<'EOF'  (body run as bash, "$@" are the arguments)
mock() {
  local -r name="$1"
  shift
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
  local -r dir="${_TEST_TMP:?mock works inside a case}/.mocks/${name}"
  mkdir -p "${dir}"
  : >"${dir}/calls"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >>%q\n' "${dir}/calls"
    [[ -z "${out}" ]] || printf 'printf "%%s\\n" %q\n' "${out}"
    [[ -z "${err}" ]] || printf 'printf "%%s\\n" %q >&2\n' "${err}"
    [[ -z "${body}" ]] || printf '%s\n' "${body}"
    printf 'exit %s\n' "${code}"
  } >"${dir}/run"
  chmod +x "${dir}/run"
  ln -sf "${dir}/run" "${_TEST_TMP}/.bin/${name}"
  # shellcheck disable=SC2140
  eval "${name}() { \"${dir}/run\" \"\$@\"; }"
}

# The arguments of every call of a mock, one call per line.
mock::calls() { cat "${_TEST_TMP}/.mocks/$1/calls"; }
# How many times a mock was called.
mock::count() { wc -l <"${_TEST_TMP}/.mocks/$1/calls" | tr -d ' '; }

# ── Exit ─────────────────────────────────────────────────────────────────────

# A file that defines test_* cases but never calls test::main would pass
# without running them: fail it, and say why.
test::_next_on_exit() {
  local status=$?
  [[ "${BASHPID}" == "$$" ]] || exit "${status}"
  if ((status == 0 && _TEST_SUMMARY_DONE == 0)); then
    local _line fn missing=0
    while read -r _line fn; do
      [[ -n "${_TEST_RAN[${fn}]:-}" ]] || missing=$((missing + 1))
    done < <(test::_discover)
    if ((missing > 0)); then
      echo "✗ ${missing} test_* function(s) never ran: end the file with test::main" >&2
      status=1
    fi
  fi
  (exit "${status}")
  test::_on_exit
}
trap test::_next_on_exit EXIT
