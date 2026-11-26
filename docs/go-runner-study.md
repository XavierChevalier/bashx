[Documentation](README.md) › Study: a Go runner

# Study: the tooling in Go (or Rust)?

The question: would bashx run faster with its tooling (`bashx test`, the
reporters, `bashx coverage`) written in a compiled language, the test API
staying as it is? To answer it with numbers, [`go/`](../go) holds a Go port
of that tooling, and [`bench/run.bash`](../bench/run.bash) compares the two
versions on the same test files.

## What was ported, what was not

| Part | Ported | Why |
| --- | --- | --- |
| `lib/bashx.sh` (the test API) | no | It runs inside the test file's bash: `assert`, `capture`, `mock` and the per-case subshell are bash by nature. Changing it would change the API. |
| `bashx test` (`lib/runner.sh`) | yes | Discovery, shards, process groups, deadlines, the status footer. |
| reporters (`lib/reporters/*.sh`) | yes | They loop over every case. |
| `bashx coverage covered / report` | yes | They parse every trace and every script. |
| `bashx mutate` | no | Its time goes into running the tests on each mutant. `bashx-go mutate` runs `lib/mutation.sh`. |

The protocol between the runner and a test file did not change:
`bash <file>` from the file's directory, in its own process group,
`BASHX_RESULT_FILE` / `BASHX_CASES_FILE` / `BASHX_LIB`, and `BASH_ENV` set to
the tracer under `--coverage`.

**Same behaviour, checked:** `lib/runner.test.sh` (24 black-box cases) passes
against the Go runner (`BASHX_TEST_RUNNER=go/runner-shim.bash`). On bashx's own
suite, both runners write the same JSON report once durations are left out,
and the same `covered.tsv`. `coverage report` gives the same result in every
format and with `-x`, on the real traces and on 5 random coverages of every
script.

## Why Go rather than Rust

Both would give the same numbers here: the time goes into the bash processes
the runner starts, not into the runner (the Go runner uses 2 ms of CPU per test
file). What tips the choice:

- process groups, signals and deadlines, a worker pool and channels are
  in Go's standard library; there is a single dependency (`golang.org/x/term`,
  for the TTY footer);
- one static binary per OS and architecture, from one `GOOS=… GOARCH=… go
  build` command;
- the code reads close to the bash, which made checking it line by line
  easier.

Rust would start 1 to 2 ms faster and make a smaller binary (Go: 3.8 MB).
Neither matters next to a bash that takes 10 ms to start.

## Results

`bench/run.bash 3`: bash 5.2.21, Go 1.24.7, 4 jobs on 4 CPUs, median of 3 runs
after a warm-up. CPU is user + sys, for the runner and everything it waited
for.

| Scenario | bash wall (ms) | Go wall (ms) | bash CPU (ms) | Go CPU (ms) | Wall speed-up |
| --- | ---: | ---: | ---: | ---: | ---: |
| startup: `test --help` | 11 | 2 | 11 | 2 | ×5.5 |
| 200 files `exit 0` (no API) | 8007 | 120 | 6367 | 375 | ×66.7 |
| 40 files `sleep 0.05` | 1570 | 544 | 1290 | 161 | ×2.9 |
| 50 files × 20 cases (API) | 4646 | 3436 | 13671 | 11953 | ×1.35 |
| same + `--report=json` | 7761 | 3513 | 16731 | 12067 | ×2.2 |
| same + `--report=junit` | 16281 | 3687 | 26115 | 12748 | ×4.4 |
| `coverage covered` (197 traces, 13 MB) | 1213 | 246 | 1192 | 279 | ×4.9 |
| `coverage report` | 58 | 6 | 76 | 8 | ×9.7 |
| bashx's own suite (112 cases) | 14173 | 14088 | 10484 | 10283 | ×1.01 |
| bashx's own suite `--coverage` | 15629 | 14343 | 12404 | 10647 | ×1.09 |

## What the numbers say

**1. On a real suite, the runner barely counts.** bashx's own suite runs in
the same 14 s with both (+1 %, and +9 % with coverage). Its time goes into its
tests. The slowest file, `mutation.test.sh`, runs whole mutation sessions.

**2. The floor is the test API.** A case costs about 11 ms in `lib/bashx.sh`,
whichever runner starts the file: a file of 100 `assert 1 == 1` takes 1.1 s on
its own with `bash f.test.sh`. Each case forks a subshell, calls `mktemp`,
`mkdir` and `rm`, and makes two `$(test::_now_us)` and, for the reports, two
`$(test::_escape …)`. That is why "50 × 20 cases" only gains ×1.35. A Go
runner cannot go below this floor, because the floor is in bash.

**3. Where the bash runner loses, it loses heavily, and for two reasons:**

- *the polling loop.* `runner::run_all` sleeps 0.1 s whenever no file has
  finished, so a short file costs at least one 0.1 s tick. With
  `STATUS_POLL_INTERVAL=0.01`, the 200 empty files go from 8.0 s to 3.6 s
  with the bash runner, and nothing else changes;
- *forks per file.* Without the sleep, a file still costs about 30 ms of CPU
  in the bash runner (`$( )`, `awk`, `cat`, `tee`, `perl`, `env`…), against
  2 ms in Go.

**4. The reporters grow with the number of cases.** The JSON reporter makes
4 `$( )` per case, and the JUnit one runs one more `awk` per case: +3 s and
+11.6 s for 1,000 cases. In Go, writing a report takes under 10 ms.

**5. Coverage post-processing:** ×5 on `covered` (awk reading 13 MB of
traces) and ×10 on `report`. That is 1 s saved on a run of 15 s.

## Cost of switching

- **Distribution.** bashx says "no dependency beyond bash ≥ 5 and the usual
  coreutils", and installs with `git clone` or `git submodule add`. A Go runner
  would need a binary per OS and architecture, built and attached to each
  release, and a download step in CI and in the submodule setup. Or every user
  would need a Go toolchain.
- **Two implementations to keep in step**, or the bash runner dropped, and
  with it `bash lib/runner.sh` on a machine that only has bash.
- **A second language** for contributors to a project about bash, tested
  with itself.

## Recommendation

Stay in bash, and fix the hotspots the benchmark found. They explain most of
the gap, and fixing them keeps the "bash only" promise:

1. **Runner polling**: have the workers notify the main loop when they finish
   (a FIFO read with `read -t`), or shorten the tick. The bash runner then
   loses its main handicap on suites of many short files (measured: −55 % on
   200 empty files with a 0.01 s tick).
2. **Reporters**: write each report in a single `awk` over `cases.tsv`,
   instead of `$( )` and `printf '%b'` per case.
3. **Per-case cost in `lib/bashx.sh`**, without changing the API: read
   `EPOCHREALTIME` directly instead of `$(test::_now_us)`, escape into a
   variable instead of through `$( )`, create the case dir without `mktemp`.
   This lowers the floor for both runners, so it is the largest gain on a real
   suite.

The Go runner would be worth it if suites of hundreds of very short files
became the common case (×66 on that scenario), or if a feature needs
something bash does badly: watch mode, live streaming of the cases. Its
measured equivalence (the same tests, the same reports) makes that option
cheap to take up later. Until then, `go/` stays a study: built and tested in
CI, not distributed.

## Run it again

```bash
go -C go build -o bashx-go .
bench/run.bash 5            # BENCH_JOBS=8 to change the parallelism
```

---

Previous: [How it works](how-it-works.md)
