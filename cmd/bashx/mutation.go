package main

// Mutation testing for bash: change one operator of a script at a time (a
// mutant), run the script's tests, and count the mutants they catch. A
// surviving mutant is a behaviour no test pins down.
//
// Mutants run in throwaway copies of the project (one per job, never the
// working tree itself), so the tests run unchanged against the mutated file.
// See docs/mutation-testing.md.

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const mutationUsage = `Usage: bashx mutate [options] <script.sh>...

Mutates each script, runs its tests (<dir>/<name>.test.sh and
<dir>/<name>.*.test.sh by default) against every mutant, prints a Markdown
report.

  -t <test>     test file to run (repeatable; default: the script's own tests)
  -o <ops>      operators or groups, comma-separated (default: all; see -L)
  -k <order>    1 = one mutation per mutant, 2 = pairs on two lines (default: 1)
  -m <max>      run at most <max> mutants, sampled deterministically (default: all)
  -j <jobs>     parallel project copies (default: CPU count)
  -T <seconds>  per-test deadline (default: 3 x baseline + 5, at least 10)
  -s <score>    exit 1 when a script scores under <score> % (default: off)
  -r <file>     also write one TSV row per mutant to <file>
  -n            dry run: count the mutants, run nothing
  -L            list the operators
  -h            this help

Lines with a "# no-mutate[: why]" comment are left alone.
`

// operator: a name, an ERE that locates it (with its context), the literal it
// replaces inside that match, the replacement, and an optional ERE the whole
// line must match. stmt-del is handled by deletable.
type operator struct {
	name, re, from, to, guard string
	reC, guardC               *regexp.Regexp
}

var operators = []operator{
	{name: "rel-eq", re: ` -eq `, from: "-eq", to: "-ne"},
	{name: "rel-ne", re: ` -ne `, from: "-ne", to: "-eq"},
	{name: "rel-lt", re: ` -lt `, from: "-lt", to: "-le"},
	{name: "rel-le", re: ` -le `, from: "-le", to: "-lt"},
	{name: "rel-gt", re: ` -gt `, from: "-gt", to: "-ge"},
	{name: "rel-ge", re: ` -ge `, from: "-ge", to: "-gt"},
	{name: "str-eq", re: ` == `, from: "==", to: "!="},
	{name: "str-ne", re: ` != `, from: "!=", to: "=="},
	{name: "str-z", re: `\[\[ -z `, from: "-z", to: "-n"},
	{name: "str-n", re: `\[\[ -n `, from: "-n", to: "-z"},
	{name: "arith-lt", re: ` < `, from: "<", to: "<=", guard: `\(\(`},
	{name: "arith-le", re: ` <= `, from: "<=", to: "<", guard: `\(\(`},
	{name: "arith-gt", re: ` > `, from: ">", to: ">=", guard: `\(\(`},
	{name: "arith-ge", re: ` >= `, from: ">=", to: ">", guard: `\(\(`},
	{name: "arith-add", re: ` \+ `, from: "+", to: "-", guard: `\(\(`},
	{name: "arith-sub", re: ` - `, from: "-", to: "+", guard: `\(\(`},
	{name: "arith-mul", re: ` \* `, from: "*", to: "/", guard: `\(\(`},
	{name: "arith-div", re: ` / `, from: "/", to: "*", guard: `\(\(`},
	{name: "arith-mod", re: ` % `, from: "%", to: "*", guard: `\(\(`},
	{name: "arith-incr", re: `\+\+`, from: "++", to: "--"},
	{name: "cond-neg", re: `\[\[ [^!]`, from: "[[", to: "[[ !"},
	{name: "cond-drop-neg", re: `(if|elif|while|&&|\|\||\[\[) ! `, from: "! ", to: ""},
	{name: "logic-and", re: ` && `, from: "&&", to: "||"},
	{name: "logic-or", re: ` \|\| `, from: "||", to: "&&"},
	{name: "ret-0", re: `(return|exit) 0([^0-9]|$)`, from: " 0", to: " 1"},
	{name: "ret-1", re: `(return|exit) 1([^0-9]|$)`, from: " 1", to: " 0"},
	{name: "bool-true", re: `(^|[^[:alnum:]_:-])true([^[:alnum:]_:-]|$)`, from: "true", to: "false"},
	{name: "bool-false", re: `(^|[^[:alnum:]_:-])false([^[:alnum:]_:-]|$)`, from: "false", to: "true"},
	{name: "stmt-del", from: "<command>", to: ":"},
}

