[Documentation](README.md) › Installation

# Installation

## Requirements

| Needed for | Requirement |
| --- | --- |
| everything | **bash ≥ 5.0**, `find`, `awk`, `sort`, `mktemp` |
| `bashx test` deadlines and process cleanup | `perl` (optional: without it, files run without a deadline) |
| `bashx test --coverage`, `bashx coverage` | `git` (optional: outside git every `*.sh` counts) |
| `bashx mutate` | `git`, and GNU `timeout`, `shuf`, `realpath` (coreutils) |

Check your bash:

```console
$ bash --version | head -1
GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)
```

**Linux**: any distribution with bash 5 and GNU coreutils (Debian ≥ 10,
Ubuntu ≥ 20.04, Fedora…). CI runs on Ubuntu. On Alpine, install `bash`,
`coreutils` and `perl` first.

**macOS** ships bash 3.2, which is too old. Install a recent bash and GNU
coreutils with Homebrew:

```bash
brew install bash coreutils
export PATH="$(brew --prefix coreutils)/libexec/gnubin:$(brew --prefix)/bin:${PATH}"
```

bashx is tested on Linux; macOS with these packages is expected to work but
is not part of CI.

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

```bash
git clone --depth 1 https://github.com/XavierChevalier/bashx.git /tmp/bashx
mkdir -p vendor/bashx
cp -R /tmp/bashx/bin /tmp/bashx/lib /tmp/bashx/LICENSE vendor/bashx/
```

`bin/` and `lib/` are all bashx needs at run time. Keep the `LICENSE` file
with them.

### D. Clone in CI

```bash
git clone --depth 1 --branch v0.1.0 https://github.com/XavierChevalier/bashx.git /tmp/bashx
/tmp/bashx/bin/bashx test
```

Pin a tag, not `main`, so a new release cannot change your CI by itself.

## Check that it works

```console
$ bashx version
bashx 0.1.0
$ bashx lib
/home/me/.bashx/lib
```

`bashx lib` prints the directory test files source `bashx.sh` from. Then run
bashx's own example:

```console
$ bashx test ~/.bashx/examples/calculator
...
📊 Test Summary: 5 passed, 0 failed, 5 total (111ms)
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
| C | copy `bin/` and `lib/` again |
| D | change the tag |

Read the [CHANGELOG](../CHANGELOG.md) before updating.

## Uninstall

```bash
rm ~/.local/bin/bashx
rm -rf ~/.bashx
```

For a submodule: `git rm vendor/bashx`, then remove its section from
`.gitmodules` if git left it.

---

Next: [Getting started](getting-started.md)
