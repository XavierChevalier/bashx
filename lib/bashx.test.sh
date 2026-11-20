#!/usr/bin/env bash
# Tests of the test API (bashx.sh), mostly through small test files run in a
# child bash, the way a project uses it.
source "$(dirname "${BASH_SOURCE[0]}")/bashx.sh"

BASHX_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bashx.sh"

# Writes a test file at <path> sourcing bashx.sh, followed by <body>.
write_suite() {
  local -r path="$1" body="$2"
  mkdir -p "$(dirname "${path}")"
  printf '#!/usr/bin/env bash\nsource "%s"\n%s\n' "${BASHX_SH}" "${body}" >"${path}"
}

# Runs <file>: output (colours off) in OUT, exit code in RC.
run_suite() {
  RC=0
  OUT="$(NO_COLOR=1 bash "$1" 2>&1)" || RC=$?
}

test_should_isolate_variables_functions_and_path_per_case() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/iso.test.sh" '
polluter() {
  export LEAK=polluted
  leaked_fn() { :; }
  PATH="/not-on-path:${PATH}"
  cd /
}
observer() {
  [[ -z "${LEAK:-}" ]] || { echo "env leaked"; return 1; }
  ! declare -F leaked_fn >/dev/null || { echo "function leaked"; return 1; }
  [[ ":${PATH}:" != *:/not-on-path:* ]] || { echo "PATH leaked"; return 1; }
  [[ "${PWD}" != / ]] || { echo "cwd leaked"; return 1; }
}
test::init
test::run "polluter" polluter
test::run "observer" observer
test::summary'
  run_suite "${tmp}/iso.test.sh"
  test::assert_equals 0 "${RC}" "${OUT}" || return 1
  test::assert_contains "${OUT}" "All 2 tests passed" || return 1
}

# errexit is on inside a case: the first failing command or assertion ends it.
test_should_fail_a_case_at_its_first_failure() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/mid.test.sh" '
bad_assert() { test::assert_equals 1 2; echo "kept"" going after an assertion"; }
bad_command() { false; echo "kept"" going after a command"; }
test::init
test::run "bad assert" bad_assert
test::run "bad command" bad_command
test::summary'
  run_suite "${tmp}/mid.test.sh"
  test::assert_equals 1 "${RC}" || return 1
  test::assert_not_contains "${OUT}" "kept going" || return 1
  test::assert_contains "${OUT}" "✗ Failed: 2 / Passed: 0 / Total: 2" || return 1
}

test_should_fail_the_file_when_the_summary_is_forgotten() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/nosummary.test.sh" '
test::init
test::run "fails" false'
  run_suite "${tmp}/nosummary.test.sh"
  test::assert_equals 1 "${RC}" || return 1
  test::assert_contains "${OUT}" "Failed: 1 / Passed: 0 / Total: 1" || return 1
}

# A library may chain its own EXIT handler in front of bashx's (and reset $?),
# and its subshells inherit that chain: the file must still fail once.
test_should_fail_the_file_once_through_a_chained_exit_trap() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/chain.test.sh" '
trap "true; $(trap -p EXIT | sed -E "s/^trap -- '"'"'(.*)'"'"' EXIT$/\1/")" EXIT
in_subshell() { ( exit 0 ); }
test::init
test::run "fails" false
test::run "subshell" in_subshell
test::summary'
  run_suite "${tmp}/chain.test.sh"
  test::assert_equals 1 "${RC}" || return 1
  test::assert_contains "${OUT}" "Failed: 1 / Passed: 1 / Total: 2" || return 1
  test::assert_equals 1 "$(grep -c '└' <<<"${OUT}")" "one summary: ${OUT}" || return 1
}

test_should_print_what_each_failed_assertion_expected() {
  local out row
  # shellcheck disable=SC2089,SC2090 # rows are split into words on purpose
  for row in \
    "assert_equals a b|Expected: a" \
    "assert_not_equals a a|Expected a value other than: a" \
    "assert_contains abc x|Expected 'abc' to contain 'x'" \
    "assert_not_contains abc b|Expected 'abc' not to contain 'b'" \
    "assert_matches abc ^b|Expected 'abc' to match /^b/" \
    "assert_exit_code 3 true|Expected exit code 3, got 0: true" \
    "assert_file_exists /nope|Expected file to exist: /nope" \
    "assert_file_not_exists /|Expected no file at: /"; do
    # shellcheck disable=SC2086 # the row holds the arguments
    out="$(NO_COLOR=1 test::${row%%|*} 2>&1)" && { echo "    ${row%%|*} passed" >&2; return 1; }
    test::assert_contains "${out}" "${row#*|}" || return 1
  done
  out="$(NO_COLOR=1 test::assert_equals a b "why it matters")" || true
  test::assert_contains "${out}" "Message:  why it matters" || return 1
}