func init() {
	for i := range operators {
		op := &operators[i]
		// POSIX (leftmost-longest) matching, as awk's match().
		if op.re != "" {
			op.reC = regexp.MustCompilePOSIX(op.re)
		}
		if op.guard != "" {
			op.guardC = regexp.MustCompilePOSIX(op.guard)
		}
	}
}

func operatorRank(name string) int {
	for i, op := range operators {
		if op.name == name {
			return i + 1
		}
	}
	return 0
}

// selectOperators keeps the operators named in a comma list, by name or group
// prefix ("rel", "arith-add"); all of them when the list is empty.
func selectOperators(list string) []operator {
	if list == "" {
		return operators
	}
	want := strings.Split(list, ",")
	var out []operator
	for _, op := range operators {
		for _, w := range want {
			if op.name == w || strings.HasPrefix(op.name, w+"-") {
				out = append(out, op)
				break
			}
		}
	}
	return out
}

// mutation: one changed line of a mutant.
type mutation struct {
	line int
	text string
}

// mutant: one or two mutations (order 2: on two different lines).
type mutant struct {
	id      int
	op      string
	changes []mutation
}

var (
	commentOnlyRe = regexp.MustCompilePOSIX(`^[ \t]*(#|$)`)
	noMutateRe    = regexp.MustCompilePOSIX(`[ \t]#[ \t]*no-mutate([ \t:]|$)`)
	commentRe     = regexp.MustCompilePOSIX(`[ \t]#`)
	heredocPosix  = regexp.MustCompilePOSIX(`<<-?[ \t]*["']?[A-Za-z_][A-Za-z0-9_]*`)
	keywordRe     = regexp.MustCompilePOSIX(`^(if|then|else|elif|fi|for|while|until|do|done|case|esac|function|select|set|shopt)([ \t;]|$)`)
	bareDeclRe    = regexp.MustCompilePOSIX(`^(local|declare|readonly|typeset|export)( +-[a-zA-Z]+)*( +[A-Za-z_][A-Za-z0-9_]*)+$`)
	blockOpenRe   = regexp.MustCompilePOSIX(`(\{|\(|\\|\||&&|then|do|in)$`)
	patternRe     = regexp.MustCompilePOSIX(`^[^(]*\)`)
)

// fileLines splits a file as `mapfile -t` does.
func fileLines(data string) []string {
	if data == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(data, "\n"), "\n")
}

// generate lists the first-order mutants of a script. Skips blank and
// comment lines, heredoc bodies, "# no-mutate" lines, and trailing comments.
// Every match of an operator on a line is its own mutant.
func generate(content string, ops []operator) []mutant {
	var out []mutant
	heredoc := ""
	for i, line := range fileLines(content) {
		nr := i + 1
		if heredoc != "" {
			if strings.TrimLeft(line, " \t") == heredoc {
				heredoc = ""
			}
			continue
		}
		if !strings.Contains(line, "<<<") {
			if m := heredocPosix.FindString(line); m != "" {
				heredoc = heredocHead.ReplaceAllString(m, "")
			}
		}
		if commentOnlyRe.MatchString(line) || noMutateRe.MatchString(line) {
			continue
		}
		code, comment := line, ""
		if loc := commentRe.FindStringIndex(code); loc != nil {
			code, comment = line[:loc[0]], line[loc[0]:]
		}
		for _, op := range ops {
			if op.name == "stmt-del" {
				if deletable(code) {
					indent := code[:len(code)-len(strings.TrimLeft(code, " \t"))]
					out = append(out, mutant{op: op.name, changes: []mutation{{nr, indent + ":" + comment}}})
				}
				continue
			}
			if op.guardC != nil && !op.guardC.MatchString(code) {
				continue
			}
			rest, off := code, 0
			for rest != "" {
				loc := op.reC.FindStringIndex(rest)
				if loc == nil {
					break
				}
				p := strings.Index(rest[loc[0]:loc[1]], op.from)
				start := off + loc[0] + p // 0-based, in code
				out = append(out, mutant{op: op.name, changes: []mutation{{nr, code[:start] + op.to + code[start+len(op.from):] + comment}}})
				adv := loc[0] + p + len(op.from) // just past the replaced literal
				if adv < 1 {
					adv = 1
				}
				off += adv
				rest = rest[adv:]
			}
		}
	}
	return out
}

