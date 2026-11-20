[Documentation](README.md) › Command line

# Command line reference

```text
bashx <command> [options]
```

| Command | Does |
| --- | --- |
| [`bashx test`](#bashx-test) | run the test files |
| [`bashx coverage report`](#bashx-coverage-report) | score a coverage run, list untested lines |
| [`bashx coverage covered`](#bashx-coverage-covered) | turn raw traces into covered lines (low level) |
| [`bashx mutate`](#bashx-mutate) | mutation testing |
| [`bashx lib`](#bashx-lib) | print the library directory |
| [`bashx version`](#bashx-version) | print the version |
| `bashx help` | list the commands (also `bashx`, `-h`, `--help`) |

An unknown command exits with code 2.

---

## bashx test

```text
bashx test [options] [<root>]
```

Runs every `*.test.sh` under `<root>`. Without `<root>`: the git root of the
current directory, or the current directory outside git. Details:
[Running tests](running-tests.md).

| Option | Default | Effect |
| --- | --- | --- |
| `--kind=KIND` | all files | Only files named `*.KIND.test.sh`. `KIND` is any word: `unit`, `integration`, `slow`… |
| `--jobs=N` | CPU count, or `BASHX_JOBS` | Number of files running at the same time. `--jobs=1` runs them one by one. |
| `--timeout=SECONDS` | 60, or `BASHX_TIMEOUT` | Deadline of each file. Past it, the file and every process it started are killed, and the file fails with `⏱️ TIMEOUT after Ns`. Needs `perl`. |
| `--shard=I/N` | `1/1` | Run only part `I` of `N` (CI matrix). Every file belongs to exactly one shard. |
| `--durations=FILE` | `<root>/.bashx/durations.tsv` | Durations used to balance shards and start long files first. A missing file is fine. |
| `--record-durations=FILE` | | Write each file's duration to `FILE` (directories created). |
| `--coverage=DIR` | | Trace the run, write `DIR/covered.tsv`, print `🧭 Coverage: covered=… coverable=… pct=…`. See [Coverage](coverage.md). |
| `--report=FORMAT` | | Also write `test_report.FORMAT` in the current directory: `markdown`, `json` or `junit`. |
| `-h`, `--help` | | Print the help. |

Options use the `--name=value` form (no space).

### Examples

```bash
bashx test                                    # the whole project
bashx test tests/integration                  # one directory
bashx test --kind=unit --jobs=4               # unit tests, 4 at a time
bashx test --timeout=300 --report=junit       # slow suite, JUnit for the CI
bashx test --shard=2/3                        # second third of the files
bashx test --coverage=coverage                # with line coverage
bashx test --record-durations=.bashx/durations.tsv
```

### Output files

| File | Written when | Content |
| --- | --- | --- |
| `test_report.markdown` | `--report=markdown` | counts table, failed files, full output |
| `test_report.json` | `--report=json` | `{"summary": {"passed", "failed", "skipped", "total", "files"}, "failed_files": [...], "output": "..."}` |
| `test_report.junit` | `--report=junit` | JUnit XML: totals, one `testcase` per failed file |
| `DIR/covered.tsv` | `--coverage=DIR` | `path<TAB>line` for each project line that ran |
| `FILE` | `--record-durations=FILE` | `seconds<TAB>path` per file, sorted by path |

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | every file passed; skipped files and cases count as passed |
| 1 | a file failed or timed out, no test file was found, or the report format is unknown |
| 2 | invalid option, `--jobs`, `--timeout`, `--shard`, or a root that is not a directory |
| 130 | interrupted (Ctrl-C) |

---

## bashx coverage report

```text
bashx coverage report [-r <root>] [-x <regex>] [-f <format>] <covered.tsv>...
```

Scores one or more `covered.tsv` files (their union) against the project's
scripts.

| Option | Default | Effect |
| --- | --- | --- |
| `-r <root>` | git root of the current directory, or the current directory | Project root the paths are relative to. |
| `-x <regex>` | | Leave out scripts whose path matches this extended regex, e.g. `'^(vendor\|examples)/'`. Test files, `fixtures/` and a vendored bashx are always left out. |
| `-f <format>` | `summary` | Output format, below. |
| `-h` | | Print the help. |

| Format | Output |
| --- | --- |
| `summary` | `covered=660 coverable=730 pct=90.4` |
| `markdown` | `**Coverage:** 90.4% of bash lines (660/730)` |
| `tsv` | `path<TAB>covered<TAB>coverable`, one row per script, with a header |
| `uncovered` | `path:line: code` for every coverable line no test ran, sorted |

```bash
bashx coverage report coverage/covered.tsv
bashx coverage report -f uncovered coverage/covered.tsv
bashx coverage report -x '^vendor/' -f markdown shard-*/covered.tsv
```

Exit code 1 on a usage error or an unknown format.

## bashx coverage covered

```text
bashx coverage covered [-r <root>] <trace dir>
```

Reads the raw traces `bashx test --coverage` collects and prints
`path<TAB>line` for each project line they ran. `bashx test --coverage` calls
it for you; use it only to work on traces collected another way (see
[How it works](how-it-works.md#coverage-tracing)).

---

## bashx mutate

```text
bashx mutate [options] <script>...
```

Mutation testing of each `<script>` against its tests. Runs inside a git
repository. Details: [Mutation testing](mutation-testing.md).

| Option | Default | Effect |
| --- | --- | --- |
| `-t <test>` | the script's own tests: `<dir>/<name>.test.sh` and `<dir>/<name>.*.test.sh` | Test file to run. Repeat for several. Applies to every script given. |
| `-o <ops>` | all operators | Comma-separated operator names or groups: `rel`, `str`, `arith`, `cond`, `logic`, `ret`, `bool`, `stmt-del`, or full names like `arith-add`. |
| `-k <order>` | `1` | `1`: one mutation per mutant. `2`: two mutations, on two different lines. |
| `-m <max>` | `0` (all) | Run at most `max` mutants, sampled the same way on every run. |
| `-j <jobs>` | CPU count | Parallel copies of the project. |
| `-T <seconds>` | 3 × unmutated test time + 5, at least 10 | Deadline of one test file against one mutant. Past it, the mutant counts as killed (timeout). |
| `-s <score>` | off | Exit 1 when a script's score is under `score` percent. |
| `-r <file>` | | Also write one TSV row per mutant: `script id operator status ms line text`. |
| `-n` | | Dry run: print the number of mutants and pairs per script, run nothing. |
| `-L` | | Print the operators table. |
| `-h` | | Print the help. |

### Examples

```bash
bashx mutate lib/backup.sh                         # one script
bashx mutate lib/*.sh                              # several, with a summary table
bashx mutate -n lib/*.sh                           # how many mutants?
bashx mutate -o rel,logic lib/backup.sh            # only comparisons and && / ||
bashx mutate -t tests/backup_e2e.test.sh lib/backup.sh
bashx mutate -s 90 lib/backup.sh                   # fail under 90 %
bashx mutate -k 2 -m 200 lib/backup.sh             # 200 sampled pairs
bashx mutate -r mutants.tsv lib/backup.sh >report.md
```

### Output

The Markdown report goes to stdout; progress lines (`mutation: 12/40`) go to
stderr every 10 seconds.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | done (whatever the score, unless `-s`) |
| 1 | a script scored under `-s`, or its tests fail before any mutation |
| 2 | usage error, no operator matches `-o`, no test found for a script, not in a git repository |

---

## bashx lib

```console
$ bashx lib
/home/me/.bashx/lib
```

The directory holding `bashx.sh`. Test files source it with
`source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"`.

## bashx version

<!-- x-release-please-start-version -->
```console
$ bashx version
bashx 0.1.0
```
<!-- x-release-please-end -->

Also `bashx --version` and `bashx -v`.

---

## Environment variables

| Variable | Used by | Effect |
| --- | --- | --- |
| `BASHX_JOBS` | `bashx test` | Default of `--jobs`. |
| `BASHX_TIMEOUT` | `bashx test` | Default of `--timeout`. |
| `BASHX_PLAIN_OUTPUT` | `bashx test` | Any value: no live status line, even in a terminal. |
| `CI` | `bashx test` | Any value: same as `BASHX_PLAIN_OUTPUT`. Set by most CI systems. |
| `NO_COLOR` | test files, `bashx test` | Any value: no colours ([no-color.org](https://no-color.org)). |
| `TMPDIR` | everything | Where temporary directories are created (default `/tmp`). |
| `BASHX_LIB` | test files | Set by `bashx`; read by test files to find `bashx.sh`. |
| `BASHX_RESULT_FILE` | test files | Set by the runner for each file: where `test::summary` writes the counts. |
| `BASHX_COVERAGE_TRACE_DIR` | traced processes | Set by `bashx test --coverage`: where each bash process writes its trace. |

The last three are set by bashx itself; see [How it works](how-it-works.md).

---

Previous: [CI](ci.md) · Next: [API](api.md)
