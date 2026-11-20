[Documentation](README.md) › API

# API reference

Everything a test file gets from:

```bash
source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"
```

Sourcing it also:

- turns on `set -euo pipefail` in the test file;
- sets an EXIT trap that removes the file's temporary directory, makes the
  file exit 1 when a case failed, and fails a file whose `test_*` functions
  never ran ([details](writing-tests.md#the-exit-trap)).

| Cases | Checks | Fixtures |
| --- | --- | --- |
| [`test_*` functions](#test_-functions) | [`assert`](#assert) | [`mock`](#mock) |
| [`test::main`](#testmain) | [`capture`](#capture) | [`mock::calls`, `mock::count`](#mockcalls-mockcount) |
| [`test::cases`](#testcases) | [v1 assertions](#v1-assertions) | [`test::tmp_dir`](#testtmp_dir) |
| [`before_each`, `after_each`, `before_all`](#hooks) | | [`test::suite_tmp_dir`](#testsuite_tmp_dir) |
| [`test::skip`](#testskip) | | [`test::mock_command`](#testmock_command) |
| [`test::run`, `test::init`, `test::summary`](#testrun) | | |

---

## Cases

### test_* functions

```bash
test_should_keep_the_last_three_archives() {
  ...
}
```

Every function whose name starts with `test_` is a case. Its description is
its name without `test_`, underscores turned into spaces: `should keep the
last three archives`. [`test::main`](#testmain) runs them in the order they
are defined in the file.

Each case runs in a subshell, with errexit on, stdin closed, and its own
temporary directory and `bin/` directory (first on `PATH`). What it prints
is shown under it only when it fails or is skipped (always with
`bashx test -v` or `BASHX_VERBOSE=1`).

```text
│  ✓ should keep a short text (7ms)
│  ✗ should cut a long text (6ms)
│    ✗ strings.test.sh:10  assert "$(strings::truncate "hello world" 6)" == "hello w…"
│      expected: hello w…
│      actual:   hello…
│  ○ should talk to docker (skipped)
│    skipped: docker not installed
```

The duration turns yellow from 300 ms and red from 1.2 s.

### test::main

```text
test::main
```

Runs every `test_*` function not run yet, in the order of the file (once per
row for those with a [table](#testcases)), then prints the file's result and
returns 1 when a case failed. Make it the last line of the file.

```text
└── ✓ All 3 tests passed (24ms)
└── ✓ All 3 tests passed / Skipped: 1 (24ms)
└── ✗ Failed: 1 / Passed: 2 / Total: 3 (30ms)
```

Forgotten, the file fails anyway, with
`✗ 2 test_* function(s) never ran: end the file with test::main`.

### test::cases

```text
test::cases <function> <<'EOF'
<arguments of row 1>
<arguments of row 2>
EOF
```

Gives a case a table: `test::main` runs it once per row, with the row's
words as arguments. Words follow shell quoting (`"hello world"` is one word,
`""` an empty one). Blank lines and lines starting with `#` are skipped. The
description of each run ends with its arguments:
`should truncate [hello world 6 hello…]`.

```bash
test_should_truncate() {
  assert "$(strings::truncate "$1" "$2")" == "$3"
}
test::cases test_should_truncate <<'EOF'
hello          10  hello
"hello world"  6   hello…
# a cut at the boundary
hello          5   hello
EOF
```

### Hooks

```bash
before_all()  { ...; }   # once, in the file's shell, before the first case
before_each() { ...; }   # in each case's subshell, before the case
after_each()  { ...; }   # in each case's subshell, after it, even when it failed
```

Define any of them in the test file and they are called. What `before_each`
sets (variables, `cd`, mocks) is seen by the case and gone after it.

```bash
before_each() {
  WORK="$(test::tmp_dir)"
  cp -r "${FIXTURES}/project" "${WORK}"
  cd "${WORK}/project"
}
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

### test::run

```text
test::run "<description>" <function> [args...]
test::init
test::summary
```

The pieces `test::main` is made of, for a description of your own or a file
written for bashx 0.1:

- `test::run` runs one case now. A function run this way is not run again
  by `test::main`. It always returns 0, so the next case runs whatever
  happened.
- `test::init` prints the file name and calls `before_all`. The first
  `test::run` calls it when you do not.
- `test::summary` prints the result and returns 1 when a case failed.

```bash
test::run "should cut at a multi-byte boundary" check_truncate "héllo" 2 "h…"
test::main
```

With `BASHX_FILTER` set (`bashx test --filter=TEXT`), `test::run` runs only
the cases whose description contains it.

---

## Checks

### assert

```text
assert <actual> <operator> [<expected>]
```

Checks one thing, in the same order every time. On failure it prints the
line, the values, and ends the case: under `if`, `||`, `&&`, `!`, and inside
a `$( )` too (a helper that asserts fails the case wherever it is called).

| Operator | Holds when |
| --- | --- |
| `==` / `!=` | the strings are equal / differ |
| `contains` / `!contains` | `<expected>` appears / does not appear in `<actual>` |
| `matches` | `<actual>` matches the extended regex (`[[ =~ ]]`; quote it in single quotes) |
| `starts_with` / `ends_with` | `<actual>` starts / ends with `<expected>` |
| `empty` / `!empty` | `<actual>` is empty / not empty (no `<expected>`) |
| `-eq` `-ne` `-lt` `-le` `-gt` `-ge` | integer comparison; fails on a non-integer |
| `is_file` / `is_dir` | `<actual>` is a regular file / a directory |
| `exists` / `!exists` | something / nothing exists at `<actual>` |
| `has` / `!has` | the file `<actual>` contains / does not contain `<expected>` |
| `same_as` | the file `<actual>` holds exactly `<expected>`, or the content of the file `<expected>` names (a "golden" file) |

```bash
assert "$(strings::truncate "hello world" 6)" == "hello…"
assert "${out}" contains "3 files saved"
assert "${out}" !contains "password"
assert "$(bashx version)" matches '^bashx [0-9]+\.[0-9]+\.[0-9]+$'
assert "$(wc -l <"${log}")" -ge 3
assert "${dir}/cache" !exists
assert "${dir}/app.conf" has "port=8080"
assert "${dir}/report.md" same_as "$(dirname "${BASH_SOURCE[0]}")/fixtures/report.md"
```

A failure, from a helper, with a multi-line value:

```text
│    ✗ backup.test.sh:12  assert "$(ls "${dir}")" == "${expected}"
│      called from backup.test.sh:20 (test_should_prune_old_archives)
│      diff (- expected, + actual):
│      @@ -1,3 +1,3 @@
│       3.tar
│      -4.tar
│      +1.tar
│       5.tar
```

`assert` takes no message, and refuses extra arguments (a message left from
a v1 assertion fails with `assert: too many arguments`). The failure already
prints the source line, so a trailing comment shows with it; a value worth
seeing goes in an `echo` before, which shows only when the case fails:

```bash
for opt in --jobs=0 --timeout=x; do
  capture bashx test "${opt}"
  echo "option: ${opt}"
  assert "${STATUS}" == 2    # bad options exit 2
done
```

`test::assert` is the same function, for a file whose code under test
defines its own `assert`.

### capture

```text
capture <command> [args...]
```

Runs the command in a subshell, stdin closed, without stopping the case, and
sets:

| Variable | Holds |
| --- | --- |
| `STATUS` | its exit code |
| `STDOUT` | what it printed on stdout |
| `STDERR` | what it printed on stderr |

Trailing newlines are dropped, as with `$( )`. What the command changes
(variables, `cd`) stays in its subshell; an `exit` in it ends only the
subshell.

```bash
capture backup::run /nope
assert "${STATUS}" == 1
assert "${STDERR}" contains "no such file: /nope"
assert "${STDOUT}" empty
```

The names are in capitals on purpose: shellcheck does not report them as
never assigned. `test::capture` is the same function.

### v1 assertions

The assertions of bashx 0.1 are still there and unchanged. Unlike `assert`,
they return 1 and rely on errexit to end the case, so they do nothing under
`if` or `||`, and take an optional last `[message]`.

| v1 | With `assert` |
| --- | --- |
| `test::assert_equals <expected> <actual>` | `assert <actual> == <expected>` |
| `test::assert_not_equals <unexpected> <actual>` | `assert <actual> != <unexpected>` |
| `test::assert_contains <haystack> <needle>` | `assert <haystack> contains <needle>` |
| `test::assert_not_contains <haystack> <needle>` | `assert <haystack> !contains <needle>` |
| `test::assert_matches <string> <regex>` | `assert <string> matches <regex>` |
| `test::assert_exit_code <code> <command>…` | `capture <command>…; assert "${STATUS}" == <code>` |
| `test::assert_file_exists <file>` | `assert <file> is_file` |
| `test::assert_file_not_exists <path>` | `assert <path> !exists` |
| `test::assert_file_contains <file> <needle>` | `assert <file> has <needle>` |
| `test::assert_file_not_contains <file> <needle>` | `assert <file> !has <needle>` |
| `test::assert_file_equals <file> <expected>` | `assert <file> same_as <expected>` |

---

## Fixtures

### mock

```text
mock <name> [--exit <code>] [--stdout <text>] [--stderr <text>]
mock <name> <<'EOF'
<bash body; "$@" are the arguments>
EOF
```

Replaces the command or function `<name>` until the end of the case, and
records every call. The replacement is two things that write to the same
call log:

- a function `<name>`, for calls from the test's shell: it takes precedence
  over `PATH`, so it also replaces a function of the code under test;
- an executable in the case's `bin/`, first on `PATH`, for calls from child
  processes (`bash script.sh`, `xargs`, `env`…).

Without options, the mock prints nothing and succeeds. The options print
`<text>` and exit with `<code>`; a body on stdin runs after them.

```bash
test_should_retry_when_the_api_is_down() {
  mock curl --exit 7
  mock sleep
  api::fetch_with_retry 3 || true
  assert "$(mock::count curl)" == 3
}

test_should_read_the_commit() {
  mock git <<'EOF'
[[ "$1" == rev-parse ]] && echo abc123
EOF
  assert "$(release::version)" == "0.1.0+abc123"
}
```

Outside a case, `mock` fails with `mock: works inside a case only`.
`test::mock` is the same function.

### mock::calls, mock::count

```text
mock::calls <name>
mock::count <name>
```

`mock::calls` prints the arguments of every call of a mock, one call per
line (`"$*"`). `mock::count` prints how many calls there were.

```bash
deploy::notify "done"
assert "$(mock::calls curl)" contains "--data done"
```

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
  assert "${dir}/app.conf" has "port=80"
}
```

### test::suite_tmp_dir

```text
test::suite_tmp_dir
```

Prints the file's shared temporary directory: the same path for every case,
removed when the file exits. Use it for fixtures that are slow to build and
only read. Fails with `test::suite_tmp_dir needs test::init first` before
the first case or `before_all`.

```bash
before_all() {
  FIXTURE="$(test::suite_tmp_dir)/big-tree"
  build_big_tree "${FIXTURE}"          # once, for every case
}
```

### test::mock_command

```text
test::mock_command <name> <script> [<bin dir>]
```

The bashx 0.1 way to mock: writes an executable `<name>` that runs
`<script>` into a directory and prints the directory, to put first on `PATH`
yourself. It records nothing; prefer [`mock`](#mock).

---

## Variables

| Variable | Set by | Meaning |
| --- | --- | --- |
| `BASHX_LIB` | `bashx`, or `bashx.sh` itself | Directory of `bashx.sh`. |
| `BASHX_FILTER` | you, or `bashx test --filter` | Run only the cases whose description contains it. |
| `BASHX_VERBOSE` | you, or `bashx test -v` | Any value: show what passing cases print. |
| `NO_COLOR` | you | Any value: no colours. Read when `bashx.sh` is sourced. |
| `STATUS`, `STDOUT`, `STDERR` | `capture` | What the last captured command did. |

Names starting with `test::_` or `_TEST_` are internal: do not use them.

---

Previous: [Command line](cli.md) · Next: [How it works](how-it-works.md)