// deletable: a command that can become `:` (not a keyword, a bare
// declaration, a block edge or a continued line).
func deletable(s string) bool {
	t := strings.Trim(s, " \t")
	if strings.HasPrefix(t, ";;") || strings.HasSuffix(t, ";;") {
		return false
	}
	t = strings.TrimRight(t, " \t;")
	if keywordRe.MatchString(t) || bareDeclRe.MatchString(t) {
		return false
	}
	if strings.HasPrefix(t, "{") || strings.HasPrefix(t, "}") || strings.HasPrefix(t, "(") || strings.HasPrefix(t, ")") || blockOpenRe.MatchString(t) {
		return false
	}
	return !patternRe.MatchString(t) && t != ":"
}

// pairs: every pair of first-order mutants on two different lines, named
// op1+op2 (names sorted).
func pairs(first []mutant) []mutant {
	var out []mutant
	for i := range first {
		for j := i + 1; j < len(first); j++ {
			a, b := first[i], first[j]
			if a.changes[0].line == b.changes[0].line {
				continue
			}
			name := a.op + "+" + b.op
			if b.op < a.op {
				name = b.op + "+" + a.op
			}
			out = append(out, mutant{op: name, changes: []mutation{a.changes[0], b.changes[0]}})
		}
	}
	return out
}

// sample keeps max mutants, the same ones on every run (0 keeps all).
func sample(ms []mutant, max int) []mutant {
	if max == 0 {
		return ms
	}
	out := append([]mutant(nil), ms...)
	rand.New(rand.NewSource(1)).Shuffle(len(out), func(i, j int) { out[i], out[j] = out[j], out[i] })
	if max < len(out) {
		out = out[:max]
	}
	return out
}

// mutantsOf: the numbered mutants of a script for an order, sampled to max.
func mutantsOf(content string, ops []operator, order, max int) []mutant {
	ms := generate(content, ops)
	if order == 2 {
		ms = pairs(ms)
	}
	ms = sample(ms, max)
	for i := range ms {
		ms[i].id = i + 1
	}
	return ms
}

// ownTests: <dir>/<name>.test.sh and <dir>/<name>.*.test.sh, relative to dir.
func ownTests(dir, script string) []string {
	base := strings.TrimSuffix(script, ".sh")
	var out []string
	if st, err := os.Stat(filepath.Join(dir, base+".test.sh")); err == nil && st.Mode().IsRegular() {
		out = append(out, base+".test.sh")
	}
	matches, _ := filepath.Glob(filepath.Join(dir, globEscape(base)+".*.test.sh"))
	for _, m := range matches {
		if st, err := os.Stat(m); err == nil && st.Mode().IsRegular() {
			rel, _ := filepath.Rel(dir, m)
			out = append(out, rel)
		}
	}
	return out
}

func globEscape(s string) string {
	return regexp.MustCompile(`[*?\[\\]`).ReplaceAllString(s, `\$0`)
}

// sandbox copies the project's working tree (tracked + untracked, not
// ignored) into dest, committed in a fresh git repo so `git rev-parse` and
// `git ls-files` answer inside it as they do in the checkout.
func sandbox(root, dest string) error {
	out, err := exec.Command("git", "-C", root, "ls-files", "-z", "-co", "--exclude-standard").Output()
	if err != nil {
		return fmt.Errorf("git ls-files in %s: %w", root, err)
	}
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return err
	}
	for _, rel := range strings.Split(string(out), "\x00") {
		if rel == "" {
			continue
		}
		if err := copyPath(filepath.Join(root, rel), filepath.Join(dest, rel)); err != nil {
			return err
		}
	}
	git := func(args ...string) error {
		cmd := exec.Command("git", append([]string{"-C", dest}, args...)...)
		cmd.Stderr = os.Stderr
		return cmd.Run()
	}
	if err := git("init", "-q"); err != nil {
		return err
	}
	if err := git("add", "-A"); err != nil {
		return err
	}
	return git("-c", "user.name=mutation", "-c", "user.email=mutation@localhost", "-c", "commit.gpgsign=false",
		"commit", "-qm", "sandbox", "--no-verify")
}

