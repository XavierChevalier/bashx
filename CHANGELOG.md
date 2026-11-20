# Changelog

Every release is listed here, newest first. From 0.1.0 on, this file is
written by the release workflow from the commit messages: see
[CONTRIBUTING.md](CONTRIBUTING.md#releases).

## [0.1.0](https://github.com/XavierChevalier/bashx/releases/tag/v0.1.0) (2026-11-20)

First release.

### Features

- `bashx.sh`: test API (`test::run`, assertions, `test::skip`, mocks, tmp dirs);
  every case isolated in a subshell with errexit on.
- `bashx test`: parallel runner with per-file deadlines, process-group cleanup,
  `@requires`, kinds, CI shards balanced on durations, Markdown / JSON / JUnit
  reports.
- `bashx test --coverage` and `bashx coverage report`: line coverage of the
  project's scripts; `-f uncovered` lists the lines no test ran.
- `bashx mutate`: mutation testing with 29 operators, pairs (`-k 2`),
  sampling, minimum score, `# no-mutate: <reason>`.

### Documentation

- Installation, getting started, writing tests, running tests, coverage,
  mutation testing, CI, command line reference, API, how it works,
  troubleshooting.
