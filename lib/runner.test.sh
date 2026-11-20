#!/usr/bin/env bash
# Tests of the runner (bashx test).
source "$(dirname "${BASH_SOURCE[0]}")/bashx.sh"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${LIB_DIR}/runner.sh"

# Writes an executable test file <path> running <body>.
write_stub() {
  local -r path="$1" body="$2"
  mkdir -p "$(dirname "${path}")"
  printf '%s\n' "#!/usr/bin/env bash" "set -euo pipefail" "${body}" >"${path}"
  chmod +x "${path}"
}

# A test file using the bashx API, with one passing case per name given.
write_bashx_file() {
  local -r path="$1"
  shift
  local body='source "${BASHX_LIB}/bashx.sh"'$'\n''test::init'
  local name
  for name in "$@"; do body+=$'\n'"test::run \"${name}\" true"; done
  write_stub "${path}" "${body}"$'\n''test::summary'
}

run_runner() {
  local -r root="$1"
  shift
  BASHX_PLAIN_OUTPUT=1 bash "${RUNNER}" --jobs=2 "$@" "${root}"
}

test_should_run_every_test_file_under_the_root() {
  local tmp out
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/a.test.sh" 'echo ran-a'
  write_stub "${tmp}/sub/b.unit.test.sh" 'echo ran-b'
  write_stub "${tmp}/c.sh" 'echo ran-c'
  write_stub "${tmp}/node_modules/d.test.sh" 'echo ran-d'
  write_stub "${tmp}/.git/e.test.sh" 'echo ran-e'
  out="$(run_runner "${tmp}" 2>&1)" || return 1
  test::assert_contains "${out}" "ran-a" || return 1
  test::assert_contains "${out}" "ran-b" || return 1
  test::assert_not_contains "${out}" "ran-c" "not a test file" || return 1
  test::assert_not_contains "${out}" "ran-d" "dependencies are skipped" || return 1
  test::assert_not_contains "${out}" "ran-e" || return 1
}

# A submodule or a vendored clone (bashx itself, often) has its own tests.
test_should_leave_nested_repositories_out() {
  local tmp out
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/mine.test.sh" 'echo ran-mine'
  write_stub "${tmp}/vendor/lib/theirs.test.sh" 'echo ran-theirs'
  git -C "${tmp}/vendor/lib" init -q
  write_stub "${tmp}/vendor/plain/copied.test.sh" 'echo ran-copied'
  mkdir -p "${tmp}/sub" && echo "gitdir: ../.git/modules/sub" >"${tmp}/sub/.git"
  write_stub "${tmp}/sub/module.test.sh" 'echo ran-module'
  out="$(run_runner "${tmp}" 2>&1)" || return 1
  test::assert_contains "${out}" "ran-mine" || return 1
  test::assert_contains "${out}" "ran-copied" "a plain copy is part of the project" || return 1
  test::assert_not_contains "${out}" "ran-theirs" "a nested clone" || return 1
  test::assert_not_contains "${out}" "ran-module" "a submodule (.git file)" || return 1
}

test_should_run_only_the_matching_kind() {
  local tmp out
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/a.unit.test.sh" 'echo ran-unit'
  write_stub "${tmp}/b.integration.test.sh" 'echo ran-integration'
  write_stub "${tmp}/c.test.sh" 'echo ran-plain'
  out="$(run_runner "${tmp}" --kind=integration 2>&1)" || return 1
  test::assert_contains "${out}" "ran-integration" || return 1
  test::assert_not_contains "${out}" "ran-unit" || return 1
  test::assert_not_contains "${out}" "ran-plain" || return 1
}

test_should_fail_when_no_test_file_is_found() {
  local tmp out rc=0
  tmp="$(test::tmp_dir)"
  out="$(run_runner "${tmp}" 2>&1)" || rc=$?
  test::assert_equals 1 "${rc}" || return 1
  test::assert_contains "${out}" "No test files (*.test.sh) under" || return 1
}

test_should_run_each_file_from_its_own_directory() {
  local tmp out
  tmp="$(test::tmp_dir)"
  mkdir -p "${tmp}/sub"
  echo 'greet() { echo hello; }' >"${tmp}/sub/lib.sh"
  write_stub "${tmp}/sub/lib.test.sh" 'source ./lib.sh; greet'
  out="$(run_runner "${tmp}" 2>&1)" || return 1
  test::assert_contains "${out}" "hello" || return 1
}

