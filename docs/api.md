[Documentation](README.md) › API

# API reference

Everything a test file gets from:

```bash
source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"
```

Sourcing it also:

- turns on `set -euo pipefail` in the test file;
- sets an EXIT trap that removes the file's temporary directory and makes the
  file exit 1 when a case failed ([details](writing-tests.md#the-exit-trap)).

| Lifecycle | Assertions | Fixtures |
| --- | --- | --- |
| [`test::init`](#testinit) | [`test::assert_equals`](#testassert_equals) | [`test::tmp_dir`](#testtmp_dir) |
| [`test::run`](#testrun) | [`test::assert_not_equals`](#testassert_not_equals) | [`test::suite_tmp_dir`](#testsuite_tmp_dir) |
| [`test::skip`](#testskip) | [`test::assert_contains`](#testassert_contains) | [`test::mock_command`](#testmock_command) |
| [`test::summary`](#testsummary) | [`test::assert_not_contains`](#testassert_not_contains) | |
| | [`test::assert_matches`](#testassert_matches) | |
| | [`test::assert_exit_code`](#testassert_exit_code) | |
| | [`test::assert_file_exists`](#testassert_file_exists) | |
| | [`test::assert_file_not_exists`](#testassert_file_not_exists) | |
| | [`test::assert_file_contains`](#testassert_file_contains) | |
| | [`test::assert_file_not_contains`](#testassert_file_not_contains) | |
| | [`test::assert_file_equals`](#testassert_file_equals) | |

---

## Lifecycle

### test::init

```text
test::init
```

Starts the test file: resets the counters, creates the file's shared
temporary directory, prints the file name relative to the git root:

```text
🧪 ./lib/strings.test.sh
```

Call it once, after defining the cases and before the first `test::run`.

### test::run

```text
test::run "<description>" <function> [args...]
```

Runs one case: calls `<function>` with the arguments, in a subshell, with
errexit on and its own temporary directory. Prints one line:

```text
│  ✓ should keep a short text (7ms)
│  ✗ should cut a long text (6ms)
│  ○ should talk to docker (skipped)
```

The duration turns yellow from 300 ms and red from 1.2 s. `test::run` always
returns 0, so the next case runs whatever happened.

The arguments make table-driven cases easy:

```bash
check_truncate() {
  test::assert_equals "$3" "$(strings::truncate "$1" "$2")"
}

test::run "should keep a short text" check_truncate "hello" 10 "hello"
test::run "should cut a long text" check_truncate "hello world" 6 "hello…"
```

### test::skip

```text
test::skip ["<reason>"]
```

Inside a case: ends it now, as skipped (neither passed nor failed). The
reason is printed under the case.

```bash
test_should_build_the_image() {
  command -v docker >/dev/null || test::skip "docker not installed"
  ...
}
```

To skip a whole file, use [`# @requires`](running-tests.md#skipping-files).

### test::summary

```text
test::summary
```

Prints the file's result and returns 1 when a case failed. Make it the last
command of the file: its status becomes the file's exit code.

```text
└── ✓ All 3 tests passed (24ms)
└── ✓ All 3 tests passed / Skipped: 1 (24ms)
└── ✗ Failed: 1 / Passed: 2 / Total: 3 (30ms)
```

Forgotten, the EXIT trap prints it anyway and the file still fails when a case
failed.

---

## Assertions

All assertions:

- return 0 when they hold;
- otherwise print `✗ Assertion failed` with what was expected and what was
  found, and return 1, which ends the case (errexit);
- take an optional last argument, `[message]`, printed with the failure as
  `Message: …`.

```text
    ✗ Assertion failed
      Expected: 3
      Actual:   4
      Message:  files left after pruning
```

### test::assert_equals

```text
test::assert_equals <expected> <actual> [message]
```

The two strings are equal. Compare whole outputs, lists joined on spaces or
newlines, exit codes captured in a variable.

```bash
test::assert_equals "hello…" "$(strings::truncate "hello world" 6)"
test::assert_equals $'line 1\nline 2' "$(my_command)"
```

### test::assert_not_equals

```text
test::assert_not_equals <unexpected> <actual> [message]
```

The two strings differ.

```bash
test::assert_not_equals "$(uuid::new)" "$(uuid::new)"
```

### test::assert_contains

```text
test::assert_contains <haystack> <needle> [message]
```

`needle` appears in `haystack`. Use it for long outputs where only one part
matters.

```bash
test::assert_contains "$(backup::run 2>&1)" "3 files saved"
```

### test::assert_not_contains

```text
test::assert_not_contains <haystack> <needle> [message]
```

`needle` does not appear in `haystack`.

```bash
test::assert_not_contains "$(deploy::log)" "password"
```

### test::assert_matches

```text
test::assert_matches <string> <regex> [message]
```

`string` matches the extended regular expression (bash `[[ =~ ]]`). Quote the
regex in single quotes.

```bash
test::assert_matches "$(bashx version)" '^bashx [0-9]+\.[0-9]+\.[0-9]+$'
```

### test::assert_exit_code

```text
test::assert_exit_code <code> <command> [args...]
```

Runs the command, discards its output, and checks its exit code. The command
can be a function. The `[message]` argument is not available here: the
arguments after `<code>` are the command.

```bash
test::assert_exit_code 0 config::valid "port=80"
test::assert_exit_code 2 config::valid "port=eighty"
```

To check the output too, capture both instead (see
[testing exit codes](writing-tests.md#testing-exit-codes-and-errors)).

### test::assert_file_exists

```text
test::assert_file_exists <file> [message]
```

`file` exists and is a regular file.

### test::assert_file_not_exists

```text
test::assert_file_not_exists <path> [message]
```

Nothing exists at `path` (no file, directory or link).

```bash
cleanup::run "${dir}"
test::assert_file_not_exists "${dir}/cache"
```

### test::assert_file_contains

```text
test::assert_file_contains <file> <needle> [message]
```

The file exists and contains `needle`.

```bash
test::assert_file_contains "${dir}/app.conf" "port=8080"
```

### test::assert_file_not_contains

```text
test::assert_file_not_contains <file> <needle> [message]
```

The file exists and does not contain `needle`.

### test::assert_file_equals

```text
test::assert_file_equals <file> <expected> [message]
```

The file's whole content equals `expected`. When `expected` names an existing
file, its content is the expected value (a "golden" file).

```bash
test::assert_file_equals "${dir}/out.txt" "done"
test::assert_file_equals "${dir}/report.md" "$(dirname "${BASH_SOURCE[0]}")/fixtures/report.md"
```

---

## Fixtures

### test::tmp_dir

```text
test::tmp_dir
```

Prints the path of a new, empty directory. Inside a case, it lives in the
case's temporary directory and is removed when the case ends. Outside a case,
it is removed when the file exits.

```bash
test_should_write_the_config() {
  local dir
  dir="$(test::tmp_dir)"
  config::write "${dir}/app.conf" port=80
  test::assert_file_contains "${dir}/app.conf" "port=80"
}
```

### test::suite_tmp_dir

```text
test::suite_tmp_dir
```

Prints the file's shared temporary directory: the same path for every case,
removed when the file exits. Use it for fixtures that are slow to build and
only read. Fails with `test::suite_tmp_dir needs test::init first` before
`test::init`.

```bash
test::init
FIXTURE="$(test::suite_tmp_dir)/big-tree"
build_big_tree "${FIXTURE}"          # once, for every case
test::run "should count the files" test_should_count_the_files
```

### test::mock_command

```text
test::mock_command <name> <script> [<bin dir>]
```

Writes an executable `<name>` that runs `<script>` (bash) into a directory,
and prints that directory. Put it first on `PATH` inside a case to replace a
real command. Pass the same `<bin dir>` to group several mocks.

```bash
test_should_retry_when_the_api_is_down() {
  local bin calls
  calls="$(test::tmp_dir)/calls"
  bin="$(test::mock_command curl "echo x >>'${calls}'; exit 7")"
  test::mock_command sleep ':' "${bin}" >/dev/null
  PATH="${bin}:${PATH}"
  api::fetch_with_retry 3 || true
  test::assert_equals 3 "$(wc -l <"${calls}")"
}
```

The `PATH` change ends with the case.

---

## Variables

| Variable | Set by | Meaning |
| --- | --- | --- |
| `BASHX_LIB` | `bashx`, or `bashx.sh` itself | Directory of `bashx.sh`. |
| `NO_COLOR` | you | Any value: no colours. Read when `bashx.sh` is sourced. |

Names starting with `test::_` or `_TEST_` are internal: do not use them.

---

Previous: [Command line](cli.md) · Next: [How it works](how-it-works.md)
