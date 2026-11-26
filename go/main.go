// bashx-go: a Go port of the bashx runner (`bashx test`), its reporters and
// `bashx coverage`, built to compare it with the bash version. Test files and
// their API (lib/bashx.sh) are unchanged: the runner still starts `bash <file>`
// and speaks the same protocol (BASHX_RESULT_FILE, BASHX_CASES_FILE).
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

const version = "0.1.1-go"

// libDir is the bashx lib dir: $BASHX_LIB, or ../lib next to the executable.
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
		// Mutation testing stays in bash: its time is spent in the tests.
		bash, err := exec.LookPath("bash")
		if err != nil {
			fmt.Fprintln(os.Stderr, "bashx: bash not found")
			os.Exit(127)
		}
		argv := append([]string{"bash", filepath.Join(lib, "mutation.sh")}, args...)
		if err := syscall.Exec(bash, argv, os.Environ()); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(126)
		}
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
