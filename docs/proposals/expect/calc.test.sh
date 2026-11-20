#!/usr/bin/env bash
# examples/calculator/calc.test.sh, written with the proposed expect API.
source "$(dirname "${BASH_SOURCE[0]}")/expect.sh"
source "$(dirname "${BASH_SOURCE[0]}")/calc.sh"

test_should_add_two_integers() {
  expect "$(calc::add 2 3)" to_be 5
  expect "$(calc::add 2 -3)" to_be -1
}

test_should_divide_towards_zero() {
  expect "$(calc::divide 7 2)" to_be 3
  expect "$(calc::divide -7 2)" to_be -3
}

test_should_refuse_a_division_by_zero() {
  run calc::divide 1 0
  expect_status to_be 1
  expect_stderr to_be "calc: division by zero"
  expect_stdout to_be_empty
}

test_should_tell_the_sign_of_a_number() {
  expect "$(calc::sign "$1")" to_be "$2"
}
test::cases test_should_tell_the_sign_of_a_number <<'TABLE'
-4  negative
0   zero
9   positive
TABLE

test_should_name_what_is_not_an_integer() {
  run calc::add 1 x
  expect_status to_be 2
  expect_stderr to_contain "not an integer: 'x'"
  expect_stdout to_be_empty
}

test::main
