// bashx: the command behind bin/bashx. It runs test files (`bashx test`),
// scores coverage (`bashx coverage`) and runs mutation testing (`bashx
// mutate`). Test files stay bash: they source lib/bashx.sh, and the runner
// starts `bash <file>` and reads back what the API writes
// (BASHX_RESULT_FILE, BASHX_CASES_FILE). See docs/how-it-works.md.
package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// version is set at build time: -ldflags "-X main.version=X.Y.Z".
var version = "dev"

// libDir is the bashx lib dir: $BASHX_LIB (bin/bashx sets it), or a lib dir
// next to the executable.
func libDir() string {
	if d := os.Getenv("BASHX_LIB"); d != "" {
		if abs, err := filepath.Abs(d); err == nil {
			return abs
		}
		return d
	}
	exe, err := os.Executable()
	if err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		for _, cand := range []string{"../lib", "../../lib"} {
			d := filepath.Join(filepath.Dir(exe), cand)
			if _, err := os.Stat(filepath.Join(d, "bashx.sh")); err == nil {
				return d
			}
		}
	}
	return "lib"
}

func usage() {
	fmt.Printf(`bashx %s: tests, coverage and mutation testing for bash

Usage: bashx <command> [options]

  test [<root>]            run every *.test.sh under <root>
  test --coverage=DIR      ... and measure line coverage
  coverage report <tsv>    score a coverage run again (filters, formats)
  mutate <script.sh>...    mutation testing: do the tests notice a change?
  lib                      print the lib dir, for: source "$(bashx lib)/bashx.sh"
  version                  print the version

`+"`bashx <command> --help`"+` details each command. Docs: docs/ in the repository.
`, version)
}

func main() {
	lib := libDir()
	os.Setenv("BASHX_LIB", lib)
	cmd := "help"
	args := os.Args[1:]
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	switch cmd {
	case "test":
		os.Exit(runnerMain(lib, args))
	case "coverage":
		os.Exit(coverageMain(lib, args))
	case "mutate":
		os.Exit(mutationMain(lib, args))
	case "lib":
		fmt.Println(lib)
	case "version", "--version", "-v":
		fmt.Println("bashx " + version)
	case "help", "--help", "-h":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "bashx: unknown command '%s'\n", cmd)
		os.Stdout = os.Stderr
		usage()
		os.Exit(2)
	}
}
