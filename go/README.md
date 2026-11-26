# bashx-go: a study

A Go port of `bashx test` (the runner and its markdown / json / junit
reporters) and of `bashx coverage` (`covered`, `report`), written to measure
what leaving bash for the tooling would bring. The results and the
recommendation are in [docs/go-runner-study.md](../docs/go-runner-study.md).

What did not change: the test files and their API. `lib/bashx.sh` is still
what a test file sources; the Go runner starts `bash <file>` exactly as the
bash one does, with the same environment (`BASHX_RESULT_FILE`,
`BASHX_CASES_FILE`, `BASHX_LIB`, `BASH_ENV` under `--coverage`) and reads the
same files back. `bashx-go mutate` hands over to `lib/mutation.sh`.

```bash
go -C go build -o bashx-go .
go/bashx-go test                        # same options as bin/bashx test
go/bashx-go coverage report coverage/covered.tsv
```

## Same behaviour, checked

- `lib/runner.test.sh` tests the runner as a black box; it runs against the Go
  port with `BASHX_TEST_RUNNER=go/runner-shim.bash bash lib/runner.test.sh`
  (24/24 pass; a CI job does it).
- On bashx's own suite, both runners give the same JSON report (cases,
  statuses, outputs, once durations are left out) and the same
  `covered.tsv`; `coverage report` gives the same result in every format, on
  real traces and on random coverage of every script.

Two deliberate differences: the failed files are listed in the order the run
planned them (the bash runner lists them in the order its polling loop saw
them finish), and a file's result is printed the moment it finishes, without
the bash runner's 0.1 s polling.

## Layout

```text
main.go       the command: dispatches like bin/bashx
runner.go     bashx test: discovery, shards, process groups, deadlines
status.go     the TTY status footer, signals
reports.go    markdown, json, junit
coverage.go   bashx coverage covered / report
```
