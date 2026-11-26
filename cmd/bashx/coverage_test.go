package main

import (
	"strconv"
	"strings"
	"testing"
)

// Every multi-line shape, numbered in the comments below.
const sampleScript = `#!/usr/bin/env bash
f() {
  local x=1
  echo a \
    b
  arr=(
    one
  )
  awk '
    { print }
  ' <<<"z"
  if [[ "${x}" -eq 1 ]]; then
    echo yes # trailing comment
  else
    echo no
  fi
  case "${x}" in
    1) echo one ;;
    *)
      echo other
      ;;
  esac
  cat <<X
body
X
}
f
`

func TestCountsEachStatementOnceOnItsFirstLine(t *testing.T) {
	info := scriptLines(sampleScript)
	var coverable []string
	for i, li := range info {
		if li.coverable {
			coverable = append(coverable, itoa(i+1))
		}
	}
	// Not: shebang, f() {, continuation (5), array body (7-8), awk body
	// (10-11), then/else/fi, case patterns (19), ;;, esac, heredoc body, }.
	expect(t, strings.Join(coverable, " "), "3 4 6 9 12 13 15 17 18 20 23 27")
	// A line xtrace reports inside a statement maps to its first line.
	if info[7].start != 6 || info[10].start != 9 {
		t.Errorf("starts: line 8 → %d, line 11 → %d", info[7].start, info[10].start)
	}
}

func TestNormalisesPaths(t *testing.T) {
	expect(t, normalise("/a/./b/../c//d/"), "/a/c/d")
	expect(t, normalise("/../x"), "/x")
}

func itoa(n int) string { return strconv.Itoa(n) }