test_should_let_the_exit_code_win_over_summary_text() {
  local tmp out rc=0
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/liar.test.sh" 'echo "All 99 tests passed"; exit 1'
  out="$(run_runner "${tmp}" 2>&1)" || rc=$?
  test::assert_equals 1 "${rc}" || return 1
  test::assert_contains "${out}" "0 passed, 1 failed, 1 total" || return 1
}

test_should_report_all_failures_in_a_parallel_run() {
  local tmp out rc=0
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/ok.test.sh" "exit 0"
  write_stub "${tmp}/fail-a.test.sh" "exit 1"
  write_stub "${tmp}/fail-b.test.sh" "exit 1"
  out="$(run_runner "${tmp}" --jobs=3 2>&1)" || rc=$?
  test::assert_equals 1 "${rc}" || return 1
  test::assert_contains "${out}" "Failed test files:
  • fail-a.test.sh
  • fail-b.test.sh" || return 1
}

test_should_count_cases_from_the_result_file() {
  local tmp out
  tmp="$(test::tmp_dir)"
  write_bashx_file "${tmp}/counted.test.sh" one two
  write_stub "${tmp}/plain.test.sh" 'echo "no api"'
  out="$(run_runner "${tmp}" 2>&1)" || return 1
  test::assert_contains "${out}" "📊 Test Summary: 3 passed, 0 failed, 3 total (" || return 1
}

test_should_count_skipped_cases() {
  local tmp out
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/skips.test.sh" 'source "${BASHX_LIB}/bashx.sh"
skipper() { test::skip "not today"; }
test::init
test::run "ok" true
test::run "skipped" skipper
test::summary'
  out="$(run_runner "${tmp}" 2>&1)" || return 1
  test::assert_contains "${out}" "1 passed, 0 failed, 1 skipped, 2 total" || return 1
}

test_should_skip_a_file_whose_required_command_is_missing() {
  local tmp out
  tmp="$(test::tmp_dir)"
  printf '%s\n' '#!/usr/bin/env bash' '# @requires bash definitely-not-a-command-xyz' 'echo ran-needs' >"${tmp}/needs.test.sh"
  printf '%s\n' '#!/usr/bin/env bash' '# Needs bash only.' '# @requires bash' '' 'echo ran-has' >"${tmp}/has.test.sh"
  out="$(run_runner "${tmp}" 2>&1)" || return 1
  test::assert_not_contains "${out}" "ran-needs" || return 1
  test::assert_contains "${out}" "Skipped (requires definitely-not-a-command-xyz)" || return 1
  test::assert_contains "${out}" "ran-has" || return 1
  test::assert_contains "${out}" "1 passed, 0 failed, 1 skipped, 1 total" || return 1
}

test_should_stream_results_in_completion_order() {
  local tmp out slow fast
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/a-slow.test.sh" 'sleep 1; echo SLOW-DONE'
  write_stub "${tmp}/b-fast.test.sh" 'echo FAST-DONE'
  out="$(run_runner "${tmp}" 2>&1)" || return 1
  fast="$(grep -n FAST-DONE <<<"${out}" | cut -d: -f1)"
  slow="$(grep -n SLOW-DONE <<<"${out}" | cut -d: -f1)"
  ((fast < slow)) || { echo "    fast file must stream first" >&2; return 1; }
}

test_should_time_out_a_hung_file_and_keep_the_suite_going() {
  local tmp out rc=0 start
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/hangs.test.sh" 'sleep 120'
  write_stub "${tmp}/ok.test.sh" 'exit 0'
  start="${SECONDS}"
  out="$(run_runner "${tmp}" --timeout=1 2>&1)" || rc=$?
  test::assert_equals 1 "${rc}" || return 1
  test::assert_contains "${out}" "TIMEOUT after 1s: killed hangs.test.sh" || return 1
  test::assert_contains "${out}" "1 passed, 1 failed" || return 1
  ((SECONDS - start < 30)) || { echo "    the deadline did not cut the file" >&2; return 1; }
}

# Alive = still the leaked `sleep 30` (a pid can be reused) and not a zombie
# (a killed orphan may wait to be reaped).
process_alive() {
  local info
  info="$(ps -o stat=,args= -p "$1" 2>/dev/null)" || return 1
  [[ -n "${info}" && "${info}" != Z* && "${info}" == *"sleep 30"* ]]
}

