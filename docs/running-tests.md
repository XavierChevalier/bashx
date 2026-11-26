[Documentation](README.md) › Running tests

# Running tests

```bash
bashx test                 # every *.test.sh under the git root (or the current dir)
bashx test tests/          # under another root
bashx test --kind=unit     # only *.unit.test.sh
bashx test --filter=retry  # only the cases whose description contains "retry"
bashx test -v              # also show what passing cases print
bash path/to/x.test.sh     # one file, without the runner
BASHX_FILTER=retry bash path/to/x.test.sh
```

## What the runner does

- **Finds** every `*.test.sh` under the root, skipping `.git`,
  `node_modules`, `venv`, `.venv`, `.cache`, `.bashx`, and nested git
  repositories (submodules, vendored clones: their tests are theirs to run).
- **Runs** them in parallel, each from its own directory, with no stdin.
- **Streams** each file's output as soon as it finishes, then prints a
  summary. In a terminal a status line shows the files still running; it is
  off in CI, outside a TTY and with `BASHX_PLAIN_OUTPUT=1`.
- **Counts** cases from what each file reports. A file that does not use
  the API counts as one test, passed when it exits 0.
- **Fails** (exit 1) when any file exits non-zero or reports a failed case.

```text
🧪 ./calc.test.sh
│  ✓ should add two integers (8ms)
│  ✗ should divide towards zero (9ms)
└── ✗ Failed: 1 / Passed: 1 / Total: 2 (40ms)

📊 Test Summary: 1 passed, 1 failed, 2 total (61ms)

Failed test files:
  • calc.test.sh
```

## Options

Every option, with its exact syntax and exit codes, is in the
[command line reference](cli.md#bashx-test). In short:

| Option | Default | Effect |
| --- | --- | --- |
| `--kind=KIND` | all | Only `*.KIND.test.sh`. |
| `--jobs=N` | CPU count (`BASHX_JOBS`) | Files run at the same time. |
| `--timeout=SECONDS` | 60 (`BASHX_TIMEOUT`) | Deadline per file. Past it the file is killed with every process it started, and fails. |
| `--shard=I/N` | `1/1` | Run part I of N. See [CI](ci.md). |
| `--durations=FILE` | `<root>/.bashx/durations.tsv` | Durations used to balance shards and start long files first. |
| `--record-durations=FILE` | | Write each file's duration (`seconds<TAB>path`). |
| `--coverage=DIR` | | Measure line coverage: see [Coverage](coverage.md). |
| `--report=FORMAT` | | Also write `test_report.markdown`, `.json` or `.junit` in the current directory, with each case and the output of the failed ones. See [the formats](cli.md#output-files). |
| `--filter=TEXT` | | Only the cases whose description contains `TEXT`. |
| `-v`, `--verbose` | | Show what passing cases print; by default a case's output shows only when it fails or is skipped. |

## Isolation

Each file runs in its own process group with a deadline. When the file ends, every process it left behind is killed: a
`sleep 300 &` forgotten in a test cannot outlive the suite or hold its output
open.

## Skipping files

A file whose header lists commands with `# @requires` is skipped unless all of
them are on `PATH`:

```bash
#!/usr/bin/env bash
# Integration tests against a real database.
# @requires docker psql
```

The comment has to come before the first command of the file.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | every file passed (skipped ones included) |
| 1 | a file failed, timed out, or no test file was found |
| 2 | bad option or root |

---

Previous: [Writing tests](writing-tests.md) · Next: [Coverage](coverage.md)