// copyPath copies a file, a link or a directory (a submodule) with its mode;
// a path that no longer exists is skipped.
func copyPath(src, dst string) error {
	st, err := os.Lstat(src)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	switch {
	case st.Mode()&os.ModeSymlink != 0:
		target, err := os.Readlink(src)
		if err != nil {
			return err
		}
		os.Remove(dst)
		return os.Symlink(target, dst)
	case st.IsDir():
		entries, err := os.ReadDir(src)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(dst, st.Mode().Perm()|0o700); err != nil {
			return err
		}
		for _, e := range entries {
			if err := copyPath(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())); err != nil {
				return err
			}
		}
		return nil
	case st.Mode().IsRegular():
		in, err := os.Open(src)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, st.Mode().Perm())
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, in); err != nil {
			out.Close()
			return err
		}
		return out.Close()
	}
	return nil
}

var failedCountRe = regexp.MustCompile(`(?m)^failed=[1-9]`)

// runTest runs one test file from its directory in the sandbox and returns
// its exit code: 124 past the deadline. As in `bashx test`, failed cases in
// BASHX_RESULT_FILE fail the file even when it exits 0 (a library's EXIT trap
// can swallow the status).
func runTest(lib, sandboxDir string, deadline time.Duration, testFile string) int {
	result := filepath.Join(sandboxDir, ".mutation-result")
	os.Remove(result)
	cmd := exec.Command("bash", filepath.Base(testFile))
	cmd.Dir = filepath.Join(sandboxDir, filepath.Dir(testFile))
	cmd.Env = append(os.Environ(), "BASHX_RESULT_FILE="+result, "BASHX_LIB="+lib, "NO_COLOR=1")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return 127
	}
	pgid := cmd.Process.Pid
	var timedOut atomic.Bool
	// Past the deadline: TERM the group, then KILL it 5 s later (timeout -k 5).
	timer := time.AfterFunc(deadline, func() {
		timedOut.Store(true)
		syscall.Kill(-pgid, syscall.SIGTERM)
		time.AfterFunc(5*time.Second, func() { syscall.Kill(-pgid, syscall.SIGKILL) })
	})
	err := cmd.Wait()
	timer.Stop()
	syscall.Kill(-pgid, syscall.SIGKILL) // leaked children do not outlive the test
	rc := 0
	if err != nil {
		if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			rc = 128 + int(ws.Signal())
		} else {
			rc = cmd.ProcessState.ExitCode()
		}
	}
	if timedOut.Load() {
		return 124
	}
	if rc == 0 {
		if data, err := os.ReadFile(result); err == nil && failedCountRe.Match(data) {
			rc = 1
		}
	}
	return rc
}

// apply returns the original lines with the mutant's changes, as a file.
func apply(original []string, changes []mutation) string {
	lines := append([]string(nil), original...)
	for _, c := range changes {
		for len(lines) < c.line {
			lines = append(lines, "")
		}
		lines[c.line-1] = c.text
	}
	return strings.Join(lines, "\n") + "\n"
}

// mutationDeadline: 3 × the tests' unmutated time + 5 s, at least 10 s.
func mutationDeadline(baselineMs int64) int64 {
	secs := (3*baselineMs+999)/1000 + 5
	if secs < 10 {
		secs = 10
	}
	return secs
}

// outcome of one mutant.
type outcome struct {
	status string // killed, timeout, survived, invalid (the mutant does not parse)
	ms     int64
}

