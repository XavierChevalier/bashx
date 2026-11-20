[Documentation](README.md) › CI

# CI

## GitHub Actions

bashx needs nothing but a checkout. Vendored as a submodule:

```yaml
name: Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true
      - run: vendor/bashx/bin/bashx test --coverage=coverage --report=junit
      - run: vendor/bashx/bin/bashx coverage report -f markdown coverage/covered.tsv >>"$GITHUB_STEP_SUMMARY"
```

Or cloned at a fixed tag:

```yaml
      - run: git clone --depth 1 --branch v0.1.0 https://github.com/XavierChevalier/bashx.git /tmp/bashx
      - run: /tmp/bashx/bin/bashx test
```

`CI` being set turns the live status line off; the output stays plain.

## Shards

A slow suite splits over several runners. Each shard runs about the same
amount of work, balanced on recorded durations:

```bash
bashx test --record-durations=.bashx/durations.tsv   # once in a while, commit the file
```

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        shard: [1, 2, 3]
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true
      - run: vendor/bashx/bin/bashx test --shard=${{ matrix.shard }}/3 --coverage=coverage
      - uses: actions/upload-artifact@v4
        with:
          name: coverage-${{ matrix.shard }}
          path: coverage/covered.tsv

  coverage:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true
      - uses: actions/download-artifact@v4
      - run: vendor/bashx/bin/bashx coverage report coverage-*/covered.tsv
```

Every file runs in exactly one shard, whatever the durations file says. A
stale or missing file only costs balance (an unknown file weighs one second).

## Mutation testing in CI

A mutation run costs one test run per mutant: run it on the scripts that
matter, on a schedule or on the scripts a PR changes, and gate on a score:

```yaml
      - run: |
          changed="$(git diff --name-only origin/main -- '*.sh' | grep -v '\.test\.sh$' || true)"
          [ -z "${changed}" ] || vendor/bashx/bin/bashx mutate -s 80 ${changed} >>"$GITHUB_STEP_SUMMARY"
```

The report is Markdown, so it renders as is in the job summary or a PR
comment.

---

Previous: [Mutation testing](mutation-testing.md) · Next: [Command line](cli.md)
