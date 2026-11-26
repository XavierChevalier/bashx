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

# A copy of bin/ and lib/ without the sources (the release archive, a copy
# into a project) and without Go: the binary comes from libexec/ when the
# archive ships it, else from the release, once, checked against its sum.
test_should_find_or_download_the_binary_without_go() {
  local dir bin releases path out
  command -v curl >/dev/null && command -v sha256sum >/dev/null || test::skip "needs curl and sha256sum"
  dir="$(test::tmp_dir)"
  mkdir -p "${dir}/bashx"
  cp -R "${LIB}" "${dir}/bashx/lib"
  mkdir -p "${dir}/bashx/bin"
  cp "${BASHX}" "${dir}/bashx/bin/bashx"
  bin="${BASHX_BIN:-${LIB}/../.build/bashx}"
  # PATH without go: a dir of links to the commands the launcher uses.
  path="$(test::tmp_dir)"
  local cmd
  for cmd in bash env uname tr cat mkdir mktemp mv rm chmod awk sha256sum curl dirname readlink; do
    ln -s "$(command -v "${cmd}")" "${path}/${cmd}"
  done

  releases="$(test::tmp_dir)"
  mkdir -p "${releases}/v$("${BASHX}" version | cut -d' ' -f2)"
  local -r asset="${releases}/v$("${BASHX}" version | cut -d' ' -f2)/bashx-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
  cp "${bin}" "${asset}"
  (cd "$(dirname "${asset}")" && sha256sum "$(basename "${asset}")" >"${asset}.sha256")

  out="$(BASHX_BIN="" PATH="${path}" XDG_CACHE_HOME="${dir}/cache" BASHX_RELEASES_URL="file://${releases}" \
    "${dir}/bashx/bin/bashx" test --help 2>&1)"
  assert "${out}" contains "bashx: downloading file://"
  assert "${out}" contains "Usage: bashx test"
  out="$(BASHX_BIN="" PATH="${path}" XDG_CACHE_HOME="${dir}/cache" "${dir}/bashx/bin/bashx" test --help 2>&1)"
  assert "${out}" !contains "downloading"  # cached

  echo "corrupted" >"${asset}"
  local rc=0
  out="$(BASHX_BIN="" PATH="${path}" XDG_CACHE_HOME="${dir}/cache2" BASHX_RELEASES_URL="file://${releases}" \
    "${dir}/bashx/bin/bashx" test --help 2>&1)" || rc=$?
  assert "${rc}" == 1
  assert "${out}" contains "checksum mismatch"

  mkdir -p "${dir}/bashx/libexec"
  cp "${bin}" "${dir}/bashx/libexec/$(basename "${asset}")"
  out="$(BASHX_BIN="" PATH="${path}" XDG_CACHE_HOME="${dir}/cache3" "${dir}/bashx/bin/bashx" test --help 2>&1)"
  assert "${out}" == "$(BASHX_BIN="${bin}" "${BASHX}" test --help)"
}

test::main
