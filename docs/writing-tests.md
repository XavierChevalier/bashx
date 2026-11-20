# Writing tests

## A test file

A test file is a bash script named `*.test.sh`. Put it next to the script it
tests: `backup.sh` → `backup.test.sh`. `bashx mutate backup.sh` finds it there.

```bash
#!/usr/bin/env bash
source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"        # 1. the API
source "$(dirname "${BASH_SOURCE[0]}")/backup.sh"    # 2. the code under test

test_should_keep_the_last_three_archives() {         # 3. one function per case
  local dir
  dir="$(test::tmp_dir)"
  touch "${dir}"/{1,2,3,4,5}.tar
  backup::prune "${dir}" 3
  test::assert_equals "3.tar 4.tar 5.tar" "$(cd "${dir}" && echo *)"
}

test::init                                            # 4. run the cases
test::run "should keep the last three archives" test_should_keep_the_last_three_archives
test::summary
```

1. `BASHX_LIB` is set by `bashx test`. Outside it, `$(bashx lib)` finds the
   library, so `bash backup.test.sh` works too.
2. Source the code with a path relative to the test file. `bashx test` also
   starts each file from its own directory, so `source ./backup.sh` works.
3. A case is any function. Name it after the behaviour it checks.
4. `test::init` prints the file name, `test::run` runs one case, and
   `test::summary` prints the tally and fails the file when a case failed.

Optional kinds: `backup.unit.test.sh`, `backup.integration.test.sh`… let you
run a subset with `bashx test --kind=unit`. Any word works as a kind.

## What a case gets

Each `test::run` runs its function:

- **in a subshell**: variables, functions, `cd`, `PATH` or `export` changed in
  a case do not reach the next one. Cases are independent and can run in any
  order.
- **with errexit on**: the first failing command or assertion ends the case
  and marks it failed. No `|| return 1` needed after each assertion.
- **with its own tmp dir**: `test::tmp_dir` returns a new empty directory
  inside it, removed when the case ends.

## Assertions

```bash
test::assert_equals "expected" "${actual}"
test::assert_contains "${output}" "Saved 3 files"
test::assert_matches "${version}" '^[0-9]+\.[0-9]+$'
test::assert_exit_code 2 my_function --bad-flag
test::assert_file_contains "${dir}/config" "port=8080"
```

A failed assertion prints what it expected and what it got:

```text
    ✗ Assertion failed
      Expected: 3.tar 4.tar 5.tar
      Actual:   1.tar 2.tar 3.tar 4.tar 5.tar
│  ✗ should keep the last three archives (12ms)
```

Every assertion takes an optional last argument: a message printed with the
failure. The full list is in the [API reference](api.md).

## Testing exit codes and errors

Capture the code without stopping the case:

```bash
test_should_refuse_a_missing_file() {
  local err rc=0
  err="$(backup::run /nope 2>&1)" || rc=$?
  test::assert_equals 1 "${rc}"
  test::assert_contains "${err}" "no such file: /nope"
}
```

Write `cmd || rc=$?`, never `cmd; rc=$?`: under errexit the second form ends
the case on the failure before `rc` is set.

## Fixtures

- `test::tmp_dir`: a new directory per call, removed with the case.
- `test::suite_tmp_dir`: one directory for the whole file, for fixtures that
  are slow to build and only read by the cases. Build it once after
  `test::init`.
- Files inline: a heredoc is often clearer than a fixture file.

```bash
test_should_read_the_port() {
  local conf
  conf="$(test::tmp_dir)/app.conf"
  cat >"${conf}" <<'EOF'
port=8080
EOF
  test::assert_equals 8080 "$(config::get "${conf}" port)"
}
```

## Mocks

Replace a command for one case by putting a fake first on `PATH`:

```bash
test_should_report_an_unreachable_host() {
  PATH="$(test::mock_command curl 'exit 7'):${PATH}"
  test::assert_equals "down" "$(health::check https://example.org)"
}
```

The change dies with the case's subshell. To check how the mock was called,
make it write its arguments to a file in the case's tmp dir:

```bash
  local log
  log="$(test::tmp_dir)/curl.log"
  PATH="$(test::mock_command curl "echo \"\$*\" >>'${log}'"):${PATH}"
  deploy::notify "done"
  test::assert_file_contains "${log}" "--data done"
```

A function can be replaced the same way: define it again inside the case.

## Skipping

- One case: `test::skip "needs docker"` ends it as skipped.
- A whole file: a header comment `# @requires docker jq` makes `bashx test`
  skip the file unless every listed command is on `PATH`. The comment must
  come before the first command.

## Testing a script, not a function

When the code under test is a script with a `main`, run it as a command:

```bash
SCRIPT="$(dirname "${BASH_SOURCE[0]}")/backup.sh"

test_should_print_usage_without_arguments() {
  local out rc=0
  out="$(bash "${SCRIPT}" 2>&1)" || rc=$?
  test::assert_equals 2 "${rc}"
  test::assert_contains "${out}" "Usage:"
}
```

To source its functions without running it, guard `main` in the script:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

## Bash pitfalls that tests meet

- **errexit is off under `if`, `while`, `||`, `&&` and `!`**, in everything
  the condition calls. A function that relies on errexit to stop at a failed
  check carries on when called as `if my_function` or `my_function || …`.
  Check explicitly: `validate "$@" || return`.
- `((n++))` returns 1 when `n` was 0 and ends the case: write `n=$((n + 1))`.
- `local x="$(cmd)"` hides the failure of `cmd` (status of `local`). Declare
  first: `local x; x="$(cmd)"`.
- A command substitution drops trailing newlines: compare outputs with
  `assert_equals`, not line counts of `$(…)`.

## The EXIT trap

`bashx.sh` sets an EXIT trap that removes the file's tmp dir and fails the
file when a case failed, even if `test::summary` was forgotten. If the code
under test sets its own EXIT trap, chain the existing one instead of replacing
it, or call it from yours.
