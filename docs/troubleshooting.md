[Documentation](README.md) › Troubleshooting

# Troubleshooting

## Installation

**`bashx: command not found`**
The directory holding the `bashx` link is not on your `PATH`. Check with
`echo "${PATH}"`, then add it, e.g. `export PATH="${HOME}/.local/bin:${PATH}"`
in `~/.bashrc`. See [Installation](installation.md#a-clone-and-link).

**`EPOCHREALTIME: unbound variable`, `declare: -A: invalid option`, `mapfile: command not found`**
Bash is older than 5.0 (macOS ships 3.2). Install a recent bash and make sure
it comes first on the `PATH`: [macOS](installation.md#requirements).

**A test file run alone fails with `bashx: command not found` on its first line**
`source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"` needs `bashx` on the `PATH`
when `BASHX_LIB` is not set. Either install it on the `PATH`, or run
`BASHX_LIB=vendor/bashx/lib bash my.test.sh`, or run it through
`bashx test path/to/dir`.

## bashx test

**`No test files (*.test.sh) under …`**
The runner only picks files named `*.test.sh`. Rename `test_foo.sh` to
`foo.test.sh`. Files under `.git`, `node_modules`, `venv`, `.venv`, `.cache`
and `.bashx` are ignored, and so are nested git repositories: a directory
with its own `.git` (a submodule, a clone) is a separate project. Run
`bashx test <that directory>` to test it.

**A case fails with no "Assertion failed" message**
A command failed before any assertion, and errexit ended the case. Its error
went to stderr, which is shown with the case: look just above the `✗` line.
Typical causes: an unset variable (`set -u`), `((n++))` with `n=0`, a
`grep` that found nothing.

**A function under test goes on after a failed check**
Bash ignores errexit in anything called from `if`, `while`, `!`, `||` or
`&&`, so a check that relies on errexit does not stop the function there.
Make the check explicit: `validate "$@" || return`. See
[bash pitfalls](writing-tests.md#bash-pitfalls-that-tests-meet).

**`⏱️ TIMEOUT after 60s: killed …`**
The file ran past its deadline. Either a test waits for something that never
comes (stdin is closed: a `read` gets end of file; a server that never
answers…), or the file is just slow: raise the deadline with
`--timeout=300` or `BASHX_TIMEOUT=300`.

**The file passes alone but fails under `bashx test`**
Under the runner the file starts from its own directory, has no stdin, and
runs next to other files. Check for paths relative to where you used to run
it, a `read` from the terminal, or two files writing the same fixed path
(use `test::tmp_dir`). `--jobs=1` tells whether parallelism is the cause.

**The live status line garbles the CI log**
It turns off when `CI` is set or the output is not a terminal; set
`BASHX_PLAIN_OUTPUT=1` to force it off.

## Coverage

**`covered=0 coverable=0`**
No script was found under the root. Coverage counts the `*.sh` files git
tracks or would track (not ignored), minus tests and `fixtures/`. Check the
root (`-r`), and that the scripts end in `.sh`.

**A script the tests run shows 0 covered lines**
It is not traced if it is started by another shell (`sh script.sh`, a
`#!/bin/sh` shebang), with a cleared environment (`env -i`), or from outside
the root. Run bash scripts with bash.

**Lines I would count are ignored**
Only the first line of a multi-line command counts, and structural lines
(`then`, `fi`, `}`…) never do. This is on purpose: see
[what is measured](coverage.md#what-is-measured).

## Mutation testing

**`error: bashx mutate runs inside a git repository`**
Run `git init` (no commit needed: untracked files are copied too, ignored
ones are not).

**`error: <test> fails before any mutation (exit 1): fix it first`**
The tests must pass on the unchanged code. Run them with `bashx test` and
fix them first. Under `bashx mutate`, they run from a copy of the project:
a test that reads a file outside the project, or an ignored file, can pass
in place and fail there.

**`error: no test for lib/x.sh: pass -t <test>`**
No `lib/x.test.sh` or `lib/x.*.test.sh` next to the script. Name the tests
that cover it with `-t`.

**Many `timeout` results**
A mutant made a loop endless, and the deadline killed it: that counts as
killed. If the run is slow because of them, lower the deadline with `-T`.

**A survivor I cannot kill**
It may be an equivalent mutant: the change cannot be observed. Mark the line
`# no-mutate: <reason>`. Check first whether the code can be simpler: see
[reading survivors](mutation-testing.md#reading-survivors).

**It takes too long**
Each mutant runs the tests once. Count first (`-n`), restrict operators
(`-o rel,logic`), sample (`-m 100`), and make the script's own tests fast:
they are the ones that run.

---

Previous: [How it works](how-it-works.md) · [Back to the index](README.md)