test_should_not_let_a_leaked_child_outlive_the_file() {
  local tmp pid i
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/leaky.test.sh" "sleep 30 &"$'\n'"echo \$! >'${tmp}/leaked.pid'"
  run_runner "${tmp}" >/dev/null 2>&1 || return 1
  pid="$(cat "${tmp}/leaked.pid")"
  for ((i = 0; i < 50; i++)); do
    process_alive "${pid}" || return 0
    sleep 0.1
  done
  kill -KILL "${pid}" 2>/dev/null || true
  echo "    leaked child ${pid} survived the runner" >&2
  return 1
}

test_should_emit_no_cursor_escapes_outside_a_tty() {
  local tmp out
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/ok.test.sh" 'exit 0'
  out="$(bash "${RUNNER}" "${tmp}" 2>&1)" || return 1
  test::assert_not_contains "${out}" $'\033[?25l' || return 1
  test::assert_not_contains "${out}" $'\033[1A' || return 1
}

test_should_run_every_file_in_exactly_one_shard() {
  local tmp all="" i
  tmp="$(test::tmp_dir)"
  for i in 1 2 3 4 5; do write_stub "${tmp}/f${i}.test.sh" "echo ran-f${i}"; done
  for i in 1 2 3; do all+="$(run_runner "${tmp}" --shard="${i}/3" 2>&1 | grep -o 'ran-f[0-9]')"$'\n'; done
  test::assert_equals "ran-f1 ran-f2 ran-f3 ran-f4 ran-f5" "$(grep . <<<"${all}" | sort | paste -sd' ')" || return 1
}

test_should_refuse_bad_options() {
  local tmp opt rc
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/ok.test.sh" 'exit 0'
  for opt in --shard=4/3 --shard=0/2 --shard=x --jobs=0 --timeout=x --nope; do
    rc=0
    run_runner "${tmp}" "${opt}" >/dev/null 2>&1 || rc=$?
    test::assert_equals 2 "${rc}" "exit code of ${opt}" || return 1
  done
  rc=0
  bash "${RUNNER}" "${tmp}/missing" >/dev/null 2>&1 || rc=$?
  test::assert_equals 2 "${rc}" "a missing root" || return 1
}

test_should_balance_shards_on_recorded_durations() {
  local tmp shard1 shard2
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/a.test.sh" 'echo ran-a'
  write_stub "${tmp}/b.test.sh" 'echo ran-b'
  write_stub "${tmp}/c.test.sh" 'echo ran-c'
  # a is long: alone in shard 1; b and c share shard 2.
  mkdir -p "${tmp}/.bashx"
  printf '10\ta.test.sh\n1\tb.test.sh\n1\tc.test.sh\n' >"${tmp}/.bashx/durations.tsv"
  shard1="$(run_runner "${tmp}" --shard=1/2 2>&1 | grep -o 'ran-[a-c]' | paste -sd' ')"
  shard2="$(run_runner "${tmp}" --shard=2/2 2>&1 | grep -o 'ran-[a-c]' | sort | paste -sd' ')"
  test::assert_equals "ran-a|ran-b ran-c" "${shard1}|${shard2}" || return 1
}

test_should_start_the_longest_file_first() {
  local tmp out
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/a.test.sh" 'echo ran-a'
  write_stub "${tmp}/z.test.sh" 'echo ran-z'
  printf '5\tz.test.sh\n1\ta.test.sh\n' >"${tmp}/durations.tsv"
  out="$(BASHX_PLAIN_OUTPUT=1 bash "${RUNNER}" --jobs=1 --durations="${tmp}/durations.tsv" "${tmp}" 2>&1)" || return 1
  test::assert_equals "ran-z ran-a" "$(grep -o 'ran-[az]' <<<"${out}" | paste -sd' ')" || return 1
}

test_should_record_each_file_duration() {
  local tmp out
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/a.test.sh" 'exit 0'
  write_stub "${tmp}/sub/b.test.sh" 'exit 0'
  out="$(run_runner "${tmp}" --record-durations="${tmp}/out/durations.tsv" 2>&1)" || return 1
  test::assert_contains "${out}" "Durations written to ${tmp}/out/durations.tsv" || return 1
  test::assert_matches "$(cat "${tmp}/out/durations.tsv")" $'^[0-9]+\.[0-9]\ta\.test\.sh\n[0-9]+\.[0-9]\tsub/b\.test\.sh$' || return 1
}

