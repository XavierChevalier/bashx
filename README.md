# bashx

[![CI](https://github.com/XavierChevalier/bashx/actions/workflows/ci.yml/badge.svg)](https://github.com/XavierChevalier/bashx/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/XavierChevalier/bashx)](https://github.com/XavierChevalier/bashx/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Tests, coverage and mutation testing for bash, in bash.

- **Write tests** as plain bash functions, with assertions, mocks and temp dirs.
  Every case runs isolated: errexit on, its own subshell, its own tmp dir.
- **Run them** in parallel with `bashx test`: per-file deadlines, no leaked
  processes, CI shards, Markdown / JSON / JUnit reports.
- **Measure line coverage** with `bashx test --coverage=DIR`, and list the
  lines no test runs.
- **Check the tests themselves** with `bashx mutate`: it changes one operator
  of your script at a time (`-gt` → `-ge`, `&&` → `||`, a command deleted…)
  and tells you which changes no test notices.

No dependency beyond bash ≥ 5 and the usual coreutils. bashx tests itself:
83 cases, 90 % line coverage.

## Install

```bash
git clone https://github.com/XavierChevalier/bashx.git ~/.bashx
ln -s ~/.bashx/bin/bashx ~/.local/bin/bashx   # any directory on your PATH
bashx version
```

Or vendor it in your project, so CI needs nothing else:

```bash
git submodule add https://github.com/XavierChevalier/bashx.git vendor/bashx
vendor/bashx/bin/bashx test
```

Requirements, macOS, updating and the other ways to install:
[Installation](docs/installation.md).

## Quick start

A script to test, `calc.sh`:

```bash
calc::add() {
  echo $(($1 + $2))
}
```

Its tests, `calc.test.sh`, next to it:

```bash
#!/usr/bin/env bash
source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"
source "$(dirname "${BASH_SOURCE[0]}")/calc.sh"

test_should_add_two_integers() {
  test::assert_equals 5 "$(calc::add 2 3)"
  test::assert_equals -1 "$(calc::add 2 -3)"
}

test::init
test::run "should add two integers" test_should_add_two_integers
test::summary
```

Run every `*.test.sh` of the project:

```console
$ bashx test
🧪 ./calc.test.sh
│  ✓ should add two integers (8ms)
└── ✓ All 1 tests passed (31ms)

📊 Test Summary: 1 passed, 0 failed, 1 total (52ms)
```

A test file is also a plain script: `bash calc.test.sh` runs it alone.

## A full example

[`examples/calculator`](examples/calculator) holds a small library with five
cases. From there:

```console
$ bashx test --coverage=/tmp/cov examples/calculator
...
🧭 Coverage: covered=18 coverable=18 pct=100.0
📊 Test Summary: 5 passed, 0 failed, 5 total (111ms)
```

Every line runs. Are the tests checking what those lines do?

```console
$ bashx mutate examples/calculator/calc.sh
| Operator | Mutation | Mutants | Killed | Timeout | Survived | Invalid | Score |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| arith-add | `+` → `-` | 1 | 1 | 0 | 0 | 0 | 100.0% |
| … | | | | | | | |
| logic-or | `\|\|` → `&&` | 3 | 3 | 0 | 0 | 0 | 100.0% |
| stmt-del | command → `:` | 12 | 11 | 0 | 1 | 0 | 91.7% |
| **Total** |  | 22 | 21 | 0 | 1 | 0 | 95.5% |

Survivors (1)
- `examples/calculator/calc.sh:42` stmt-del: `echo "calc: not an integer: '${arg}'" >&2` → `:`
```

Deleting the error message changes nothing the tests see: they check the exit
code of a bad input, never what the user is told. One assertion kills it:

```bash
test_should_name_the_bad_input() {
  test::assert_equals "calc: not an integer: 'x'" "$(calc::add 1 x 2>&1)"
}
```

That is the point of mutation testing: coverage says a line ran, a mutation
score says a test would notice if it were wrong. The example ships with this
gap left open, to try it.

## Documentation

Start with **[Getting started](docs/getting-started.md)**: a first project, from
an empty directory to 100 % coverage and mutation score. Everything else is
in the **[documentation index](docs/README.md)**:

| Guides | Reference |
| --- | --- |
| [Installation](docs/installation.md) | [Command line](docs/cli.md): every command, option, variable, exit code |
| [Writing tests](docs/writing-tests.md) | [API](docs/api.md): every `test::` function |
| [Running tests](docs/running-tests.md) | [How it works](docs/how-it-works.md) |
| [Coverage](docs/coverage.md) | [Troubleshooting](docs/troubleshooting.md) |
| [Mutation testing](docs/mutation-testing.md) | [Changelog](CHANGELOG.md) |
| [CI](docs/ci.md) | [Contributing and releases](CONTRIBUTING.md) |

## Requirements

- bash ≥ 5.0, find, awk, mktemp, sort (Linux: present everywhere)
- `bashx mutate`: git (it copies the tracked files), GNU `timeout`, `shuf`,
  `realpath`
- Optional: `perl` (per-file deadline and process-group cleanup in `bashx test`)

Tested on Linux. macOS needs a recent bash and GNU coreutils (Homebrew).

## License

[MIT](LICENSE)