test_should_pass_the_assertions_that_hold() {
  local dir
  dir="$(test::tmp_dir)"
  printf 'hello world' >"${dir}/f"
  printf 'hello world' >"${dir}/expected"
  test::assert_equals a a
  test::assert_not_equals a b
  test::assert_contains "hello world" "lo w"
  test::assert_not_contains "hello" "x"
  test::assert_matches "v1.2.3" '^v[0-9]+\.[0-9]+\.[0-9]+$'
  test::assert_exit_code 3 bash -c 'exit 3'
  test::assert_file_exists "${dir}/f"
  test::assert_file_not_exists "${dir}/nope"
  test::assert_file_contains "${dir}/f" "world"
  test::assert_file_not_contains "${dir}/f" "moon"
  test::assert_file_equals "${dir}/f" "hello world"
  test::assert_file_equals "${dir}/f" "${dir}/expected"
}

test_should_fail_file_assertions_on_a_missing_file() {
  local assertion
  for assertion in file_contains file_not_contains file_equals; do
    if "test::assert_${assertion}" /nope x >/dev/null; then
      echo "    assert_${assertion} passed on a missing file" >&2
      return 1
    fi
  done
}

test_should_skip_a_case_with_its_reason() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/skip.test.sh" '
skipper() { test::skip "needs docker"; echo "kept going"; }
test::init
test::run "skipped case" skipper
test::run "passing case" true
test::summary'
  run_suite "${tmp}/skip.test.sh"
  test::assert_equals 0 "${RC}" || return 1
  test::assert_contains "${OUT}" "skipped: needs docker" || return 1
  test::assert_contains "${OUT}" "○ skipped case (skipped)" || return 1
  test::assert_not_contains "${OUT}" "kept going" || return 1
  test::assert_contains "${OUT}" "All 2 tests passed / Skipped: 1" || return 1
}

test_should_replace_a_command_with_a_mock() {
  local bin
  bin="$(test::mock_command curl 'echo "mocked $*"')"
  test::assert_equals "mocked -s url" "$(PATH="${bin}:${PATH}" curl -s url)" || return 1
  test::mock_command wget 'exit 4' "${bin}" >/dev/null
  test::assert_exit_code 4 env PATH="${bin}:${PATH}" wget || return 1
}

test_should_give_each_case_its_own_tmp_dir_and_clean_it() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/tmp.test.sh" "
record() { test::tmp_dir >>'${tmp}/dirs'; test::tmp_dir >>'${tmp}/dirs'; }
shared() { [[ -d \"\$(test::suite_tmp_dir)\" ]] && test::suite_tmp_dir >'${tmp}/suite'; }
test::init
test::run one record
test::run two record
test::run shared shared
test::summary"
  run_suite "${tmp}/tmp.test.sh"
  test::assert_equals 0 "${RC}" "${OUT}" || return 1
  test::assert_equals 4 "$(sort -u "${tmp}/dirs" | wc -l)" "every dir is new" || return 1
  local dir
  while IFS= read -r dir; do
    test::assert_file_not_exists "${dir}" "removed with its case" || return 1
  done <"${tmp}/dirs"
  test::assert_file_not_exists "$(cat "${tmp}/suite")" "removed with the file" || return 1
}

test_should_refuse_a_suite_tmp_dir_before_init() {
  local out rc=0
  out="$(bash -c 'source "$1"; test::suite_tmp_dir' _ "${BASHX_SH}" 2>&1)" || rc=$?
  test::assert_equals 1 "${rc}" || return 1
  test::assert_contains "${out}" "needs test::init first" || return 1
}

test_should_write_the_counts_for_the_runner() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/counts.test.sh" '
skipper() { test::skip; }
test::init
test::run ok true
test::run ko false
test::run skip skipper
test::summary'
  BASHX_RESULT_FILE="${tmp}/result" bash "${tmp}/counts.test.sh" >/dev/null 2>&1 || true
  test::assert_equals "passed=1 failed=1 skipped=1 total=3" "$(grep -v duration "${tmp}/result" | paste -sd' ')" || return 1
  test::assert_matches "$(cat "${tmp}/result")" 'duration_ms=[0-9]+' || return 1
}

test_should_name_the_file_relative_to_its_git_root() {
  local tmp
  tmp="$(test::tmp_dir)"
  git -C "${tmp}" init -q
  write_suite "${tmp}/sub/name.test.sh" 'test::init'
  run_suite "${tmp}/sub/name.test.sh"
  test::assert_equals "🧪 ./sub/name.test.sh" "${OUT}" || return 1
}

test_should_honour_no_color() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/c.test.sh" 'test::init; test::run ok true; test::summary'
  run_suite "${tmp}/c.test.sh"
  test::assert_not_contains "${OUT}" $'\033[' || return 1
  test::assert_contains "$(env -u NO_COLOR bash "${tmp}/c.test.sh")" $'\033[0;32m✓' || return 1
}

