# Changelog

## 0.1.0

First release.

- `bashx.sh`: test API (`test::run`, assertions, `test::skip`, mocks, tmp dirs);
  every case isolated in a subshell with errexit on.
- `bashx test`: parallel runner with per-file deadlines, process-group cleanup,
  `@requires`, kinds, CI shards balanced on durations, Markdown / JSON / JUnit
  reports.
- `bashx test --coverage` and `bashx coverage report`: line coverage of the
  project's scripts.
- `bashx mutate`: mutation testing with 29 operators, pairs (`-k 2`),
  sampling, minimum score, `# no-mutate: <reason>`.