// worker runs its mutants in one sandbox, restoring the script after.
func worker(lib, sandboxDir, script string, deadline time.Duration, queue []mutant, tests []string, record func(int, outcome)) {
	target := filepath.Join(sandboxDir, script)
	data, err := os.ReadFile(target)
	if err != nil {
		return
	}
	st, _ := os.Stat(target)
	original := fileLines(string(data))
	defer os.WriteFile(target, data, st.Mode().Perm())
	for _, m := range queue {
		start := time.Now()
		os.WriteFile(target, []byte(apply(original, m.changes)), st.Mode().Perm())
		status := "survived"
		if exec.Command("bash", "-n", target).Run() != nil {
			status = "invalid"
		} else {
			for _, t := range tests {
				rc := runTest(lib, sandboxDir, deadline, t)
				if rc == 124 || rc == 137 {
					status = "timeout"
					break
				}
				if rc != 0 {
					status = "killed"
					break
				}
			}
		}
		record(m.id, outcome{status, time.Since(start).Milliseconds()})
	}
}

// scriptRun: the result of one script, for its report.
type scriptRun struct {
	script     string
	order      int
	baselineMs int64
	elapsed    int64
	tests      []string
	mutants    []mutant
	outcomes   map[int]outcome
	original   []string
}

type tally struct{ n, killed, timeout, survived, invalid int }

func (t *tally) add(status string) {
	t.n++
	switch status {
	case "killed":
		t.killed++
	case "timeout":
		t.timeout++
	case "survived":
		t.survived++
	case "invalid":
		t.invalid++
	}
}

func (t tally) score() string {
	v := t.killed + t.timeout + t.survived
	if v == 0 {
		return "n/a"
	}
	return fmt.Sprintf("%.1f%%", float64(t.killed+t.timeout)*100/float64(v))
}

func escapePipes(s string) string { return strings.ReplaceAll(s, "|", `\|`) }

func operatorDescription(name string) string {
	if name == "stmt-del" {
		return "command → `:`"
	}
	for _, op := range operators {
		if op.name == name {
			return "`" + escapePipes(op.from) + "` → `" + escapePipes(op.to) + "`"
		}
	}
	a, b, _ := strings.Cut(name, "+")
	return "combination of " + a + " and " + b
}

// operatorKey orders operators as the table lists them, a pair after its
// first operator.
func operatorKey(name string) string {
	a, b, isPair := strings.Cut(name, "+")
	if !isPair {
		return fmt.Sprintf("%04d", operatorRank(name))
	}
	return fmt.Sprintf("%04d%04d", operatorRank(a), operatorRank(b))
}

func trimForReport(s string) string {
	s = strings.TrimLeft(s, " \t\n\r\v\f")
	s = strings.ReplaceAll(s, "`", "'")
	if r := []rune(s); len(r) > 120 {
		s = string(r[:120])
	}
	return s
}

// report writes one script's Markdown report: header, table, survivors.
func (r *scriptRun) report(w io.Writer) tally {
	var testsMd string
	for _, t := range r.tests {
		testsMd += "`" + filepath.Base(t) + "` "
	}
	fmt.Fprintf(w, "### `%s`\n\nTests: %s(%d ms unmutated) · order %d · %d s\n\n", r.script, testsMd, r.baselineMs, r.order, r.elapsed)
	fmt.Fprintln(w, "| Operator | Mutation | Mutants | Killed | Timeout | Survived | Invalid | Score |")
	fmt.Fprintln(w, "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |")
	per := map[string]*tally{}
	var names []string
	var total tally
	for _, m := range r.mutants {
		if per[m.op] == nil {
			per[m.op] = &tally{}
			names = append(names, m.op)
		}
		status := r.outcomes[m.id].status
		per[m.op].add(status)
		total.add(status)
	}
	sort.SliceStable(names, func(i, j int) bool { return operatorKey(names[i]) < operatorKey(names[j]) })
	row := func(op, desc string, t tally) {
		fmt.Fprintf(w, "| %s | %s | %d | %d | %d | %d | %d | %s |\n", op, desc, t.n, t.killed, t.timeout, t.survived, t.invalid, t.score())
	}
	for _, name := range names {
		row(name, operatorDescription(name), *per[name])
	}
	row("**Total**", "", total)

	var survivors []mutant
	for _, m := range r.mutants {
		if r.outcomes[m.id].status == "survived" {
			survivors = append(survivors, m)
		}
	}
	sort.SliceStable(survivors, func(i, j int) bool { return survivors[i].changes[0].line < survivors[j].changes[0].line })
	if len(survivors) > 0 {
		fmt.Fprintf(w, "\n<details><summary>Survivors (%d)</summary>\n\n", len(survivors))
		for i, m := range survivors {
			if i == 40 {
				break
			}
			for _, c := range m.changes {
				before := ""
				if c.line-1 < len(r.original) {
					before = r.original[c.line-1]
				}
				fmt.Fprintf(w, "- `%s:%d` %s: `%s` → `%s`\n", r.script, c.line, m.op, trimForReport(before), trimForReport(c.text))
			}
		}
		fmt.Fprintln(w, "\n</details>")
	}
	fmt.Fprintln(w)
	return total
}