# ── test::main, test::cases ─────────────────────────────────────────────────

test_should_run_the_test_functions_in_file_order() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/main.test.sh" '
test_should_come_first() { :; }
helper() { :; }
test_a_later_one() { :; }
test::main'
  run_suite "${tmp}/main.test.sh"
  test::assert_equals 0 "${RC}" "${OUT}" || return 1
  test::assert_matches "${OUT}" "✓ should come first.*✓ a later one" || return 1
  test::assert_not_contains "${OUT}" "helper" || return 1
  test::assert_contains "${OUT}" "All 2 tests passed" || return 1
}

test_should_not_run_twice_a_case_already_run() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/twice.test.sh" '
test_once() { echo ran >>"$1"; }
test::run "explicit" test_once "'"${tmp}"'/log"
test::main'
  run_suite "${tmp}/twice.test.sh"
  test::assert_equals 0 "${RC}" "${OUT}" || return 1
  test::assert_equals 1 "$(wc -l <"${tmp}/log")" || return 1
}

test_should_fail_a_file_whose_cases_never_ran() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/nomain.test.sh" '
test_one() { :; }
test_two() { :; }'
  run_suite "${tmp}/nomain.test.sh"
  test::assert_equals 1 "${RC}" || return 1
  test::assert_contains "${OUT}" "2 test_* function(s) never ran: end the file with test::main" || return 1
}

test_should_run_a_case_once_per_row_of_its_table() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/table.test.sh" '
test_should_join() { [[ "$1+$2" == "$3" ]]; }
test::cases test_should_join <<'"'EOF'"'
a          b     a+b
# a comment
  "x y"    z     "x y+z"

""         ""    +
EOF
test::main'
  run_suite "${tmp}/table.test.sh"
  test::assert_equals 0 "${RC}" "${OUT}" || return 1
  test::assert_contains "${OUT}" "✓ should join [a b a+b]" || return 1
  test::assert_contains "${OUT}" "✓ should join [x y z x y+z]" || return 1
  test::assert_contains "${OUT}" "All 3 tests passed" || return 1
}

# ── assert ───────────────────────────────────────────────────────────────────

test_should_pass_the_asserts_that_hold() {
  local dir
  dir="$(test::tmp_dir)"
  printf 'port=80\n' >"${dir}/conf"
  printf 'port=80\n' >"${dir}/golden"
  assert a == a
  assert a != b
  assert "hello world" contains "lo w"
  assert "hello" !contains x
  assert v1.2.3 matches '^v[0-9]+\.[0-9]+\.[0-9]+$'
  assert "Usage: x" starts_with "Usage:"
  assert "file.sh" ends_with ".sh"
  assert "" empty
  assert x !empty
  assert 3 -eq 3
  assert 3 -ne 4
  assert -1 -lt 0
  assert 3 -le 3
  assert 10 -gt 9
  assert 3 -ge 3
  assert "${dir}/conf" is_file
  assert "${dir}" is_dir
  assert "${dir}" exists
  assert "${dir}/nope" !exists
  assert "${dir}/conf" has "port=80"
  assert "${dir}/conf" !has "port=8080"
  assert "${dir}/conf" same_as "port=80"
  assert "${dir}/conf" same_as "${dir}/golden"
  test::assert a == a
}

