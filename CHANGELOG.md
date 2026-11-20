# Changelog

Every release is listed here, newest first. From 0.1.0 on, this file is
written by the release workflow from the commit messages: see
[CONTRIBUTING.md](CONTRIBUTING.md#releases).

## [0.2.0](https://github.com/XavierChevalier/bashx/compare/v0.1.1...v0.2.0) (2026-11-20)


### ⚠ BREAKING CHANGES

* what a passing case prints is no longer shown (set BASHX_VERBOSE to see it), and a case's stdin is /dev/null.

### Features

* an optional message for assert ([a3748fe](https://github.com/XavierChevalier/bashx/commit/a3748fe88675ca8bad9e8674cbe84664dd054f34))
* **runner:** --filter and -v ([278e736](https://github.com/XavierChevalier/bashx/commit/278e736b16a3dd57b34c8b1e1f1d1a5ac0bd2182))
* test_* cases, test::main, assert, capture, mock, tables and hooks ([1f6dffe](https://github.com/XavierChevalier/bashx/commit/1f6dffe4b7692ef199ad25e859c5b4951cb927f9))


### Documentation

* **proposals:** capture through $( ), which keeps the status on bash 5.0 ([b0b6cf1](https://github.com/XavierChevalier/bashx/commit/b0b6cf140690584aa2247694b50ea94bd6e23b11))
* **proposals:** end test files with test::main, not the EXIT trap ([c5c38bb](https://github.com/XavierChevalier/bashx/commit/c5c38bba2aff9a5aadd52811e9862ed4fb8c968e))
* **proposals:** run capture's command inside an || list for bash 5.0 ([dc6f250](https://github.com/XavierChevalier/bashx/commit/dc6f250ba77cf72c2eafdfa8028c12e68eb4b379))
* propose a v2 test-writing API, with a working spike ([8117998](https://github.com/XavierChevalier/bashx/commit/8117998186bfd27eefac6af91f8c9bcceedef241))
* write tests with test_* functions, assert, capture and mock ([310a26b](https://github.com/XavierChevalier/bashx/commit/310a26bf2cbfde933a9ac09432cc660d6b967bb6))

## [0.1.1](https://github.com/XavierChevalier/bashx/compare/v0.1.0...v0.1.1) (2026-11-20)


### Bug Fixes

* automated releases and wider CI; a vendored bashx stays out of the project's tests and coverage ([d1386b2](https://github.com/XavierChevalier/bashx/commit/d1386b29608978a311fe68361c4a5c47c944a701))
* **coverage:** leave a vendored bashx out of the project's score ([67d5dd4](https://github.com/XavierChevalier/bashx/commit/67d5dd4a6704adab616badadc8a679c78465def2))
* **coverage:** normalise the root like the trace paths (macOS TMPDIR ends in /) ([9e3739f](https://github.com/XavierChevalier/bashx/commit/9e3739ff5cfbf4ff13301c2b8a6e6d597940bd37))
* portable awk, tar and paths for busybox (Alpine) and macOS ([f1103d5](https://github.com/XavierChevalier/bashx/commit/f1103d525a116b3020e3d68ac0443fd7b0cc5bfc))
* **runner:** clean up leaked processes on bash 5.0 and 5.1 ([bffd8f8](https://github.com/XavierChevalier/bashx/commit/bffd8f8e928dc8273b4cffbad1298496e774a11e))
* **runner:** leave nested git repositories out; keep tests out of release archives ([2ad407d](https://github.com/XavierChevalier/bashx/commit/2ad407d588c08a474798e05f02085fe0e299502c))


### Documentation

* nested repositories and vendored bashx in test runs and coverage ([38533be](https://github.com/XavierChevalier/bashx/commit/38533be87b8f10debcfa5340a36d4fd9e62995f2))

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