test_should_write_markdown_json_and_junit_reports() {
  local tmp format
  tmp="$(test::tmp_dir)"
  write_stub "${tmp}/tests/ok.test.sh" 'echo "say \"hi\""'
  write_stub "${tmp}/tests/bad.test.sh" 'exit 1'
  for format in markdown json junit; do
    (cd "${tmp}" && run_runner tests --report="${format}" >/dev/null 2>&1) || true
  done
  test::assert_file_contains "${tmp}/test_report.markdown" "| 1 | 1 | 0 | 2 | 2 |" || return 1
  test::assert_file_contains "${tmp}/test_report.markdown" '- `bad.test.sh`' || return 1
  test::assert_file_contains "${tmp}/test_report.json" '"summary": {"passed": 1, "failed": 1, "skipped": 0, "total": 2, "files": 2}' || return 1
  test::assert_file_contains "${tmp}/test_report.json" '"failed_files": ["bad.test.sh"]' || return 1
  test::assert_file_contains "${tmp}/test_report.json" 'say \"hi\"' || return 1
  test::assert_file_contains "${tmp}/test_report.junit" 'tests="2" failures="1" skipped="0"' || return 1
  test::assert_file_contains "${tmp}/test_report.junit" '<testcase classname="bashx" name="bad.test.sh">' || return 1
  local rc=0
  (cd "${tmp}" && run_runner tests --report=yaml >/dev/null 2>&1) || rc=$?
  test::assert_equals 1 "${rc}" "unknown format" || return 1
}

test_should_measure_the_coverage_of_scripts_the_tests_run() {
  local tmp out
  tmp="$(test::tmp_dir)"
  printf '%s\n' '#!/usr/bin/env bash' 'used() {' '  echo used' '}' 'unused() {' '  echo unused' '}' >"${tmp}/lib.sh"
  write_stub "${tmp}/lib.test.sh" 'source ./lib.sh; used'
  out="$(run_runner "${tmp}" --coverage="${tmp}/cov" 2>&1)" || return 1
  test::assert_contains "${out}" "🧭 Coverage: covered=1 coverable=2 pct=50.0" || return 1
  test::assert_equals "lib.sh	3" "$(grep '^lib.sh' "${tmp}/cov/covered.tsv")" || return 1
  test::assert_file_not_exists "${tmp}/cov/traces" || return 1
}

test_should_print_its_help() {
  test::assert_contains "$(bash "${RUNNER}" --help)" "Usage: bashx test [options] [<root>]" || return 1
}

test::init
test::run "should run every test file under the root" test_should_run_every_test_file_under_the_root
test::run "should leave nested repositories out" test_should_leave_nested_repositories_out
test::run "should run only the matching kind" test_should_run_only_the_matching_kind
test::run "should fail when no test file is found" test_should_fail_when_no_test_file_is_found
test::run "should run each file from its own directory" test_should_run_each_file_from_its_own_directory
test::run "should let the exit code win over summary text" test_should_let_the_exit_code_win_over_summary_text
test::run "should report all failures in a parallel run" test_should_report_all_failures_in_a_parallel_run
test::run "should count cases from the result file" test_should_count_cases_from_the_result_file
test::run "should count skipped cases" test_should_count_skipped_cases
test::run "should skip a file whose required command is missing" test_should_skip_a_file_whose_required_command_is_missing
test::run "should stream results in completion order" test_should_stream_results_in_completion_order
test::run "should time out a hung file and keep the suite going" test_should_time_out_a_hung_file_and_keep_the_suite_going
test::run "should not let a leaked child outlive the file" test_should_not_let_a_leaked_child_outlive_the_file
test::run "should emit no cursor escapes outside a tty" test_should_emit_no_cursor_escapes_outside_a_tty
test::run "should run every file in exactly one shard" test_should_run_every_file_in_exactly_one_shard
test::run "should refuse bad options" test_should_refuse_bad_options
test::run "should balance shards on recorded durations" test_should_balance_shards_on_recorded_durations
test::run "should start the longest file first" test_should_start_the_longest_file_first
test::run "should record each file duration" test_should_record_each_file_duration
test::run "should write markdown json and junit reports" test_should_write_markdown_json_and_junit_reports
test::run "should measure the coverage of scripts the tests run" test_should_measure_the_coverage_of_scripts_the_tests_run
test::run "should print its help" test_should_print_its_help
test::summary
