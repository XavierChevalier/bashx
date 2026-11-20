#!/usr/bin/env bash
# Tests of calc.sh. Run them with `bashx test`, or alone: `bash calc.test.sh`.
source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"
source "$(dirname "${BASH_SOURCE[0]}")/calc.sh"

test_should_add_two_integers() {
  test::assert_equals 5 "$(calc::add 2 3)"
  test::assert_equals -1 "$(calc::add 2 -3)"
}

test_should_divide_towards_zero() {
  test::assert_equals 3 "$(calc::divide 7 2)"
  test::assert_equals -3 "$(calc::divide -7 2)"
}

test_should_refuse_a_division_by_zero() {
  local err rc=0
  err="$(calc::divide 1 0 2>&1)" || rc=$?
  test::assert_equals 1 "${rc}"
  test::assert_equals "calc: division by zero" "${err}"
}

test_should_tell_the_sign_of_a_number() {
  test::assert_equals negative "$(calc::sign -4)"
  test::assert_equals zero "$(calc::sign 0)"
  test::assert_equals positive "$(calc::sign 9)"
}

test_should_refuse_what_is_not_an_integer() {
  test::assert_exit_code 2 calc::add 1 x
  test::assert_exit_code 2 calc::divide 1.5 2
  test::assert_exit_code 2 calc::sign ""
}

test::init
test::run "should add two integers" test_should_add_two_integers
test::run "should divide towards zero" test_should_divide_towards_zero
test::run "should refuse a division by zero" test_should_refuse_a_division_by_zero
test::run "should tell the sign of a number" test_should_tell_the_sign_of_a_number
test::run "should refuse what is not an integer" test_should_refuse_what_is_not_an_integer
test::summary