# The failure output of one assert, with the case's failure flag off so that
# it does not fail this case.
assert_output() {
  _TEST_FAIL_FLAG="" _TEST_RED="" _TEST_RESET="" assert "$@" 2>&1
}

test_should_print_what_each_failed_assert_expected() {
  local dir row out
  dir="$(test::tmp_dir)"
  printf 'port=80\n' >"${dir}/conf"
  # shellcheck disable=SC2089,SC2090 # rows are split into words on purpose
  for row in \
    "a == b|expected: b" \
    "a != a|!=: a" \
    "abc contains x|contains: x" \
    "abc !contains b|!contains: b" \
    "abc matches ^b|matches: ^b" \
    "abc starts_with b|starts_with: b" \
    "abc ends_with b|ends_with: b" \
    "x empty|empty, but got: x" \
    "3 -gt 4|-gt: 4" \
    "x -gt 4|-gt compares integers" \
    "/nope is_file|is_file, but got: /nope" \
    "/ !exists|!exists, but got: /" \
    "${dir}/conf has 8080|has: 8080" \
    "/nope has x|no file at: /nope" \
    "a bogus b|unknown operator 'bogus'"; do
    # shellcheck disable=SC2086 # the row holds the arguments
    out="$(assert_output ${row%%|*})" || true
    test::assert_contains "${out}" "${row#*|}" || return 1
    test::assert_contains "${out}" "✗ bashx.test.sh:" "the line of the assert" || return 1
  done
}

test_should_show_a_diff_for_multiline_values() {
  local out
  out="$(assert_output $'a\nb\nc' == $'a\nB\nc')" || true
  test::assert_contains "${out}" "diff (- expected, + actual):" || return 1
  test::assert_contains "${out}" $'-B\n  +b' || return 1
}

test_should_name_the_helper_and_the_case_of_a_failed_assert() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/where.test.sh" '
check_even() { assert $(($1 % 2)) == 0; }
test_should_be_even() {
  check_even 3
}
test::main'
  run_suite "${tmp}/where.test.sh"
  test::assert_equals 1 "${RC}" || return 1
  test::assert_contains "${OUT}" "✗ where.test.sh:4  check_even() { assert \$((\$1 % 2)) == 0; }" || return 1
  test::assert_contains "${OUT}" "called from where.test.sh:6 (test_should_be_even)" || return 1
}

# errexit is off under if, ||, && and ! and does not reach $( ): a failed
# assert must fail the case anyway.
test_should_fail_the_case_wherever_an_assert_fails() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/anywhere.test.sh" '
check() { assert "$1" == ok; }
test_under_if() { if check ko; then :; fi; echo "kept"" going"; }
test_under_or() { check ko || true; echo "kept"" going"; }
test_in_a_substitution() { local x; x="$(check ko)"; echo "after the substitution"; }
test::main'
  run_suite "${tmp}/anywhere.test.sh"
  test::assert_equals 1 "${RC}" || return 1
  test::assert_contains "${OUT}" "Failed: 3 / Passed: 0 / Total: 3" || return 1
  test::assert_not_contains "${OUT}" "kept going" || return 1
}

# ── capture ──────────────────────────────────────────────────────────────────

test_should_capture_the_status_and_both_outputs() {
  speak() { echo "out $1"; echo "err $1" >&2; return "$2"; }
  capture speak hello 3
  test::assert_equals 3 "${STATUS}" || return 1
  test::assert_equals "out hello" "${STDOUT}" || return 1
  test::assert_equals "err hello" "${STDERR}" || return 1
  capture true
  test::assert_equals "0||" "${STATUS}|${STDOUT}|${STDERR}" || return 1
}

# The bash 5.0 trap: `check || return` in a function that is the whole of
# a subshell. Its status must come through.
test_should_capture_the_status_of_a_bare_return() {
  refuse() { false || return; echo "unreachable"; }
  capture refuse
  test::assert_equals 1 "${STATUS}" || return 1
  test::assert_equals "" "${STDOUT}" || return 1
}

