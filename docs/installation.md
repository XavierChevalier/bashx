[Documentation](README.md) › Installation

# Installation

## Requirements

| Needed for | Requirement |
| --- | --- |
| test files | **bash ≥ 5.0** and the usual coreutils (`mktemp`, `sed`, `diff`…) |
| the `bashx` command | its binary for your platform (Linux or macOS, amd64 or arm64), which `bin/bashx` finds by itself: see below |
| `bashx test --coverage`, `bashx coverage` | `git` (optional: outside git every `*.sh` counts) |
| `bashx mutate` | `git` |

### The binary

`bashx test`, `coverage` and `mutate` are one Go program. `bin/bashx` runs
it from the first place it finds:

| Source | When |
| --- | --- |
| built from the sources into `.build/` | a git checkout (methods A, B, D) on a machine with [Go](https://go.dev/dl/) ≥ 1.22: a few seconds, once, and again after an update |
| `libexec/` | the release archive (method C) ships every binary |
| downloaded into `~/.cache/bashx/<version>/` | otherwise: once per version, with `curl` or `wget`, checked against its `.sha256` |

A machine without network access needs Go, or the release archive. To use a
binary of your own, set `BASHX_BIN` to its path.

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

## Choose how to install

| Method | Good for |
| --- | --- |
| [A. Clone and link](#a-clone-and-link) | your machine: `bashx` on the `PATH` for every project |
| [B. Git submodule](#b-git-submodule) | a project whose CI must not depend on anything installed |
| [C. Copy into the project](#c-copy-into-the-project) | no submodules wanted; you update by hand |
| [D. Clone in CI](#d-clone-in-ci) | CI only, pinned to a version |

### A. Clone and link

```bash
git clone https://github.com/XavierChevalier/bashx.git ~/.bashx
mkdir -p ~/.local/bin
ln -s ~/.bashx/bin/bashx ~/.local/bin/bashx
```

`~/.local/bin` must be on your `PATH` (it is by default on most Linux
distributions; otherwise add `export PATH="${HOME}/.local/bin:${PATH}"` to
`~/.bashrc`). Any other directory of the `PATH` works: bashx follows the link
to find its library.

### B. Git submodule

```bash
git submodule add https://github.com/XavierChevalier/bashx.git vendor/bashx
git commit -m "Add bashx"
```

Run it from the project:

```bash
vendor/bashx/bin/bashx test
```

Whoever clones the project then needs `git clone --recurse-submodules`, or
`git submodule update --init` after a plain clone. In CI, check out with
submodules (see [CI](ci.md)).

### C. Copy into the project

Every [release](https://github.com/XavierChevalier/bashx/releases) has a
`bashx-X.Y.Z.tar.gz` with what bashx needs at run time (`bin/`, `lib/`, and
`libexec/` with the binary for every platform) and its `LICENSE`, plus a
`.sha256` to check it:

<!-- x-release-please-start-version -->
```bash
version=0.1.1
base="https://github.com/XavierChevalier/bashx/releases/download/v${version}"
curl -fsSLO "${base}/bashx-${version}.tar.gz" -O "${base}/bashx-${version}.tar.gz.sha256"
sha256sum -c "bashx-${version}.tar.gz.sha256"
mkdir -p vendor && tar -xzf "bashx-${version}.tar.gz" -C vendor && mv "vendor/bashx-${version}" vendor/bashx
```
<!-- x-release-please-end -->

Commit `vendor/bashx`. Keep the `LICENSE` file with it.

### D. Clone in CI

<!-- x-release-please-start-version -->
```bash
git clone --depth 1 --branch v0.1.1 https://github.com/XavierChevalier/bashx.git /tmp/bashx
/tmp/bashx/bin/bashx test
```
<!-- x-release-please-end -->

Pin a tag, not `main`, so a new release cannot change your CI by itself.

## Check that it works

<!-- x-release-please-start-version -->
```console
$ bashx version
bashx 0.1.1
$ bashx lib
/home/me/.bashx/lib
```
<!-- x-release-please-end -->

`bashx lib` prints the directory test files source `bashx.sh` from. Then run
bashx's own example:

```console
$ bashx test ~/.bashx/examples/calculator
...
📊 Test Summary: 7 passed, 0 failed, 7 total (111ms)
```

## How test files find bashx

A test file starts with:

```bash
source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"
```

- Under `bashx test` and `bashx mutate`, `BASHX_LIB` is set: the file uses the
  bashx that runs it, wherever it is installed.
- Run alone (`bash x.test.sh`), it asks `bashx lib`: `bashx` must then be on
  the `PATH` (method A), or set `BASHX_LIB` yourself:
  `BASHX_LIB=vendor/bashx/lib bash x.test.sh`.

## Update

| Method | Update with |
| --- | --- |
| A | `git -C ~/.bashx pull` |
| B | `git -C vendor/bashx fetch --tags && git -C vendor/bashx checkout v0.2.0`, then commit `vendor/bashx` |
| C | download the new archive and replace `vendor/bashx` |
| D | change the tag |

Read the [CHANGELOG](../CHANGELOG.md) before updating.

## Uninstall

```bash
rm ~/.local/bin/bashx
rm -rf ~/.bashx ~/.cache/bashx
```

For a submodule: `git rm vendor/bashx`, then remove its section from
`.gitmodules` if git left it.

---

Next: [Getting started](getting-started.md)
