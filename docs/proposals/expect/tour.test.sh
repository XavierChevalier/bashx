#!/usr/bin/env bash
# A tour of the expect API on a small deploy script: values, commands, files,
# mocks, hooks. Every case passes; failures.demo.sh shows the failures.
source "$(dirname "${BASH_SOURCE[0]}")/expect.sh"

# The code under test, inline to keep the tour in one file.
deploy::notify() {
  curl --silent --data "$1" https://hooks.example.org/deploy >/dev/null || {
    echo "deploy: cannot notify" >&2
    return 1
  }
}
deploy::write_config() {
  printf 'env=%s\nport=%s\n' "$2" "$3" >"$1"
}
deploy::version() {
  echo "1.4.0+$(git rev-parse --short HEAD)"
}

before_each() {
  WORK="$(test::tmp_dir)"
}

test_should_compare_values() {
  local out="Saved 3 files in 120ms"
  expect "${out}" to_contain "3 files"
  expect "${out}" to_start_with "Saved"
  expect "${out}" to_match '[0-9]+ms$'
  expect "${out}" not to_contain "error"
  expect "$(printf 'a\nb\nc')" to_have_lines 3
  expect "${#out}" to_be_greater_than 10
}

test_should_post_the_message() {
  mock curl
  deploy::notify "v1.4.0 is live"
  expect_mock curl to_have_been_called 1 times
  expect_mock curl to_have_been_called_with --data "v1.4.0 is live"
}

test_should_say_when_it_cannot_notify() {
  mock curl --exit 7
  run deploy::notify "v1.4.0 is live"
  expect_status not to_be 0
  expect_stderr to_be "deploy: cannot notify"
}

test_should_read_the_commit_from_git() {
  mock git <<'BODY'
[[ "$1" == rev-parse ]] && echo abc123
BODY
  expect "$(deploy::version)" to_be "1.4.0+abc123"
}

test_should_write_the_config() {
  deploy::write_config "${WORK}/app.conf" prod 8080
  expect_file "${WORK}/app.conf" to_exist
  expect_file "${WORK}/app.conf" to_contain "port=8080"
  expect_file "${WORK}/app.conf" to_be $'env=prod\nport=8080'
  expect_file "${WORK}/old.conf" not to_exist
}

test::main
