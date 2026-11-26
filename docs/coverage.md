[Documentation](README.md) › Coverage

# Coverage

```console
$ bashx test --coverage=coverage
...
🧭 Coverage: covered=680 coverable=750 pct=90.7
```

The run writes `coverage/covered.tsv`: one `path<TAB>line` per line the tests
ran. Score it again, per script or for a PR comment:

```console
$ bashx coverage report -f tsv coverage/covered.tsv
path	covered	coverable
lib/deploy.sh	214	270
lib/config.sh	121	121

$ bashx coverage report -f markdown coverage/covered.tsv
**Coverage:** 90.7% of bash lines (680/750)
```

## Finding the untested lines

```console
$ bashx coverage report -f uncovered coverage/covered.tsv
lib/deploy.sh:103: echo "no target ${target}" >&2
lib/deploy.sh:104: return 1
lib/deploy.sh:178: usage
...
```

One line per coverable line no test ran, as `path:line: code`, sorted. Most
editors and terminals open `path:line` on a click.

All options and formats: [command line reference](cli.md#bashx-coverage-report).

## What is measured

Every bash process the tests start (the test file, the scripts it runs,
`bash -c`…) is traced with `xtrace` into a separate file descriptor, so the
output and stderr your tests check are untouched.

The score is over the project's scripts: the `*.sh` files git tracks or would
track (every `*.sh` outside git), minus `*.test.sh` files, anything under a
`fixtures/` directory, and bashx's own scripts when `BASHX_LIB` points to a copy of bashx inside
the project (e.g. `vendor/bashx/lib`). Leave out more with `-x`:

```bash
bashx coverage report -x '^(vendor|examples)/' coverage/covered.tsv
```

A line is one statement:

- a command over several lines (continuation, multi-line string or array,
  heredoc) counts once, on its first line;
- structural lines never count: `then`, `fi`, `done`, `}`, `;;`, case
  patterns, function headers, comments, blank lines.

So the numbers are approximate, as any bash coverage, but stable from one run
to the next: watch the trend, and read the per-script table to find the
untested script.

## Merging runs

`report` takes several `covered.tsv` files and scores their union: one per CI
shard, or unit and integration runs.

```bash
bashx coverage report shard-1/covered.tsv shard-2/covered.tsv shard-3/covered.tsv
```

## Coverage is not enough

A covered line ran; nothing says a test checked what it did. Mutation testing
answers that: see [Mutation testing](mutation-testing.md) and the example in
the [README](../README.md#a-full-example), where 100 % coverage still leaves a
mutant alive.

---

Previous: [Running tests](running-tests.md) · Next: [Mutation testing](mutation-testing.md)
