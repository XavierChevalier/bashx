#!/usr/bin/env bash
# Tests of the bashx command, as a user runs it.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/bashx.sh"

BASHX="${BASHX_BIN:-bashx}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"

test_should_list_its_commands() {
  local out
  out="$("${BASHX}")"
  assert "${out}" contains "Usage: bashx <command> [options]"
  assert "$("${BASHX}" --help)" == "${out}"
  assert "${out}" contains "mutate <script.sh>..."
}

test_should_print_its_version() {
  assert "$("${BASHX}" version)" matches '^bashx [0-9]+\.[0-9]+\.[0-9]+$'
  assert "$("${BASHX}" --version)" == "$("${BASHX}" version)"
}

# The test API is in the binary: `bashx lib` writes it once to the cache and
# prints where; test files source it from there.
test_should_give_the_test_api_from_the_binary() {
  local cache dir
  cache="$(test::tmp_dir)"
  dir="$(BASHX_LIB="" XDG_CACHE_HOME="${cache}" "${BASHX}" lib)"
  assert "${dir}/bashx.sh" same_as "${LIB}/bashx.sh"
  assert "${dir}/coverage-trace.bash" same_as "${LIB}/coverage-trace.bash"
  assert "$(BASHX_LIB="" XDG_CACHE_HOME="${cache}" "${BASHX}" lib)" == "${dir}"  # once
  assert "$(BASHX_LIB=/somewhere "${BASHX}" lib)" == "/somewhere"  # overridden
}

test_should_refuse_an_unknown_command() {
  local out rc=0
  out="$("${BASHX}" frobnicate 2>&1)" || rc=$?
  assert "${rc}" == 2
  assert "${out}" contains "bashx: unknown command 'frobnicate'"
}

# A test file can call the bashx that runs it.
test_should_run_the_tests_of_a_project() {
  local dir out
  dir="$(test::tmp_dir)"
  printf '%s\n' 'source "${BASHX_LIB}/bashx.sh"' 'test::init' 'test::run "should pass" true' \
    'test::run "should know its bashx" test -x "${BASHX_BIN}"' 'test::summary' >"${dir}/a.test.sh"
  out="$(BASHX_PLAIN_OUTPUT=1 BASHX_LIB="" "${BASHX}" test "${dir}" 2>&1)"
  assert "${out}" contains "2 passed, 0 failed, 2 total"
}

test_should_hand_mutate_and_coverage_their_arguments() {
  assert "$("${BASHX}" mutate -h)" contains "Usage: bashx mutate"
  assert "$("${BASHX}" coverage report -h)" contains "Usage: bashx coverage report"
}

test::main
