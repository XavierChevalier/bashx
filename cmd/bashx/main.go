// bashx runs bash test files (`bashx test`), scores their coverage (`bashx
// coverage`) and runs mutation testing (`bashx mutate`). Test files stay bash: they source lib/bashx.sh, and the runner
// starts `bash <file>` and reads back what the API writes
// (BASHX_RESULT_FILE, BASHX_CASES_FILE). See docs/how-it-works.md.
package main

import (
	"fmt"
	"os"
)

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
	cmd := "help"
	args := os.Args[1:]
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	var run func(lib string, args []string) int
	switch cmd {
	case "test":
		run = runnerMain
	case "coverage":
		run = coverageMain
	case "mutate":
		run = mutationMain
	case "lib":
		run = func(lib string, _ []string) int {
			fmt.Println(lib)
			return 0
		}
	case "version", "--version", "-v":
		fmt.Println("bashx " + version)
		return
	case "help", "--help", "-h":
		usage()
		return
	default:
		fmt.Fprintf(os.Stderr, "bashx: unknown command '%s'\n", cmd)
		os.Stdout = os.Stderr
		usage()
		os.Exit(2)
	}
	lib, err := libDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, "bashx: cannot write the test API to the cache:", err)
		os.Exit(1)
	}
	os.Setenv("BASHX_LIB", lib)
	// Test files can call the bashx that runs them.
	if exe, err := os.Executable(); err == nil {
		os.Setenv("BASHX_BIN", exe)
	}
	os.Exit(run(lib, args))
}
