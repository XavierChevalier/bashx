[Documentation](README.md) › Getting started

# Getting started

From an empty directory to a tested function, with its coverage and mutation
score. You need [bashx installed](installation.md) and on your `PATH`.

## 1. A function to test

```bash
mkdir demo && cd demo
git init
```

`strings.sh`:

```bash
#!/usr/bin/env bash

# Prints <text>, cut to <max> characters with "…" when it is longer.
# Usage: strings::truncate <text> <max>
strings::truncate() {
  local -r text="$1" max="$2"
  if [[ "${#text}" -le "${max}" ]]; then
    echo "${text}"
  else
    echo "${text:0:max-1}…"
  fi
}
```

## 2. Its first test

Next to it, `strings.test.sh`:

```bash
#!/usr/bin/env bash
source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"
source "$(dirname "${BASH_SOURCE[0]}")/strings.sh"

test_should_keep_a_short_text() {
  assert "$(strings::truncate "hello" 10)" == "hello"
}

test::main
```

- Line 2 loads the test API. Line 3 loads the code under test.
- A case is a function whose name starts with `test_`. Its name is its
  description: `should keep a short text`.
- `assert <actual> <operator> <expected>` checks one thing.
- `test::main`, the last line, runs every `test_*` function in order, prints
  the result and makes the file fail if a case failed.

## 3. Run it

```console
$ bashx test
🧪 ./strings.test.sh
│  ✓ should keep a short text (7ms)
└── ✓ All 1 tests passed (18ms)

📊 Test Summary: 1 passed, 0 failed, 1 total (112ms)
```

`bashx test` found every `*.test.sh` under the project and ran them. A single
file also runs alone: `bash strings.test.sh`.

## 4. A failing test

Add a second case before `test::main`, with a wrong expectation on purpose:

```bash
test_should_cut_a_long_text() {
  assert "$(strings::truncate "hello world" 6)" == "hello w…"
}
```

```console
$ bashx test
🧪 ./strings.test.sh
│  ✓ should keep a short text (5ms)
│  ✗ should cut a long text (9ms)
│    ✗ strings.test.sh:10  assert "$(strings::truncate "hello world" 6)" == "hello w…"
│      expected: hello w…
│      actual:   hello…
└── ✗ Failed: 1 / Passed: 1 / Total: 2 (32ms)

📊 Test Summary: 1 passed, 1 failed, 2 total (113ms)

Failed test files:
  • strings.test.sh
$ echo $?
1
```

The failure names the line and shows both values. The function is right:
6 characters is 5 letters and `…`. Fix the expectation
to `"hello…"`, and the suite passes again.

## 5. Coverage: which lines ran?

Go back to the first version for a moment (only the short-text case), and
measure:

```console
$ bashx test --coverage=coverage
🧭 Coverage: covered=3 coverable=4 pct=75.0
...
$ bashx coverage report -f uncovered coverage/covered.tsv
strings.sh:10: echo "${text:0:max-1}…"
```

Line 10, the cutting branch, never ran. With the long-text case of step 4:

```console
$ bashx test --coverage=coverage
🧭 Coverage: covered=4 coverable=4 pct=100.0
```

Add `coverage/` to `.gitignore`.

## 6. Mutation testing: would the tests notice a bug?

Every line runs. Now let bashx change the code, one operator at a time, and
see whether a test fails:

```console
$ bashx mutate strings.sh
### `strings.sh`

Tests: `strings.test.sh` (46 ms unmutated) · order 1 · 1 s

| Operator | Mutation | Mutants | Killed | Timeout | Survived | Invalid | Score |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| rel-le | `-le` → `-lt` | 1 | 0 | 0 | 1 | 0 | 0.0% |
| cond-neg | `[[` → `[[ !` | 1 | 1 | 0 | 0 | 0 | 100.0% |
| stmt-del | command → `:` | 3 | 3 | 0 | 0 | 0 | 100.0% |
| **Total** |  | 5 | 4 | 0 | 1 | 0 | 80.0% |

Survivors (1)
- `strings.sh:7` rel-le: `if [[ "${#text}" -le "${max}" ]]; then` → `if [[ "${#text}" -lt "${max}" ]]; then`
```

With `-lt` instead of `-le`, a text of exactly `max` characters would be cut,
and no test notices: the boundary is not tested. Add it:

```bash
test_should_keep_a_text_of_exactly_the_maximum() {
  assert "$(strings::truncate "hello" 5)" == "hello"
}
```

```console
$ bashx mutate strings.sh
...
| **Total** |  | 5 | 5 | 0 | 0 | 0 | 100.0% |
```

Every change bashx can make to `strings.sh` now breaks a test.

`bashx mutate` works on copies of the files git knows about (committed or
not, but not ignored), so run it inside a git repository.

## 7. The final test file

```bash
#!/usr/bin/env bash
source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"
source "$(dirname "${BASH_SOURCE[0]}")/strings.sh"

test_should_keep_a_short_text() {
  assert "$(strings::truncate "hello" 10)" == "hello"
}

test_should_keep_a_text_of_exactly_the_maximum() {
  assert "$(strings::truncate "hello" 5)" == "hello"
}

test_should_cut_a_long_text() {
  assert "$(strings::truncate "hello world" 6)" == "hello…"
}

test::main
```

The same cases as a table, one row each:

```bash
test_should_truncate() {
  assert "$(strings::truncate "$1" "$2")" == "$3"
}
test::cases test_should_truncate <<'EOF'
hello          10  hello
hello          5   hello
"hello world"  6   hello…
EOF

test::main
```

## Where to go next

- [Writing tests](writing-tests.md): exit codes and errors, mocks, hooks,
  fixtures, testing whole scripts.
- [API](api.md): every operator and function.
- [Command line](cli.md): every option of `test`, `coverage` and `mutate`.
- [CI](ci.md): run this on every push.

---

Previous: [Installation](installation.md) · Next: [Writing tests](writing-tests.md)
