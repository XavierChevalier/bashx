#!/usr/bin/env bash
# Tests of the bashx command.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/bashx.sh"

BASHX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bashx"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"

test_should_list_its_commands() {
  local out
  out="$("${BASHX}")"
  test::assert_contains "${out}" "Usage: bashx <command> [options]" || return 1
  test::assert_equals "${out}" "$("${BASHX}" --help)" || return 1
  test::assert_contains "${out}" "mutate <script.sh>..." || return 1
}

test_should_print_its_version() {
  test::assert_matches "$("${BASHX}" version)" '^bashx [0-9]+\.[0-9]+\.[0-9]+$' || return 1
  test::assert_equals "$("${BASHX}" version)" "$("${BASHX}" --version)" || return 1
}

# Installed as a symlink (e.g. ~/.local/bin/bashx), it still finds its lib.
test_should_print_its_lib_dir_through_a_symlink() {
  local bin
  bin="$(test::tmp_dir)"
  ln -s "${BASHX}" "${bin}/bashx"
  test::assert_equals "${LIB}" "$("${bin}/bashx" lib)" || return 1
  ln -s "../$(basename "${bin}")/bashx" "${bin}/relative"
  test::assert_equals "${LIB}" "$("${bin}/relative" lib)" || return 1
}

# release-please bumps them together; a hand edit of one would ship a wrong
# `bashx version` or a changelog out of step with the tag.
test_should_agree_on_the_version_everywhere() {
  local -r root="$(dirname "${BASHX}")/.."
  local cli manifest file changelog
  cli="$("${BASHX}" version)"
  manifest="$(sed -n 's/^ *"\." *: *"\(.*\)".*$/\1/p' "${root}/.release-please-manifest.json")"
  file="$(cat "${root}/version.txt")"
  changelog="$(sed -n 's/^## \[\([0-9][^]]*\)\].*$/\1/p' "${root}/CHANGELOG.md" | head -1)"
  test::assert_equals "bashx ${manifest}" "${cli}" "bin/bashx vs .release-please-manifest.json" || return 1
  test::assert_equals "${manifest}" "${file}" "version.txt" || return 1
  test::assert_equals "${manifest}" "${changelog}" "latest CHANGELOG.md section" || return 1
}

test_should_refuse_an_unknown_command() {
  local out rc=0
  out="$("${BASHX}" frobnicate 2>&1)" || rc=$?
  test::assert_equals 2 "${rc}" || return 1
  test::assert_contains "${out}" "bashx: unknown command 'frobnicate'" || return 1
}

test_should_run_the_tests_of_a_project() {
  local dir out
  dir="$(test::tmp_dir)"
  printf '%s\n' 'source "${BASHX_LIB}/bashx.sh"' 'test::init' 'test::run "should pass" true' 'test::summary' >"${dir}/a.test.sh"
  out="$(BASHX_PLAIN_OUTPUT=1 "${BASHX}" test "${dir}" 2>&1)" || return 1
  test::assert_contains "${out}" "1 passed, 0 failed, 1 total" || return 1
}

test_should_hand_mutate_and_coverage_their_arguments() {
  test::assert_contains "$("${BASHX}" mutate -h)" "Usage: bashx mutate" || return 1
  test::assert_contains "$("${BASHX}" coverage report -h)" "Usage: bashx coverage report" || return 1
}

test::init
test::run "should list its commands" test_should_list_its_commands
test::run "should print its version" test_should_print_its_version
test::run "should print its lib dir through a symlink" test_should_print_its_lib_dir_through_a_symlink
test::run "should agree on the version everywhere" test_should_agree_on_the_version_everywhere
test::run "should refuse an unknown command" test_should_refuse_an_unknown_command
test::run "should run the tests of a project" test_should_run_the_tests_of_a_project
test::run "should hand mutate and coverage their arguments" test_should_hand_mutate_and_coverage_their_arguments
test::summary