// tsvRows: one row per mutant: script, id, operator, status, ms, line, text...
func (r *scriptRun) tsvRows(w io.Writer) {
	for _, m := range r.mutants {
		o := r.outcomes[m.id]
		fmt.Fprintf(w, "%s\t%d\t%s\t%s\t%d", r.script, m.id, m.op, o.status, o.ms)
		for _, c := range m.changes {
			fmt.Fprintf(w, "\t%d\t%s", c.line, c.text)
		}
		fmt.Fprintln(w)
	}
}

// summaryRow: one script of the cross-script table.
type summaryRow struct {
	script  string
	t       tally
	elapsed int64
}

func reportSummary(w io.Writer, rows []summaryRow) {
	if len(rows) < 2 {
		return
	}
	fmt.Fprint(w, "### Summary\n\n| Script | Mutants | Killed | Timeout | Survived | Invalid | Score | Time |\n| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n")
	var total tally
	var secs int64
	for _, r := range rows {
		fmt.Fprintf(w, "| `%s` | %d | %d | %d | %d | %d | %s | %d s |\n", r.script, r.t.n, r.t.killed, r.t.timeout, r.t.survived, r.t.invalid, r.t.score(), r.elapsed)
		total.n += r.t.n
		total.killed += r.t.killed
		total.timeout += r.t.timeout
		total.survived += r.t.survived
		total.invalid += r.t.invalid
		secs += r.elapsed
	}
	fmt.Fprintf(w, "| **Total** | %d | %d | %d | %d | %d | %s | %d s |\n", total.n, total.killed, total.timeout, total.survived, total.invalid, total.score(), secs)
}

// belowMinScore: the score of t is under min (an empty min never is).
func belowMinScore(t tally, min string) bool {
	if min == "" {
		return false
	}
	m, _ := strconv.ParseFloat(min, 64)
	v := t.killed + t.timeout + t.survived
	return v > 0 && float64(t.killed+t.timeout)*100/float64(v) < m
}

func listOperators(w io.Writer) {
	fmt.Fprint(w, "| Operator | Mutation | Only on lines matching |\n| --- | --- | --- |\n")
	for _, op := range operators {
		guard := ""
		if op.guard != "" {
			guard = "`" + escapePipes(op.guard) + "`"
		}
		fmt.Fprintf(w, "| %s | %s | %s |\n", op.name, operatorDescription(op.name), guard)
	}
}

type mutationOptions struct {
	tests                   []string
	ops                     string
	order, max, jobs        int
	deadline, minScore, tsv string
	dry                     int // 1: count, 2: list the operators
	scripts                 []string
}

