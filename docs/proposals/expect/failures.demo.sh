#!/usr/bin/env bash
# What failures look like with the expect API. Not a *.test.sh: every case
# fails on purpose. Run it alone: bash docs/proposals/expect/failures.demo.sh
source "$(dirname "${BASH_SOURCE[0]}")/expect.sh"
source "$(dirname "${BASH_SOURCE[0]}")/calc.sh"

test_a_value() {
  expect "$(calc::add 2 3)" to_be 6
}

test_a_multiline_output() {
  expect "$(printf 'a\nb\nc')" to_be $'a\nB\nc'
}

test_a_negation() {
  expect "Saved 3 files, 1 error" not to_contain "error"
}

test_a_command() {
  run calc::divide 1 0
  expect_status to_be 0
}

test_a_mock() {
  mock curl
  curl --data hello https://example.org
  expect_mock curl to_have_been_called_with --data bye
}

test_a_file() {
  local conf
  conf="$(test::tmp_dir)/app.conf"
  echo "port=80" >"${conf}"
  expect_file "${conf}" to_contain "port=8080"
}

is_even() { expect "$(($1 % 2))" to_be 0; }
test_a_helper_under_if() {
  if is_even 3; then echo "unreachable"; fi
}

test_expect_status_without_run() {
  expect_status to_be 0
}

test::main
