package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// mutantsText: the mutants of a script as "op:line:text" lines.
func mutantsText(script, ops string) string {
	var lines []string
	for _, m := range generate(script, selectOperators(ops)) {
		lines = append(lines, m.op+":"+strconv.Itoa(m.changes[0].line)+":"+m.changes[0].text)
	}
	return strings.Join(lines, "\n")
}

func expect(t *testing.T, got, want string) {
	t.Helper()
	if got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestOneMutantPerMatchOfAnOperator(t *testing.T) {
	expect(t, mutantsText(`[[ "$a" -eq 1 && "$b" -eq 2 ]]`+"\n", "rel,logic"), `rel-eq:1:[[ "$a" -ne 1 && "$b" -eq 2 ]]
rel-eq:1:[[ "$a" -eq 1 && "$b" -ne 2 ]]
logic-and:1:[[ "$a" -eq 1 || "$b" -eq 2 ]]`)
}

func TestSkipsCommentsHeredocBodiesAndNoMutateLines(t *testing.T) {
	expect(t, mutantsText(`#!/usr/bin/env bash
# true
cat <<TXT
true
TXT
x=true # no-mutate: equivalent
z=true # no-mutate
y=true # keep this comment: true
`, "bool"), "bool-true:8:y=false # keep this comment: true")
}

func TestEndsAHeredocOnlyAtItsTerminator(t *testing.T) {
	expect(t, mutantsText("cat <<TXT\ntrue\ntrue\nTXT\nx=true\n", "bool"), "bool-true:5:x=false")
}

func TestDoesNotDoubleANegation(t *testing.T) {
	expect(t, mutantsText("if [[ ! -f x ]]; then echo; fi\n", "cond"), "cond-drop-neg:1:if [[ -f x ]]; then echo; fi")
}

func TestMutatesArithmeticOnlyInsideDoubleParentheses(t *testing.T) {
	expect(t, mutantsText("echo a - b > out\nn=$((a - b))\n", "arith"), "arith-sub:2:n=$((a + b))")
}

func TestDeletesCommandsButNotKeywordsOrBareDeclarations(t *testing.T) {
	expect(t, mutantsText(`f() {
  local x
  local -r y="$1"
  if true; then
    echo "${y}"
  fi
  case "$x" in
    a) echo a ;;
  esac
}
`, "stmt-del"), "stmt-del:3:  :\nstmt-del:5:    :")
}

func TestDoesNotDeleteLinesThatContinueOrOpenABlock(t *testing.T) {
	expect(t, mutantsText(`echo a |
  cat
echo b &&
  true
echo c ||
  true
echo d \
  e
arr=(
  1
)
{
  echo f
}
;;
  echo g ;;
:
  a)
`, "stmt-del"), "stmt-del:2:  :\nstmt-del:4:  :\nstmt-del:6:  :\nstmt-del:8:  :\nstmt-del:10:  :\nstmt-del:13:  :")
}

func TestPairsMutantsOnDifferentLinesOnly(t *testing.T) {
	var got []string
	for _, m := range pairs(generate("[[ 1 -eq 1 && 2 -eq 2 ]]\nreturn 0\n", selectOperators("rel,ret"))) {
		got = append(got, m.op+":"+strconv.Itoa(m.changes[0].line)+":"+strconv.Itoa(m.changes[1].line))
	}
	expect(t, strings.Join(got, "\n"), "rel-eq+ret-0:1:2\nrel-eq+ret-0:1:2")
}

func TestSelectsOperatorsByNameOrGroup(t *testing.T) {
	var names []string
	for _, op := range selectOperators("str-z,ret") {
		names = append(names, op.name)
	}
	expect(t, strings.Join(names, ","), "str-z,ret-0,ret-1")
	if len(selectOperators("")) != 29 {
		t.Errorf("all operators: %d", len(selectOperators("")))
	}
}

func TestSamplesTheSameMutantsOnEveryRun(t *testing.T) {
	var ms []mutant
	for i := 0; i < 100; i++ {
		ms = append(ms, mutant{op: strconv.Itoa(i)})
	}
	first, second := sample(ms, 5), sample(ms, 5)
	if len(first) != 5 {
		t.Fatalf("kept %d", len(first))
	}
	for i := range first {
		if first[i].op != second[i].op {
			t.Fatalf("not the same: %v %v", first, second)
		}
	}
	if len(sample(ms, 0)) != 100 {
		t.Error("0 must keep all")
	}
}

func TestAppliesOneOrTwoMutations(t *testing.T) {
	orig := fileLines("a\nb\nc\n")
	expect(t, apply(orig, []mutation{{2, "B"}}), "a\nB\nc\n")
	expect(t, apply(orig, []mutation{{1, "A"}, {3, "C"}}), "A\nb\nC\n")
}

func TestGivesSlowTestsALongerDeadline(t *testing.T) {
	var got []string
	for _, ms := range []int64{0, 1666, 2000, 2001} {
		got = append(got, strconv.FormatInt(mutationDeadline(ms), 10))
	}
	expect(t, strings.Join(got, " "), "10 10 11 12")
}

func TestComparesTheScoreToTheMinimum(t *testing.T) {
	cases := []struct {
		t    tally
		min  string
		want bool
	}{
		{tally{10, 5, 2, 3, 0}, "", false},
		{tally{10, 5, 2, 3, 0}, "70", false},
		{tally{10, 5, 2, 3, 0}, "71", true},
		{tally{3, 0, 0, 0, 3}, "90", false}, // all invalid: no score
	}
	for _, c := range cases {
		if got := belowMinScore(c.t, c.min); got != c.want {
			t.Errorf("%v < %s: got %v", c.t, c.min, got)
		}
	}
}

func TestFindsTheScriptsOwnTests(t *testing.T) {
	dir := t.TempDir()
	for _, f := range []string{"a.sh", "a.test.sh", "a.unit.test.sh", "a.integration.test.sh", "b.unit.test.sh", "ab.test.sh"} {
		os.WriteFile(filepath.Join(dir, f), nil, 0o644)
	}
	expect(t, strings.Join(ownTests(dir, "a.sh"), "\n"), "a.test.sh\na.integration.test.sh\na.unit.test.sh")
}

func TestReportsARunAsMarkdownAndTSV(t *testing.T) {
	pad := strings.Repeat("x", 100)
	original := []string{"#!/usr/bin/env bash", `is_big() { [[ "$1" -gt 10 ]]; }`, `  is_small() { [[ "$1" -lt 3 ]]; } # see ` + "`x` " + pad}
	big := mutation{2, `is_big() { [[ "$1" -ge 10 ]]; }`}
	small := mutation{3, `  is_small() { [[ "$1" -le 3 ]]; }`}
	run := &scriptRun{
		script: "lib.sh", order: 1, baselineMs: 1234, elapsed: 56, original: original,
		tests: []string{"tests/a.unit.test.sh", "b.unit.test.sh"},
		mutants: []mutant{
			{1, "rel-gt", []mutation{big}},
			{2, "rel-lt", []mutation{small}},
			{3, "stmt-del", []mutation{{3, "  :"}}},
			{4, "rel-gt+rel-lt", []mutation{big, small}},
		},
		outcomes: map[int]outcome{1: {"killed", 12}, 2: {"survived", 30}, 3: {"timeout", 1000}, 4: {"survived", 5}},
	}
	var b bytes.Buffer
	total := run.report(&b)
	expect(t, b.String(), "### `lib.sh`\n\n"+
		"Tests: `a.unit.test.sh` `b.unit.test.sh` (1234 ms unmutated) · order 1 · 56 s\n\n"+
		"| Operator | Mutation | Mutants | Killed | Timeout | Survived | Invalid | Score |\n"+
		"| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |\n"+
		"| rel-lt | `-lt` → `-le` | 1 | 0 | 0 | 1 | 0 | 0.0% |\n"+
		"| rel-gt | `-gt` → `-ge` | 1 | 1 | 0 | 0 | 0 | 100.0% |\n"+
		"| rel-gt+rel-lt | combination of rel-gt and rel-lt | 1 | 0 | 0 | 1 | 0 | 0.0% |\n"+
		"| stmt-del | command → `:` | 1 | 0 | 1 | 0 | 0 | 100.0% |\n"+
		"| **Total** |  | 4 | 1 | 1 | 2 | 0 | 50.0% |\n\n"+
		"<details><summary>Survivors (2)</summary>\n\n"+
		"- `lib.sh:2` rel-gt+rel-lt: `is_big() { [[ \"$1\" -gt 10 ]]; }` → `is_big() { [[ \"$1\" -ge 10 ]]; }`\n"+
		"- `lib.sh:3` rel-gt+rel-lt: `is_small() { [[ \"$1\" -lt 3 ]]; } # see 'x' "+pad[:77]+"` → `is_small() { [[ \"$1\" -le 3 ]]; }`\n"+
		"- `lib.sh:3` rel-lt: `is_small() { [[ \"$1\" -lt 3 ]]; } # see 'x' "+pad[:77]+"` → `is_small() { [[ \"$1\" -le 3 ]]; }`\n\n"+
		"</details>\n\n")
	if total != (tally{4, 1, 1, 2, 0}) {
		t.Errorf("total %v", total)
	}
	b.Reset()
	run.tsvRows(&b)
	rows := strings.Split(strings.TrimSuffix(b.String(), "\n"), "\n")
	if len(rows) != 4 || rows[2] != "lib.sh\t3\tstmt-del\ttimeout\t1000\t3\t  :" {
		t.Errorf("tsv:\n%s", b.String())
	}
}

func TestReportsNoSurvivorListWithoutSurvivors(t *testing.T) {
	run := &scriptRun{script: "lib.sh", order: 1, original: []string{"x"},
		mutants: []mutant{{1, "rel-eq", []mutation{{1, "y"}}}}, outcomes: map[int]outcome{1: {"killed", 1}}}
	var b bytes.Buffer
	run.report(&b)
	if strings.Contains(b.String(), "<details>") {
		t.Errorf("survivor list without survivors:\n%s", b.String())
	}
}

func TestSummarisesSeveralScriptsOnly(t *testing.T) {
	var b bytes.Buffer
	reportSummary(&b, []summaryRow{{"lib.sh", tally{8, 4, 1, 1, 2}, 3}, {"lib2.sh", tally{2, 2, 0, 0, 0}, 1}})
	expect(t, b.String(), "### Summary\n\n"+
		"| Script | Mutants | Killed | Timeout | Survived | Invalid | Score | Time |\n"+
		"| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n"+
		"| `lib.sh` | 8 | 4 | 1 | 1 | 2 | 83.3% | 3 s |\n"+
		"| `lib2.sh` | 2 | 2 | 0 | 0 | 0 | 100.0% | 1 s |\n"+
		"| **Total** | 10 | 6 | 1 | 1 | 2 | 87.5% | 4 s |\n")
	b.Reset()
	reportSummary(&b, []summaryRow{{"lib.sh", tally{1, 1, 0, 0, 0}, 1}})
	expect(t, b.String(), "")
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).Output()
	if err != nil {
		t.Fatalf("git %v: %v", args, err)
	}
	return strings.TrimSpace(string(out))
}