var (
	orderRe  = regexp.MustCompile(`^[12]$`)
	countRe  = regexp.MustCompile(`^[0-9]+$`)
	secondRe = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?$`)
)

// parseMutationArgs reads options as getopts "t:o:k:m:j:T:s:r:nLh" does:
// up to the first operand. Returns the exit code to stop with, or -1.
func parseMutationArgs(args []string) (mutationOptions, int) {
	o := mutationOptions{order: 1, jobs: cpuCount()}
	orderS, maxS, jobsS := "1", "0", strconv.Itoa(o.jobs)
	bad := func() (mutationOptions, int) {
		fmt.Fprint(os.Stderr, mutationUsage)
		return o, 2
	}
	i := 0
	for ; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			i++
			break
		}
		if len(a) < 2 || a[0] != '-' {
			break
		}
		for j := 1; j < len(a); j++ {
			c := a[j]
			if strings.IndexByte("tokmjTsr", c) >= 0 {
				val := a[j+1:]
				if val == "" {
					if i+1 >= len(args) {
						return bad()
					}
					i++
					val = args[i]
				}
				switch c {
				case 't':
					o.tests = append(o.tests, val)
				case 'o':
					o.ops = val
				case 'k':
					orderS = val
				case 'm':
					maxS = val
				case 'j':
					jobsS = val
				case 'T':
					o.deadline = val
				case 's':
					o.minScore = val
				case 'r':
					o.tsv = val
				}
				break
			}
			switch c {
			case 'n':
				o.dry = 1
			case 'L':
				o.dry = 2
			case 'h':
				fmt.Print(mutationUsage)
				return o, 0
			default:
				return bad()
			}
		}
	}
	o.scripts = args[i:]
	if !orderRe.MatchString(orderS) || !countRe.MatchString(maxS) || !positiveRe.MatchString(jobsS) ||
		(o.deadline != "" && !secondRe.MatchString(o.deadline)) {
		return bad()
	}
	o.order, _ = strconv.Atoi(orderS)
	o.max, _ = strconv.Atoi(maxS)
	o.jobs, _ = strconv.Atoi(jobsS)
	if o.dry != 2 && len(o.scripts) == 0 {
		return bad()
	}
	return o, -1
}

func cpuCount() int {
	n := 4
	if out, err := exec.Command("getconf", "_NPROCESSORS_ONLN").Output(); err == nil {
		if v, err := strconv.Atoi(strings.TrimSpace(string(out))); err == nil && v > 0 {
			n = v
		}
	}
	return n
}

// relToRoot: the path of p (relative to the current dir) from root, links
// resolved as `realpath --relative-to` does.
func relToRoot(root, p string) string {
	abs, err := filepath.Abs(p)
	if err != nil {
		return p
	}
	if real, err := filepath.EvalSymlinks(abs); err == nil {
		abs = real
	} else if dir, err := filepath.EvalSymlinks(filepath.Dir(abs)); err == nil {
		abs = filepath.Join(dir, filepath.Base(abs))
	}
	rel, err := filepath.Rel(root, abs)
	if err != nil {
		return p
	}
	return rel
}

func mutationMain(lib string, args []string) int {
	o, rc := parseMutationArgs(args)
	if rc >= 0 {
		return rc
	}
	if o.dry == 2 {
		listOperators(os.Stdout)
		return 0
	}
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error: bashx mutate runs inside a git repository (it copies the tracked files)")
		return 2
	}
	root := strings.TrimSpace(string(out))
	if real, err := filepath.EvalSymlinks(root); err == nil {
		root = real
	}
	ops := selectOperators(o.ops)
	if len(ops) == 0 {
		fmt.Fprintf(os.Stderr, "error: no operator matches -o %s\n", o.ops)
		return 2
	}

	if o.dry == 1 {
		fmt.Print("| Script | Lines | Mutants (order 1) | Pairs (order 2) |\n| --- | ---: | ---: | ---: |\n")
		for _, s := range o.scripts {
			rel := relToRoot(root, s)
			data, err := os.ReadFile(filepath.Join(root, rel))
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 1
			}
			first := generate(string(data), ops)
			fmt.Printf("| `%s` | %d | %d | %d |\n", rel, strings.Count(string(data), "\n"), len(first), len(pairs(first)))
		}
		return 0
	}

	tmp := os.Getenv("TMPDIR")
	if tmp == "" {
		tmp = "/tmp"
	}
	workdir, err := os.MkdirTemp(tmp, "tmp.")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer os.RemoveAll(workdir)
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		os.RemoveAll(workdir)
		os.Exit(130)
	}()

	fmt.Fprintf(os.Stderr, "mutation: copying the repo into %d sandboxes\n", o.jobs)
	sandboxes := make([]string, o.jobs)
	errs := make([]error, o.jobs)
	var wg sync.WaitGroup
	for w := range sandboxes {
		sandboxes[w] = filepath.Join(workdir, fmt.Sprintf("sandbox-%d", w))
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			errs[w] = sandbox(root, sandboxes[w])
		}(w)
	}
	wg.Wait()
	for _, err := range errs {
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			return 1
		}
	}

	var tsv *bufio.Writer
	if o.tsv != "" {
		f, err := os.Create(o.tsv)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		defer f.Close()
		tsv = bufio.NewWriter(f)
		defer tsv.Flush()
		fmt.Fprint(tsv, "script\tid\toperator\tstatus\tms\tline\ttext\n")
	}

	stdout := bufio.NewWriter(os.Stdout)
	defer stdout.Flush()
	fmt.Fprint(stdout, "## Mutation testing\n\n")
	failed := 0
	var summaries []summaryRow
	for _, s := range o.scripts {
		rel := relToRoot(root, s)
		var tests []string
		if len(o.tests) > 0 {
			for _, t := range o.tests {
				tests = append(tests, relToRoot(root, t))
			}
		} else {
			tests = ownTests(root, rel)
		}
		if len(tests) == 0 {
			stdout.Flush()
			fmt.Fprintf(os.Stderr, "error: no test for %s: pass -t <test>\n", rel)
			return 2
		}
		run, err := runScript(lib, sandboxes, rel, ops, o, tests)
		if err != nil {
			stdout.Flush()
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		t := run.report(stdout)
		stdout.Flush()
		if tsv != nil {
			run.tsvRows(tsv)
		}
		summaries = append(summaries, summaryRow{rel, t, run.elapsed})
		if belowMinScore(t, o.minScore) {
			failed = 1
		}
	}
	reportSummary(stdout, summaries)
	return failed
}

// runScript runs every mutant of one script over the sandboxes.
func runScript(lib string, sandboxes []string, script string, ops []operator, o mutationOptions, tests []string) (*scriptRun, error) {
	started := time.Now()
	for _, t := range tests {
		if rc := runTest(lib, sandboxes[0], 600*time.Second, t); rc != 0 {
			return nil, fmt.Errorf("error: %s fails before any mutation (exit %d): fix it first", t, rc)
		}
	}
	baselineMs := time.Since(started).Milliseconds()
	deadline := time.Duration(mutationDeadline(baselineMs)) * time.Second
	if o.deadline != "" {
		secs, _ := strconv.ParseFloat(o.deadline, 64)
		deadline = time.Duration(secs * float64(time.Second))
	}

	data, err := os.ReadFile(filepath.Join(sandboxes[0], script))
	if err != nil {
		return nil, fmt.Errorf("error: %w", err)
	}
	ms := mutantsOf(string(data), ops, o.order, o.max)
	jobs := len(sandboxes)
	fmt.Fprintf(os.Stderr, "mutation: %s: %d mutants, %d jobs, tests %d ms unmutated\n", script, len(ms), jobs, baselineMs)

	run := &scriptRun{script: script, order: o.order, baselineMs: baselineMs, tests: tests, mutants: ms,
		outcomes: map[int]outcome{}, original: fileLines(string(data))}
	var mu sync.Mutex
	record := func(id int, out outcome) {
		mu.Lock()
		run.outcomes[id] = out
		mu.Unlock()
	}
	var wg sync.WaitGroup
	for w := 0; w < jobs; w++ {
		var queue []mutant
		for i := w; i < len(ms); i += jobs {
			queue = append(queue, ms[i])
		}
		wg.Add(1)
		go func(w int, queue []mutant) {
			defer wg.Done()
			worker(lib, sandboxes[w], script, deadline, queue, tests, record)
		}(w, queue)
	}
	progress(&wg, len(ms), func() int {
		mu.Lock()
		defer mu.Unlock()
		return len(run.outcomes)
	})
	run.elapsed = int64(time.Since(started).Seconds())
	return run, nil
}

// progress waits for the workers, printing "done/total" on stderr every
// MUTATION_PROGRESS_EVERY seconds (default 10).
func progress(wg *sync.WaitGroup, total int, done func() int) {
	every := 10
	if v, err := strconv.Atoi(os.Getenv("MUTATION_PROGRESS_EVERY")); err == nil && v > 0 {
		every = v
	}
	finished := make(chan struct{})
	go func() {
		wg.Wait()
		close(finished)
	}()
	ticker := time.NewTicker(time.Duration(every) * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-finished:
			return
		case <-ticker.C:
			fmt.Fprintf(os.Stderr, "mutation: %d/%d\n", done(), total)
		}
	}
}
