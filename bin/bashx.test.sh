#!/usr/bin/env bash
# Tests of the bashx command.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/bashx.sh"

BASHX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bashx"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"

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

# Installed as a symlink (e.g. ~/.local/bin/bashx), it still finds its lib.
test_should_print_its_lib_dir_through_a_symlink() {
  local bin
  bin="$(test::tmp_dir)"
  ln -s "${BASHX}" "${bin}/bashx"
  assert "$("${bin}/bashx" lib)" == "${LIB}"
  ln -s "../$(basename "${bin}")/bashx" "${bin}/relative"
  assert "$("${bin}/relative" lib)" == "${LIB}"
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
  assert "${cli}" == "bashx ${manifest}"  # bin/bashx vs .release-please-manifest.json
  assert "${file}" == "${manifest}"  # version.txt
  assert "${changelog}" == "${manifest}"  # latest CHANGELOG.md section
}

test_should_refuse_an_unknown_command() {
  local out rc=0
  out="$("${BASHX}" frobnicate 2>&1)" || rc=$?
  assert "${rc}" == 2
  assert "${out}" contains "bashx: unknown command 'frobnicate'"
}

test_should_run_the_tests_of_a_project() {
  local dir out
  dir="$(test::tmp_dir)"
  printf '%s\n' 'source "${BASHX_LIB}/bashx.sh"' 'test::init' 'test::run "should pass" true' 'test::summary' >"${dir}/a.test.sh"
  out="$(BASHX_PLAIN_OUTPUT=1 "${BASHX}" test "${dir}" 2>&1)"
  assert "${out}" contains "1 passed, 0 failed, 1 total"
}

test_should_hand_mutate_and_coverage_their_arguments() {
  assert "$("${BASHX}" mutate -h)" contains "Usage: bashx mutate"
  assert "$("${BASHX}" coverage report -h)" contains "Usage: bashx coverage report"
}

test::main
