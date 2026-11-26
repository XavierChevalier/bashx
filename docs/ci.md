[Documentation](README.md) › CI

# CI

## GitHub Actions

Install the binary in one step, then run it. From the release, pinned to a
version:

<!-- x-release-please-start-version -->
```yaml
name: Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install bashx
        run: |
          curl -fsSL -o /usr/local/bin/bashx \
            https://github.com/XavierChevalier/bashx/releases/download/v0.2.0/bashx-linux-amd64
          chmod +x /usr/local/bin/bashx
      - run: bashx test --coverage=coverage --report=junit
      - run: bashx coverage report -f markdown coverage/covered.tsv >>"$GITHUB_STEP_SUMMARY"
```
<!-- x-release-please-end -->

Or with Go, which GitHub's runners have:

<!-- x-release-please-start-version -->
```yaml
      - run: go install github.com/XavierChevalier/bashx/cmd/bashx@v0.2.0
      - run: bashx test
```
<!-- x-release-please-end -->

Pin a version, not `latest`, so a new release cannot change your CI by itself.

`CI` being set turns the live status line off; the output stays plain.

## Shards

A slow suite splits over several runners. Each shard runs about the same
amount of work, balanced on recorded durations:

```bash
bashx test --record-durations=.bashx/durations.tsv   # once in a while, commit the file
```

<!-- x-release-please-start-version -->
```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        shard: [1, 2, 3]
    steps:
      - uses: actions/checkout@v4
      - run: go install github.com/XavierChevalier/bashx/cmd/bashx@v0.2.0  # or download it
      - run: bashx test --shard=${{ matrix.shard }}/3 --coverage=coverage
      - uses: actions/upload-artifact@v4
        with:
          name: coverage-${{ matrix.shard }}
          path: coverage/covered.tsv

  coverage:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: go install github.com/XavierChevalier/bashx/cmd/bashx@v0.2.0
      - uses: actions/download-artifact@v4
      - run: bashx coverage report coverage-*/covered.tsv
```
<!-- x-release-please-end -->

Every file runs in exactly one shard, whatever the durations file says. A
stale or missing file only costs balance (an unknown file weighs one second).

## Mutation testing in CI

A mutation run costs one test run per mutant: run it on the scripts that
matter, on a schedule or on the scripts a PR changes, and gate on a score:

```yaml
      - run: |
          changed="$(git diff --name-only origin/main -- '*.sh' | grep -v '\.test\.sh$' || true)"
          [ -z "${changed}" ] || bashx mutate -s 80 ${changed} >>"$GITHUB_STEP_SUMMARY"
```

The report is Markdown, so it renders as is in the job summary or a PR
comment.

---

Previous: [Mutation testing](mutation-testing.md) · Next: [Command line](cli.md)
