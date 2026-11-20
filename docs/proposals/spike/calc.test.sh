#!/usr/bin/env bash
# examples/calculator/calc.test.sh, written with the proposed API.
source "$(dirname "${BASH_SOURCE[0]}")/next.sh"
source "$(dirname "${BASH_SOURCE[0]}")/calc.sh"

test_should_add_two_integers() {
  assert "$(calc::add 2 3)" == 5
  assert "$(calc::add 2 -3)" == -1
}

test_should_divide_towards_zero() {
  assert "$(calc::divide 7 2)" == 3
  assert "$(calc::divide -7 2)" == -3
}

test_should_refuse_a_division_by_zero() {
  capture calc::divide 1 0
  assert "${STATUS}" == 1
  assert "${STDERR}" == "calc: division by zero"
  assert "${STDOUT}" empty
}

test_should_tell_the_sign_of_a_number() {
  assert "$(calc::sign "$1")" == "$2"
}
test::cases test_should_tell_the_sign_of_a_number <<'TABLE'
-4  negative
0   zero
9   positive
TABLE

test_should_refuse_what_is_not_an_integer() {
  capture calc::add 1 x
  assert "${STATUS}" == 2
  assert "${STDERR}" == "calc: not an integer: 'x'"
}
