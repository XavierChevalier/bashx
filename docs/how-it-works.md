[Documentation](README.md) › How it works

# How it works

What bashx does under the hood: useful to debug a strange result, to write
test files without the API, or to reuse a part of bashx on its own.

## Layout

```text
bin/bashx                 launcher: finds the binary, sets BASHX_LIB, runs it
cmd/bashx/                the binary (Go): bashx test, coverage, mutate
  runner.go, status.go      bashx test, its status footer
  reports.go                markdown, json, junit reports
  coverage.go               bashx coverage
  mutation.go               bashx mutate
lib/bashx.sh              the test API, sourced by test files
lib/coverage-trace.bash   loaded into every traced bash process
```

Test files are bash and only ever source `lib/bashx.sh`: the binary starts
them with `bash` and reads back the files the API writes.

## Finding the binary

`bin/bashx` answers `bashx lib` and `bashx version` itself, and runs the
binary for everything else, the first it finds of:

1. `$BASHX_BIN`;
2. in a checkout (`go.mod` next to `bin/`) with Go on the `PATH`:
   `.build/bashx`, built from `cmd/bashx` and rebuilt when a source file is
   newer than it;
3. `libexec/bashx-<os>-<arch>`, which the release archive ships;
4. `~/.cache/bashx/<version>/bashx-<os>-<arch>` (`XDG_CACHE_HOME`), downloaded
   once from the GitHub release of the launcher's version
   (`BASHX_RELEASES_URL`), with `curl` or `wget`, and checked against its
   `.sha256`.

## A case

`test::main` lists the file's functions with `declare -F`, keeps the
`test_*` ones, sorts them by the line they are defined on (`shopt -s
extdebug` gives it), and hands each one to `test::run`, which runs it in a
subshell:

```bash
set +e
(
  set -e
  PATH="<case dir>/.bin:${PATH}"          # where mock puts its executables
  trap after_each EXIT                     # when after_each exists
  before_each                              # when it exists
  "$@"                                     # the case
) >"<case dir>/.log" 2>&1 </dev/null
status=$?
set -e
[[ ! -e "<case dir>/.failed" ]] || status=1
```

- The subshell is why nothing a case changes reaches the next one.
- `set -e` inside, and the subshell not being on the left of `||`, is why the
  first failure ends the case. (Bash turns errexit off in the whole left side
  of `||` and `&&`, including the functions it calls: a `( … ) || failed=1`
  would ignore failures.)
- A failed `assert` does not rely on errexit: it creates `.failed` and exits.
  Under `if` or `||` it still ends the case; in a `$( )` it only leaves the
  substitution, but `.failed` marks the case failed anyway.
- The log is printed under the case when it fails or is skipped, or always
  with `BASHX_VERBOSE`.
- Exit status 77 means skipped (`test::skip` exits with it).

The cases run from `test::main`, not from the EXIT trap, although the trap
would save a line: on bash 5.0, a `return` without argument in any function
called under a trap returns the status from before the trap, which changes
what the code under test does (`check || return` would return 0). The trap
only fails a file whose `test_*` functions never ran.

## The runner protocol

For each test file, the runner:

1. reads the header for `# @requires`; skips the file if a command is missing;
2. starts `bash <file>` from the file's directory, with no stdin, in a new
   process group, under a deadline: past it, the file's bash gets `SIGALRM`
   and the file fails with a timeout;
3. passes `BASHX_RESULT_FILE` (where to write the counts),
   `BASHX_CASES_FILE` (where each case is recorded, for `--report`) and
   `BASHX_LIB`;
4. when the file ends, kills whatever is left in its process group;
5. reads the counts from the result file, or, without one, counts the file
   as one test passed or failed by its exit code;
6. counts the file as failed when it exits non-zero, whatever the counts say.

The result file is plain `key=value` lines:

```text
passed=3
failed=0
skipped=1
total=4
duration_ms=27
```

`test::run` appends one line per case to `BASHX_CASES_FILE`:
`<status> TAB <ms> TAB <name> TAB <output>`, status `passed`, `failed` or
`skipped`, the output being what the console shows of the case (colors
stripped), backslashes, tabs and newlines written `\\`, `\t` and `\n`. A file
that records no case, or fails with no failed case (a crash, a timeout), gets
one `(whole file)` case with its output in the reports.

### Test files without the API

Any executable bash file named `*.test.sh` works with the runner: exit 0 for
success, non-zero for failure. To report several cases from your own code,
write the result file:

```bash
#!/usr/bin/env bash
passed=0 failed=0
for input in 1 2 3; do
  if my_check "${input}"; then passed=$((passed + 1)); else failed=$((failed + 1)); fi
done
if [[ -n "${BASHX_RESULT_FILE:-}" ]]; then
  printf 'passed=%d\nfailed=%d\ntotal=%d\n' "${passed}" "${failed}" $((passed + failed)) >"${BASHX_RESULT_FILE}"
fi
((failed == 0))
```

## Coverage tracing

`bashx test --coverage=DIR` exports `BASH_ENV=lib/coverage-trace.bash` to each
test file. Bash sources `BASH_ENV` at the start of every non-interactive bash
process, so every bash the tests start (the test file, the scripts it runs,
`bash -c`) loads the tracer. The tracer:

1. opens `DIR/traces/<pid>.trace` on a new file descriptor;
2. writes `#cwd <directory>` (to resolve relative paths later);
3. sets `BASH_XTRACEFD` to that descriptor, `PS4='+${BASH_SOURCE}:${LINENO}: '`
   and `set -x`.

Stdout and stderr are untouched: tests checking them still pass. At the end,
`bashx coverage covered` turns the traces into `path<TAB>line` pairs under
the root, and `bashx coverage report` maps each traced line to the start of
its statement and scores it.

Because it relies on `BASH_ENV`, a script started with `env -i`, or by
another shell (`sh script.sh`), is not traced.

## Mutation sandboxes

`bashx mutate`:

1. copies the project's files (`git ls-files --cached --others
   --exclude-standard`) into one directory per job, and commits each copy in
   a fresh git repository;
2. runs the tests once on the unchanged code: they must pass, and their
   duration sets the deadline (3 × the duration + 5 s, at least 10 s);
3. lists the mutants: for each code line and each operator, one mutant per
   place the operator matches;
4. splits them over the jobs; each job, for each of its mutants, writes the
   mutated file, checks it parses (`bash -n`), runs the test files one by one
   until one fails (each in its own process group, sent `SIGTERM` at the
   deadline and `SIGKILL` 5 s later), then restores the file;
5. joins the results into the report.

Your working tree is only read, in step 1.

---

Previous: [API](api.md) · Next: [Troubleshooting](troubleshooting.md)