func TestCopiesTrackedAndUntrackedFilesIntoASandbox(t *testing.T) {
	dir := t.TempDir()
	repo, box := filepath.Join(dir, "repo"), filepath.Join(dir, "box")
	os.MkdirAll(repo, 0o755)
	git(t, repo, "init", "-q")
	os.WriteFile(filepath.Join(repo, ".gitignore"), []byte("ignored.txt\n"), 0o644)
	for _, f := range []string{"tracked.sh", "untracked.sh", "ignored.txt"} {
		os.WriteFile(filepath.Join(repo, f), nil, 0o755)
	}
	git(t, repo, "add", "tracked.sh", ".gitignore")
	if err := sandbox(repo, box); err != nil {
		t.Fatal(err)
	}
	expect(t, git(t, box, "ls-files"), ".gitignore\ntracked.sh\nuntracked.sh")
	real, _ := filepath.EvalSymlinks(box)
	expect(t, git(t, box, "rev-parse", "--show-toplevel"), real)
	expect(t, git(t, box, "rev-list", "--count", "HEAD"), "1")
	if st, _ := os.Stat(filepath.Join(box, "tracked.sh")); st.Mode().Perm()&0o100 == 0 {
		t.Error("the mode is not kept")
	}
}

func TestReadsATestsExitDeadlineAndResultFile(t *testing.T) {
	dir := t.TempDir()
	scripts := map[string]string{
		"pass.sh":      "exit 0",
		"fail.sh":      "exit 3",
		"slow.sh":      "sleep 5",
		"swallowed.sh": `echo failed=1 >"${BASHX_RESULT_FILE}"`,
	}
	for name, body := range scripts {
		os.WriteFile(filepath.Join(dir, name), []byte(body+"\n"), 0o644)
	}
	var got []string
	for _, name := range []string{"pass", "fail", "slow", "swallowed", "pass"} {
		got = append(got, strconv.Itoa(runTest("", dir, time.Second, name+".sh")))
	}
	// A result file is not read by the next test.
	expect(t, strings.Join(got, " "), "0 3 124 1 0")
}

func TestParsesOptionsAsGetopts(t *testing.T) {
	o, rc := parseMutationArgs([]string{"-j2", "-t", "a.test.sh", "-t", "b.test.sh", "-nk", "2", "x.sh", "-j", "3"})
	if rc != -1 || o.jobs != 2 || o.order != 2 || o.dry != 1 || len(o.tests) != 2 {
		t.Fatalf("%+v %d", o, rc)
	}
	expect(t, strings.Join(o.scripts, " "), "x.sh -j 3") // options end at the first operand
}
