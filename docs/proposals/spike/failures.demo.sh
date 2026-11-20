#!/usr/bin/env bash
# What failures, mocks, hooks and skips look like. Not a *.test.sh: it fails
# on purpose. Run it alone: bash docs/proposals/spike/failures.demo.sh
source "$(dirname "${BASH_SOURCE[0]}")/next.sh"
source "$(dirname "${BASH_SOURCE[0]}")/calc.sh"
before_each() { echo "setup ran"; }
after_each() { echo "teardown ran"; }
helper() { assert "$1" == even; }
test_location_and_value() {
  assert "$(calc::add 2 2)" == 5
}
test_multiline_diff() {
  assert $'a\nb\nc' == $'a\nB\nc'
}
test_assert_under_if_still_fails() {
  if helper odd; then echo "should not print"; fi
  echo "after if"
}
test_assert_inside_substitution_still_fails() {
  local x; x="$(assert 1 == 2; echo y)"
  echo "kept going: $x"
}
notify() { curl --data "$1" https://x; sleep 1; }
test_mock_records_calls() {
  mock curl --exit 0 --stdout ok
  mock sleep
  notify "done"
  notify again
  assert "$(mock::count curl)" == 2
  assert "$(mock::calls curl)" contains "--data again"
  bash -c 'curl from-child' >/dev/null
  assert "$(mock::calls curl)" contains "from-child"
}
test_mock_with_body() {
  mock git <<'B'
[[ "$1" == rev-parse ]] && echo abc123
B
  assert "$(git rev-parse HEAD)" == abc123
}
test_skip_works() { test::skip "no docker"; }
test::main
