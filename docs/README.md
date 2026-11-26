# bashx documentation

bashx tests bash code, measures which lines the tests run, and checks that
the tests would notice a bug (mutation testing). Everything is bash.

## Start here

1. [Installation](installation.md): requirements, the four ways to install, checking it works.
2. [Getting started](getting-started.md): a first project, from an empty
   directory to 100 % coverage and 100 % mutation score, in ten minutes.

## Guides

| Page | Read it to |
| --- | --- |
| [Writing tests](writing-tests.md) | structure a test file, isolate cases, use tables, hooks, fixtures and mocks, test exit codes and scripts, avoid bash pitfalls |
| [Running tests](running-tests.md) | understand what `bashx test` does: discovery, parallelism, deadlines, skipping, kinds |
| [Coverage](coverage.md) | measure line coverage, find untested lines, merge runs |
| [Mutation testing](mutation-testing.md) | find what the tests do not check, read survivors, mark equivalent mutants |
| [CI](ci.md) | run all of it in GitHub Actions (or any CI), with shards |

## Reference

| Page | Contains |
| --- | --- |
| [Command line](cli.md) | every command, option, environment variable, output file and exit code |
| [API](api.md) | every function and `assert` operator, with an example |
| [How it works](how-it-works.md) | the runner's protocol, isolation, tracing, sandboxes; writing tests without the API |
| [Study: a Go runner](go-runner-study.md) | a Go port of the tooling benchmarked against bash, and why bashx stays in bash |
| [Troubleshooting](troubleshooting.md) | error messages and their fixes |
| [Contributing](../CONTRIBUTING.md) | checks, commit messages, how releases are made |
| [Changelog](../CHANGELOG.md) | what changed in each release |

## Conventions in this documentation

- `$` starts a command you type; the lines under it are its output.
- Paths like `lib/bashx.sh` are relative to the bashx repository.
- Outputs are shown without colours (`NO_COLOR=1`); durations vary.
