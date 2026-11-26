[Documentation](README.md) › Installation

# Installation

## Requirements

| Needed for | Requirement |
| --- | --- |
| test files | **bash ≥ 5.0** and the usual coreutils (`mktemp`, `sed`, `diff`…) |
| the `bashx` command | one binary, Linux or macOS, amd64 or arm64: nothing else |
| `bashx test --coverage`, `bashx coverage` | `git` (optional: outside git every `*.sh` counts) |
| `bashx mutate` | `git` |

Check your bash:

```console
$ bash --version | head -1
GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)
```

**Linux**: any distribution with bash 5 and GNU coreutils (Debian ≥ 10,
Ubuntu ≥ 20.04, Fedora…). CI runs on Ubuntu. On Alpine, install `bash`
and `coreutils` first.

**macOS** ships bash 3.2, which is too old. Install a recent bash and GNU
coreutils with Homebrew:

```bash
brew install bash coreutils
export PATH="$(brew --prefix coreutils)/libexec/gnubin:$(brew --prefix)/bin:${PATH}"
```

CI runs the suite on Linux and on macOS with these packages.

## Install

`bashx` is a single binary: the test API that test files source is inside
it. Put it anywhere on your `PATH`.

### A. Download the release binary

<!-- x-release-please-start-version -->
```bash
version=0.2.0
os="$(uname -s | tr '[:upper:]' '[:lower:]')"                      # linux, darwin
arch="$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"      # amd64, arm64
base="https://github.com/XavierChevalier/bashx/releases/download/v${version}"
curl -fsSLO "${base}/bashx-${os}-${arch}" -O "${base}/bashx-${os}-${arch}.sha256"
sha256sum -c "bashx-${os}-${arch}.sha256"        # macOS: shasum -a 256 -c
install -m 755 "bashx-${os}-${arch}" ~/.local/bin/bashx
```
<!-- x-release-please-end -->

`~/.local/bin` must be on your `PATH` (it is by default on most Linux
distributions; otherwise add `export PATH="${HOME}/.local/bin:${PATH}"` to
`~/.bashrc`). Any other directory of the `PATH` works.

### B. With Go

With [Go](https://go.dev/dl/) ≥ 1.22:

<!-- x-release-please-start-version -->
```bash
go install github.com/XavierChevalier/bashx/cmd/bashx@v0.2.0
```
<!-- x-release-please-end -->

It lands in `$(go env GOPATH)/bin`, which must be on your `PATH`.

### C. In CI

See [CI](ci.md): one step downloads the binary (or `go install`s it) before
the tests.

## Check that it works

<!-- x-release-please-start-version -->
```console
$ bashx version
bashx 0.2.0
$ bashx lib
/home/me/.cache/bashx/lib-0.2.0-8d0d5274d798
```
<!-- x-release-please-end -->

`bashx lib` writes the test API to your cache directory the first time
(`~/.cache`, or `XDG_CACHE_HOME`; `~/Library/Caches` on macOS) and prints
where it is. Then write a first test: [Getting started](getting-started.md).

## How test files find bashx

A test file starts with:

```bash
source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"
```

- Under `bashx test` and `bashx mutate`, `BASHX_LIB` is set: the file uses the
  test API of the bashx that runs it.
- Run alone (`bash x.test.sh`), it asks `bashx lib`: `bashx` must be on the
  `PATH`.
- Set `BASHX_LIB` yourself to use another copy of the API (a checkout of
  bashx, for instance): `bashx` then hands that one to the test files.

## Update

Install the new version the same way: download it again (A), or `go install`
the new tag (B). Read the [CHANGELOG](../CHANGELOG.md) before updating.

## Uninstall

```bash
rm ~/.local/bin/bashx     # or wherever you put it
rm -rf ~/.cache/bashx     # the extracted test API (macOS: ~/Library/Caches/bashx)
```

---

Next: [Getting started](getting-started.md)
