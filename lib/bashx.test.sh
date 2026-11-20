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
bad_assert() { test::assert_equals 1 2; echo "kept going after an assertion"; }
bad_command() { false; echo "kept going after a command"; }
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

test::init
test::run "should isolate variables functions and path per case" test_should_isolate_variables_functions_and_path_per_case
test::run "should fail a case at its first failure" test_should_fail_a_case_at_its_first_failure
test::run "should fail the file when the summary is forgotten" test_should_fail_the_file_when_the_summary_is_forgotten
test::run "should fail the file once through a chained exit trap" test_should_fail_the_file_once_through_a_chained_exit_trap
test::run "should print what each failed assertion expected" test_should_print_what_each_failed_assertion_expected
test::run "should pass the assertions that hold" test_should_pass_the_assertions_that_hold
test::run "should fail file assertions on a missing file" test_should_fail_file_assertions_on_a_missing_file
test::run "should skip a case with its reason" test_should_skip_a_case_with_its_reason
test::run "should replace a command with a mock" test_should_replace_a_command_with_a_mock
test::run "should give each case its own tmp dir and clean it" test_should_give_each_case_its_own_tmp_dir_and_clean_it
test::run "should refuse a suite tmp dir before init" test_should_refuse_a_suite_tmp_dir_before_init
test::run "should write the counts for the runner" test_should_write_the_counts_for_the_runner
test::run "should name the file relative to its git root" test_should_name_the_file_relative_to_its_git_root
test::run "should honour no color" test_should_honour_no_color
test::summary
