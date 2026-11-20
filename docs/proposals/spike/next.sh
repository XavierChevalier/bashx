#!/usr/bin/env bash
# Spike of the API proposed in docs/proposals/api-v2.md. Not a release: it
# loads lib/bashx.sh and adds the new verbs on top, to try them on real files.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/next.sh"
#   test_should_add() { assert "$(calc::add 2 3)" == 5; }
#   # nothing else: the cases are found and run when the file ends.

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

# Runs every test_* function, then the summary. Called by the EXIT trap when
# the file never called test::run itself.
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

# ── capture ──────────────────────────────────────────────────────────────────

# Runs a command and keeps what it did, without stopping the case:
# STATUS, STDOUT and STDERR (trailing newlines dropped, as with $( )).
# Usage: capture <command> [args...]
# shellcheck disable=SC2034 # read by the test file
capture() {
  local -r dir="$(mktemp -d "${_TEST_TMP:-${TMPDIR:-/tmp}}/capture.XXXXXX")"
  set +e
  ( "$@" ) >"${dir}/out" 2>"${dir}/err" </dev/null
  STATUS=$?
  set -e
  STDOUT="$(<"${dir}/out")"
  STDERR="$(<"${dir}/err")"
}
test::capture() { capture "$@"; }

# ── assert ───────────────────────────────────────────────────────────────────

# One assertion, read like a sentence: <actual> <operator> [<expected>].
# Operators: == != contains !contains matches starts_with ends_with
#            empty !empty  -eq -ne -lt -le -gt -ge
# Files:     assert <path> is_file | !exists | has <text> | !has <text> | same_as <expected or golden file>
assert() {
  local actual="${1-}" op="${2-}" expected="${3-}" ok=1
  case "${op}" in
    ==) [[ "${actual}" == "${expected}" ]] ;;
    !=) [[ "${actual}" != "${expected}" ]] ;;
    contains) [[ "${actual}" == *"${expected}"* ]] ;;
    !contains) [[ "${actual}" != *"${expected}"* ]] ;;
    matches) [[ "${actual}" =~ ${expected} ]] ;;
    starts_with) [[ "${actual}" == "${expected}"* ]] ;;
    ends_with) [[ "${actual}" == *"${expected}" ]] ;;
    empty) [[ -z "${actual}" ]] ;;
    !empty) [[ -n "${actual}" ]] ;;
    -eq | -ne | -lt | -le | -gt | -ge) test "${actual}" "${op}" "${expected}" ;;
    is_file) [[ -f "${actual}" ]] ;;
    exists) [[ -e "${actual}" ]] ;;
    !exists) [[ ! -e "${actual}" ]] ;;
    has) [[ -f "${actual}" && "$(<"${actual}")" == *"${expected}"* ]] ;;
    !has) [[ -f "${actual}" && "$(<"${actual}")" != *"${expected}"* ]] ;;
    same_as)
      [[ ! -f "${expected}" ]] || expected="$(<"${expected}")"
      [[ -f "${actual}" && "$(<"${actual}")" == "${expected}" ]] ;;
    *) echo "assert: unknown operator '${op}'" >&2; false ;;
  esac || ok=0
  ((ok == 0)) || return 0
  test::_assert_failed "${op}" "${actual}" "${expected}"
}
test::assert() { assert "$@"; }

# Prints where and what, flags the case as failed, and ends it, even when
# errexit is off (if, ||, &&, !) or inside $( ).
test::_assert_failed() {
  local -r op="$1" actual="$2" expected="$3"
  local i=1
  while [[ "${FUNCNAME[i]:-}" == assert || "${FUNCNAME[i]:-}" == test::* ]]; do i=$((i + 1)); done
  local -r file="${BASH_SOURCE[i]}" line="${BASH_LINENO[i - 1]}"
  {
    echo "${_TEST_RED}✗ ${file##*/}:${line}${_TEST_RESET}  $(sed -n "${line}{s/^[[:space:]]*//;p}" "${file}" 2>/dev/null)"
    # The call chain up to the case, when the assertion is in a helper.
    while [[ "${FUNCNAME[i]:-}" != test_* && -n "${FUNCNAME[i + 1]:-}" && "${FUNCNAME[i + 1]}" != test::* ]]; do
      i=$((i + 1))
      echo "  called from ${BASH_SOURCE[i]##*/}:${BASH_LINENO[i - 1]} (${FUNCNAME[i]})"
    done
    case "${op}" in
      == | same_as)
        if [[ "${actual}" == *$'\n'* || "${expected}" == *$'\n'* ]]; then
          diff -u --label expected --label actual <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}") | sed '1,2d; s/^/  /'
        else
          echo "  expected: ${expected}"
          echo "  actual:   ${actual}"
        fi ;;
      empty | !empty | is_file | exists | !exists) echo "  value: ${actual}" ;;
      *) echo "  actual:   ${actual}"; echo "  ${op}: ${expected}" ;;
    esac
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

test::_next_on_exit() {
  local status=$?
  [[ "${BASHPID}" == "$$" ]] || exit "${status}"
  if ((status == 0 && _TEST_SUMMARY_DONE == 0)); then
    test::main || status=1
  fi
  (exit "${status}")
  test::_on_exit
}
trap test::_next_on_exit EXIT
