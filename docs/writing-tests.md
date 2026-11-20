[Documentation](README.md) › Writing tests

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
  assert "$(cd "${dir}" && echo *)" == "3.tar 4.tar 5.tar"
}

test::main                                            # 4. run the cases
```

1. `BASHX_LIB` is set by `bashx test`. Outside it, `$(bashx lib)` finds the
   library, so `bash backup.test.sh` works too.
2. Source the code with a path relative to the test file. `bashx test` also
   starts each file from its own directory, so `source ./backup.sh` works.
3. A case is any function whose name starts with `test_`. Name it after the
   behaviour it checks: the name, without `test_` and with spaces, is what
   the output shows.
4. `test::main` runs every `test_*` function in the order of the file,
   prints the tally, and fails the file when a case failed. Forget it and
   the file fails with a message saying so.

Optional kinds: `backup.unit.test.sh`, `backup.integration.test.sh`… let you
run a subset with `bashx test --kind=unit`. Any word works as a kind.

## What a case gets

Each case runs:

- **in a subshell**: variables, functions, `cd`, `PATH` or `export` changed in
  a case do not reach the next one. Cases are independent and can run in any
  order.
- **with errexit on**: the first failing command or assertion ends the case
  and marks it failed.
- **with its own tmp dir**: `test::tmp_dir` returns a new empty directory
  inside it, removed when the case ends.
- **with stdin closed**: a `read` gets end of file instead of waiting.
- **quietly**: what it prints shows under it only when it fails or is
  skipped. `bashx test -v` shows it always.

## Assertions

`assert <actual> <operator> <expected>`, always in that order:

```bash
assert "$(calc::add 2 3)" == 5
assert "${output}" contains "Saved 3 files"
assert "${version}" matches '^[0-9]+\.[0-9]+$'
assert "$(wc -l <"${log}")" -ge 3
assert "${dir}/config" has "port=8080"
assert "${dir}/cache" !exists
```

A failed assertion names its line and shows both values, or a diff when they
span several lines:

```text
│  ✗ should keep the last three archives (12ms)
│    ✗ backup.test.sh:10  assert "$(cd "${dir}" && echo *)" == "3.tar 4.tar 5.tar"
│      expected: 3.tar 4.tar 5.tar
│      actual:   1.tar 2.tar 3.tar 4.tar 5.tar
```

It ends the case wherever it runs, so a helper can assert, even when it is
called under `if` or `||`:

```bash
check_valid_config() {
  assert "$1" has "port="
  assert "$1" has "host="
}
```

Every operator is in the [API reference](api.md#assert).

## Testing exit codes and errors

`capture` runs a command without stopping the case, and keeps its exit code
and both outputs, separately:

```bash
test_should_refuse_a_missing_file() {
  capture backup::run /nope
  assert "${STATUS}" == 1
  assert "${STDERR}" == "backup: no such file: /nope"
  assert "${STDOUT}" empty
}
```

Without `capture`, write `out="$(cmd)" || rc=$?`, never `out="$(cmd)"; rc=$?`:
under errexit the second form ends the case on the failure before `rc` is
set.

## Tables of cases

The same check on several inputs: one function, one row per case.

```bash
test_should_truncate() {
  assert "$(strings::truncate "$1" "$2")" == "$3"
}
test::cases test_should_truncate <<'EOF'
hello          10  hello
hello          5   hello
"hello world"  6   hello…
EOF
```

Each row runs as its own case, isolated like the others, and shows its
arguments: `✓ should truncate [hello world 6 hello…]`.

## Fixtures and hooks

- `test::tmp_dir`: a new directory per call, removed with the case.
- `before_each` / `after_each`: run around every case, in its subshell;
  `after_each` runs even when the case failed.
- `before_all` and `test::suite_tmp_dir`: one directory for the whole file,
  built once, for fixtures that are slow to build and only read.
- Files inline: a heredoc is often clearer than a fixture file.

```bash
before_each() {
  CONF="$(test::tmp_dir)/app.conf"
  cat >"${CONF}" <<'EOF'
port=8080
EOF
}

test_should_read_the_port() {
  assert "$(config::get "${CONF}" port)" == 8080
}
```

## Mocks

`mock` replaces a command, or a function of the code under test, until the
end of the case, and records its calls:

```bash
test_should_report_an_unreachable_host() {
  mock curl --exit 7
  assert "$(health::check https://example.org)" == "down"
}

test_should_post_the_message() {
  mock curl --stdout '{"ok":true}'
  deploy::notify "done"
  assert "$(mock::count curl)" == 1
  assert "$(mock::calls curl)" contains "--data done"
}
```

The mock answers calls from the test's shell and from child processes
(`bash deploy.sh` calling `curl` sees it too). For more than an exit code
and an output, give it a body:

```bash
mock git <<'EOF'
case "$1" in
  rev-parse) echo abc123 ;;
  status) echo "nothing to commit" ;;
  *) exit 1 ;;
esac
EOF
```

## Skipping

- One case: `test::skip "needs docker"` ends it as skipped.
- A whole file: a header comment `# @requires docker jq` makes `bashx test`
  skip the file unless every listed command is on `PATH`. The comment must
  come before the first command.

## Running some cases

`bashx test --filter=retry` runs only the cases whose description contains
`retry`; `BASHX_FILTER=retry bash api.test.sh` does the same for one file.

## Testing a script, not a function

When the code under test is a script with a `main`, run it as a command:

```bash
SCRIPT="$(dirname "${BASH_SOURCE[0]}")/backup.sh"

test_should_print_usage_without_arguments() {
  capture bash "${SCRIPT}"
  assert "${STATUS}" == 2
  assert "${STDERR}" contains "Usage:"
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
  Check explicitly: `validate "$@" || return`. (`assert` does not have this
  problem: it ends the case itself.)
- `((n++))` returns 1 when `n` was 0 and ends the case: write `n=$((n + 1))`.
- `local x="$(cmd)"` hides the failure of `cmd` (status of `local`). Declare
  first: `local x; x="$(cmd)"`.
- A command substitution drops trailing newlines: compare outputs with
  `==`, not line counts of `$(…)`.

## The EXIT trap

`bashx.sh` sets an EXIT trap that removes the file's tmp dir, fails the file
when a case failed, and fails it when it defines `test_*` functions that
never ran (`test::main` forgotten). It does not run the cases itself: under a
trap, bash 5.0 changes what a `return` without argument returns, which would
change the code under test.

If the code under test sets its own EXIT trap, chain the existing one
instead of replacing it, or call it from yours.

## Files written for bashx 0.1

`test::init`, `test::run`, `test::summary` and the `test::assert_*`
functions still work as before: old files run unchanged, and a file can mix
both styles. The [API reference](api.md#v1-assertions) maps each old
assertion to its `assert` form.

---

Previous: [Getting started](getting-started.md) · Next: [Running tests](running-tests.md)
