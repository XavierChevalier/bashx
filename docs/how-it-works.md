[Documentation](README.md) › How it works

# How it works

What bashx does under the hood: useful to debug a strange result, to write
test files without the API, or to reuse a part of bashx on its own.

## Layout

```text
bin/bashx                 the command: dispatches to lib/
lib/bashx.sh              the test API, sourced by test files
lib/runner.sh             bashx test
lib/coverage.sh           bashx coverage
lib/coverage-trace.bash   loaded into every traced bash process
lib/mutation.sh           bashx mutate
lib/reporters/*.sh        markdown, json, junit reports
```

Each `lib/*.sh` file also runs on its own (`bash lib/runner.sh --help`); `bin/bashx`
only sets `BASHX_LIB` and calls them.

## A case

`test::run` runs the case function in a subshell:

```bash
set +e
( set -e; "$@" )   # the case
status=$?
set -e
```

- The subshell is why nothing a case changes reaches the next one.
- `set -e` inside, and the subshell not being on the left of `||`, is why the
  first failure ends the case. (Bash turns errexit off in the whole left side
  of `||` and `&&`, including the functions it calls: a `( … ) || failed=1`
  would ignore failures.)
- Exit status 77 means skipped (`test::skip` exits with it).

## The runner protocol

For each test file, the runner:

1. reads the header for `# @requires`; skips the file if a command is missing;
2. starts `bash <file>` from the file's directory, with no stdin, in a new
   process group, under a deadline (`perl -e 'alarm …; exec …'`, which keeps
   working across `exec` and does not hold a pipe open);
3. passes `BASHX_RESULT_FILE` (where to write the counts) and `BASHX_LIB`;
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
   under `timeout` until one fails, then restores the file;
5. joins the results into the report.

Your working tree is only read, in step 1.

---

Previous: [API](api.md) · Next: [Troubleshooting](troubleshooting.md)