test_should_isolate_the_case_from_a_captured_command() {
  change() { MARK=changed; exit 4; }
  MARK=kept
  capture change
  test::assert_equals "4 kept" "${STATUS} ${MARK}" || return 1
}

# ── mock ─────────────────────────────────────────────────────────────────────

test_should_replace_a_command_and_record_its_calls() {
  mock curl --stdout '{"ok":true}' --stderr "warn" --exit 3
  local out rc=0
  out="$(curl -s https://a 2>&1)" || rc=$?
  test::assert_equals 3 "${rc}" || return 1
  test::assert_equals $'{"ok":true}\nwarn' "${out}" || return 1
  bash -c 'curl --from child >/dev/null 2>&1' || true
  test::assert_equals 2 "$(mock::count curl)" || return 1
  test::assert_equals $'-s https://a\n--from child' "$(mock::calls curl)" || return 1
}

test_should_run_the_body_given_to_a_mock() {
  mock git <<'EOF'
[[ "$1" == rev-parse ]] && echo abc123
EOF
  test::assert_equals abc123 "$(git rev-parse HEAD)" || return 1
  test::assert_equals abc123 "$(bash -c 'git rev-parse HEAD')" "from a child process" || return 1
}

test_should_replace_a_function_of_the_code_under_test() {
  api::fetch() { echo real; }
  report() { api::fetch; }
  mock api::fetch --stdout fake
  test::assert_equals fake "$(report)" || return 1
  test::assert_equals 1 "$(mock::count api::fetch)" || return 1
}

test_should_refuse_a_mock_outside_a_case() {
  local out rc=0
  out="$(_TEST_TMP="" mock curl 2>&1)" || rc=$?
  test::assert_equals 2 "${rc}" || return 1
  test::assert_contains "${out}" "works inside a case only" || return 1
}

# ── hooks, output, filter ────────────────────────────────────────────────────

test_should_call_the_hooks_around_each_case() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/hooks.test.sh" '
LOG="'"${tmp}"'/log"
before_all() { echo "before all" >>"${LOG}"; }
before_each() { echo "before" >>"${LOG}"; SEEN=yes; }
after_each() { echo "after" >>"${LOG}"; }
test_one() { [[ "${SEEN}" == yes ]] && echo "one" >>"${LOG}"; }
test_two() { echo "two" >>"${LOG}"; false; }
test::main'
  run_suite "${tmp}/hooks.test.sh"
  test::assert_equals 1 "${RC}" || return 1
  test::assert_equals "before all,before,one,after,before,two,after" "$(paste -sd, "${tmp}/log")" \
    "after_each runs after a failure too" || return 1
}

test_should_show_the_output_of_failed_cases_only() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/quiet.test.sh" '
test_passes() { echo "said by a passing case"; }
test_fails() { echo "said by a failing case"; false; }
test::main'
  run_suite "${tmp}/quiet.test.sh"
  test::assert_not_contains "${OUT}" "said by a passing case" || return 1
  test::assert_contains "${OUT}" "│    said by a failing case" || return 1
  OUT="$(BASHX_VERBOSE=1 NO_COLOR=1 bash "${tmp}/quiet.test.sh" 2>&1)" || true
  test::assert_contains "${OUT}" "│    said by a passing case" "verbose" || return 1
}

test_should_run_only_the_cases_matching_the_filter() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/filter.test.sh" '
test_should_keep_this() { :; }
test_should_drop_that() { false; }
test::main'
  OUT="$(BASHX_FILTER="keep" NO_COLOR=1 bash "${tmp}/filter.test.sh" 2>&1)" || return 1
  test::assert_contains "${OUT}" "✓ should keep this" || return 1
  test::assert_not_contains "${OUT}" "drop" || return 1
  test::assert_contains "${OUT}" "All 1 tests passed" || return 1
}

test_should_close_the_stdin_of_a_case() {
  local tmp
  tmp="$(test::tmp_dir)"
  write_suite "${tmp}/stdin.test.sh" '
test_reads() { ! read -r _; }
test_after() { :; }
test::main'
  OUT="$(echo "a line" | NO_COLOR=1 bash "${tmp}/stdin.test.sh" 2>&1)" || return 1
  test::assert_contains "${OUT}" "All 2 tests passed" || return 1
}

test::main
