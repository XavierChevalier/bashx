# Contributing

## Checks to run before a pull request

```bash
shellcheck -x -S warning $(git ls-files '*.sh' '*.bash')
gofmt -l cmd lib && go vet ./... && go test ./...
go run ./cmd/bashx test                             # the whole suite
go run ./cmd/bashx mutate lib/bashx.sh              # optional, slower
```

The command is Go (`cmd/bashx`, Go ≥ 1.22, no dependency); the test API
(`lib/bashx.sh`) is bash, embedded in the binary. `go run ./cmd/bashx`
builds both as they are in your checkout, so it always runs what you edit.
The bash suite (`*.test.sh`) drives the binary as a user would, through
`BASHX_BIN`; `cmd/bashx/*_test.go` holds the unit tests of its parts.

CI runs the same checks, and more:

| Job | Checks |
| --- | --- |
| `shellcheck` | every script, warnings and above |
| `go` | `gofmt`, `go vet`, the Go unit tests |
| `test (ubuntu, coverage)` | the whole suite, with the bash and Go coverage in the job summary |
| `test (bash 5.0/5.1/5.2)` | the suite on each supported bash, on the official `bash` images |
| `test (macos)` | the suite on macOS with Homebrew bash and coreutils |
| `mutation (example)` | `bashx mutate` on the example, report in the job summary |
| `PR title` | the title follows Conventional Commits (below) |

Every change comes with its tests: next to the file for `lib/`
(`lib/x.sh` → `lib/x.test.sh`), in `lib/*.test.sh` or `cmd/bashx/cli.test.sh`
(through the binary) or `cmd/bashx/*_test.go` for the commands.

## Commit messages and pull request titles

Releases are computed from them, so they follow
[Conventional Commits](https://www.conventionalcommits.org):

```text
<type>: <what changes, in the imperative>
```

| Type | For | Next version (from 0.x) | In the changelog |
| --- | --- | --- | --- |
| `feat` | a new feature | minor: 0.1.0 → 0.2.0 | Features |
| `fix` | a bug fix | patch: 0.1.0 → 0.1.1 | Bug Fixes |
| `perf` | faster, same behaviour | patch | Performance |
| `docs` | documentation only | patch | Documentation |
| `refactor`, `test`, `ci`, `chore` | everything else | none on its own | hidden |

A breaking change adds `!` (`feat!: rename test::run`) or a
`BREAKING CHANGE:` footer. Before 1.0 it bumps the minor version; from 1.0 on,
the major one.

Pull requests are merged with **squash**: the pull request title becomes the
commit message on `main`, which is why the `PR title` check enforces the
format.

## Releases

Nothing to do by hand but merging:

1. Every push to `main` runs the `Release` workflow. It opens or updates a
   pull request named `chore: release X.Y.Z`, which:
   - adds the `X.Y.Z` section to `CHANGELOG.md`, from the commits since the
     last release;
   - sets the version in `cmd/bashx/version.go`, `version.txt`,
     `.release-please-manifest.json` and the version shown in the docs.
2. Merging that pull request:
   - tags `vX.Y.Z`;
   - publishes the GitHub release, with the changelog section as its notes;
   - builds the binary for Linux and macOS, amd64 and arm64, and attaches
     each one (`bashx-<os>-<arch>`) with its `.sha256`. `go install
     …/cmd/bashx@vX.Y.Z` works from the tag itself.

To force a version, add a commit with a `Release-As: 1.0.0` footer:

```bash
git commit --allow-empty -m "chore: release 1.0.0" -m "Release-As: 1.0.0"
```

### Repository settings the workflow needs

Set once, in [Settings › Actions › General](https://github.com/XavierChevalier/bashx/settings/actions):

- **Workflow permissions**: *Read and write permissions*.
- **Allow GitHub Actions to create and approve pull requests**: checked
  (release-please opens the release pull request).

And in [Settings › General › Pull Requests](https://github.com/XavierChevalier/bashx/settings):
*Allow squash merging* checked, with *Default to pull request title*.

Optional: the release pull request is opened with the workflow's own token,
and GitHub does not start CI for it. To get CI on it too, create a
fine-grained token with *Contents* and *Pull requests* read and write on this
repository, and save it as the `RELEASE_PLEASE_TOKEN` secret in
[Settings › Secrets › Actions](https://github.com/XavierChevalier/bashx/settings/secrets/actions).
