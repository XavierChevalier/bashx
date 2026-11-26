# bashx

[![CI](https://github.com/XavierChevalier/bashx/actions/workflows/ci.yml/badge.svg)](https://github.com/XavierChevalier/bashx/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/XavierChevalier/bashx)](https://github.com/XavierChevalier/bashx/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Tests, coverage and mutation testing for bash.

- **Write tests** as plain bash functions: `assert "$(add 2 3)" == 5`, a
  command's status and outputs with `capture`, mocks that record their calls,
  tables of cases, temp dirs. Every case runs isolated: errexit on, its own
  subshell, its own tmp dir. A failure names its line and shows a diff.
- **Run them** in parallel with `bashx test`: per-file deadlines, no leaked
  processes, CI shards, Markdown / JSON / JUnit reports.
- **Measure line coverage** with `bashx test --coverage=DIR`, and list the
  lines no test runs.
- **Check the tests themselves** with `bashx mutate`: it changes one operator
  of your script at a time (`-gt` → `-ge`, `&&` → `||`, a command deleted…)
  and tells you which changes no test notices.

Tests are plain bash (≥ 5) with no dependency; the `bashx` command is a
single binary (Go), built or downloaded by `bin/bashx` on first use. bashx
tests itself: 93 cases, 99 % of the test API's lines and 86 % of the
command's statements covered.

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
  assert "$(calc::add 2 3)" == 5
  assert "$(calc::add 2 -3)" == -1
}

test::main
```

Every `test_*` function is a case, named after the function; `test::main`
runs them all.

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

[`examples/calculator`](examples/calculator) holds a small library with seven
cases. From there:

```console
$ bashx test --coverage=/tmp/cov examples/calculator
...
🧭 Coverage: covered=18 coverable=18 pct=100.0
📊 Test Summary: 7 passed, 0 failed, 7 total (111ms)
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
  capture calc::add 1 x
  assert "${STDERR}" == "calc: not an integer: 'x'"
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
| [Writing tests](docs/writing-tests.md) | [API](docs/api.md): every function and operator |
| [Running tests](docs/running-tests.md) | [How it works](docs/how-it-works.md) |
| [Coverage](docs/coverage.md) | [Troubleshooting](docs/troubleshooting.md) |
| [Mutation testing](docs/mutation-testing.md) | [Changelog](CHANGELOG.md) |
| [CI](docs/ci.md) | [Contributing and releases](CONTRIBUTING.md) |

## Requirements

- bash ≥ 5.0 for the test files, and the usual coreutils
- the `bashx` binary for your platform (Linux, macOS; amd64, arm64):
  `bin/bashx` builds it when Go is installed, takes it from the release
  archive, or downloads it once from the release (curl or wget)
- `bashx mutate`, `bashx coverage`: git

Tested on Linux and macOS (with a recent bash from Homebrew).

## License

[MIT](LICENSE)
