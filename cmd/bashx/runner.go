package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const runnerUsage = `Usage: bashx test [options] [<root>]

Runs every *.test.sh under <root> (default: the git root, or the current dir).

  --kind=KIND             only *.KIND.test.sh (e.g. unit, integration)
  --jobs=N                files run in parallel (default: CPU count, BASHX_JOBS)
  --timeout=SECONDS       deadline per file (default: 60, BASHX_TIMEOUT)
  --shard=I/N             run part I of N (CI matrix), balanced on durations
  --durations=FILE        durations for --shard (default: <root>/.bashx/durations.tsv)
  --record-durations=FILE write each file's wall time to FILE
  --coverage=DIR          trace the run, write DIR/covered.tsv, print the score
  --report=FORMAT         also write test_report.FORMAT (markdown, json, junit)
  --filter=TEXT           only the cases whose description contains TEXT
  -v, --verbose           show what passing cases print, too
  -h, --help              this help
`

var (
	ansiRe     = regexp.MustCompile("\x1b\\[[0-9;?]*[a-zA-Z]")
	positiveRe = regexp.MustCompile(`^[1-9][0-9]*$`)
	shardRe    = regexp.MustCompile(`^([0-9]+)/([0-9]+)$`)
	secsRe     = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?$`)
	requiresRe = regexp.MustCompile(`^#[[:space:]]*@requires[[:space:]]+`)
)

func stripANSI(s string) string { return ansiRe.ReplaceAllString(s, "") }

// escapeField is test::_escape: \\, \t, \n, \r.
func escapeField(s string) string {
	return strings.NewReplacer("\\", "\\\\", "\t", "\\t", "\n", "\\n", "\r", "\\r").Replace(s)
}

// unescapeField reads back escapeField, trailing newlines dropped.
func unescapeField(s string) string {
	if strings.IndexByte(s, '\\') >= 0 {
		var b strings.Builder
		for i := 0; i < len(s); i++ {
			c := s[i]
			if c == '\\' && i+1 < len(s) {
				switch s[i+1] {
				case '\\':
					b.WriteByte('\\')
					i++
					continue
				case 't':
					b.WriteByte('\t')
					i++
					continue
				case 'n':
					b.WriteByte('\n')
					i++
					continue
				case 'r':
					b.WriteByte('\r')
					i++
					continue
				}
			}
			b.WriteByte(c)
		}
		s = b.String()
	}
	return strings.TrimRight(s, "\n")
}

func relativePath(root, file string) string { return strings.TrimPrefix(file, root+"/") }

// discover lists the test files under root, sorted, skipping dependency dirs
// and nested git repositories.
func discover(root, kind string) []string {
	pattern := "*.test.sh"
	if kind != "" {
		pattern = "*." + kind + ".test.sh"
	}
	pruned := map[string]bool{".git": true, "node_modules": true, ".venv": true, "venv": true, ".cache": true, ".bashx": true}
	var files []string
	filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if path != root && pruned[d.Name()] {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			if path != root {
				if _, err := os.Lstat(filepath.Join(path, ".git")); err == nil {
					return filepath.SkipDir // a nested repository: its tests are its own
				}
			}
			return nil
		}
		if d.Type().IsRegular() {
			if ok, _ := filepath.Match(pattern, d.Name()); ok {
				files = append(files, path)
			}
		}
		return nil
	})
	sort.Strings(files)
	return files
}

// plan returns the files of shard index/count, longest first (LPT).
func plan(root, durations string, index, count int, files []string) []string {
	weight := map[string]float64{}
	if data, err := os.ReadFile(durations); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			secs, rel, ok := strings.Cut(line, "\t")
			if !ok || !secsRe.MatchString(secs) {
				continue
			}
			if w, err := strconv.ParseFloat(secs, 64); err == nil {
				weight[rel] = w
			}
		}
	}
	type entry struct {
		w         float64
		rel, file string
	}
	entries := make([]entry, len(files))
	for i, f := range files {
		rel := relativePath(root, f)
		w, ok := weight[rel]
		if !ok {
			w = 1
		}
		entries[i] = entry{w, rel, f}
	}
	sort.SliceStable(entries, func(i, j int) bool {
		if entries[i].w != entries[j].w {
			return entries[i].w > entries[j].w
		}
		return entries[i].rel < entries[j].rel
	})
	load := make([]float64, count+1)
	var out []string
	for _, e := range entries {
		best := 1
		for i := 2; i <= count; i++ {
			if load[i] < load[best] {
				best = i
			}
		}
		load[best] += e.w
		if best == index {
			out = append(out, e.file)
		}
	}
	return out
}

// requirements reads the `# @requires` commands of the file header.
func requirements(file string) []string {
	f, err := os.Open(file)
	if err != nil {
		return nil
	}
	defer f.Close()
	var cmds []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "#!"):
			continue
		case strings.TrimFunc(line, isSpace) == "":
			continue
		case strings.HasPrefix(line, "#"):
			if loc := requiresRe.FindStringIndex(line); loc != nil {
				cmds = append(cmds, strings.Fields(line[loc[1]:])...)
			}
			continue
		}
		break
	}
	return cmds
}

func isSpace(r rune) bool {
	return r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == '\v' || r == '\f'
}

// hasCommand is `command -v`: a program on PATH, or else whatever bash knows
// (builtins, keywords).
func hasCommand(name string) bool {
	if _, err := exec.LookPath(name); err == nil {
		return true
	}
	return exec.Command("bash", "-c", `command -v "$1" >/dev/null 2>&1`, "_", name).Run() == nil
}

// fileResult is what a finished test file left.
type fileResult struct {
	id       int
	file     string
	exitCode int
	timedOut bool
	elapsed  string // seconds, %.1f; "" for a skipped file
	out      []byte
	result   string // path of its result file
	cases    string // path of its cases file
}

type runner struct {
	lib, root, work string
	timeout         int
	coverage        bool

	stdout  io.Writer
	logFile *os.File

	files, passed, failed, skipped, total int
	expected                              int
	failedFiles                           []int // indexes, sorted at the end
	casesOut                              *os.File

	mu    sync.Mutex
	pgids map[int]int
}

func nowString(started time.Time) string {
	return fmt.Sprintf("%.1f", time.Since(started).Seconds())
}

// runOne runs a test file isolated: own process group, no stdin, a deadline.
func (r *runner) runOne(id int, file string) fileResult {
	started := time.Now()
	res := fileResult{id: id, file: file,
		result: filepath.Join(r.work, fmt.Sprintf("%d.result", id)),
		cases:  filepath.Join(r.work, fmt.Sprintf("%d.cases", id))}
	display := relativePath(r.root, file)

	var missing string
	for _, cmd := range requirements(file) {
		if !hasCommand(cmd) {
			missing += " " + cmd
		}
	}
	if missing != "" {
		res.out = []byte(fmt.Sprintf("🧪 ./%s\n└── ○ Skipped (requires%s)\n", display, missing))
		os.WriteFile(res.result, []byte("passed=0\nfailed=0\nskipped=1\ntotal=0\n"), 0o644)
		return res
	}

	outPath := filepath.Join(r.work, fmt.Sprintf("%d.out", id))
	out, err := os.Create(outPath)
	if err != nil {
		res.exitCode = 1
		res.out = []byte(err.Error() + "\n")
		return res
	}
	cmd := exec.Command("bash", file)
	cmd.Dir = filepath.Dir(file)
	cmd.Stdout, cmd.Stderr = out, out
	env := append(os.Environ(), "BASHX_RESULT_FILE="+res.result, "BASHX_CASES_FILE="+res.cases, "BASHX_LIB="+r.lib)
	if r.coverage {
		env = append(env, "BASH_ENV="+filepath.Join(r.lib, "coverage-trace.bash"))
	}
	cmd.Env = env
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		out.Close()
		res.exitCode = 127
		res.out = []byte(err.Error() + "\n")
		res.elapsed = nowString(started)
		return res
	}
	pgid := cmd.Process.Pid
	r.mu.Lock()
	r.pgids[id] = pgid
	r.mu.Unlock()
	// The deadline: SIGALRM to the file's bash (status 142, read as a timeout).
	timer := time.AfterFunc(time.Duration(r.timeout)*time.Second, func() { cmd.Process.Signal(syscall.SIGALRM) })
	err = cmd.Wait()
	timer.Stop()
	if err != nil {
		if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			res.exitCode = 128 + int(ws.Signal())
		} else {
			res.exitCode = cmd.ProcessState.ExitCode()
		}
	}
	if res.exitCode == 142 {
		res.timedOut = true
		res.exitCode = 124
	}
	// Sweep the group so leaked readers cannot outlive the file.
	syscall.Kill(-pgid, syscall.SIGKILL)
	r.mu.Lock()
	delete(r.pgids, id)
	r.mu.Unlock()
	out.Close()
	res.elapsed = nowString(started)
	res.out, _ = os.ReadFile(outPath)
	return res
}

func readCounts(result string, exitCode int) (passed, failed, skipped, total int) {
	if data, err := os.ReadFile(result); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			key, value, _ := strings.Cut(line, "=")
			n, _ := strconv.Atoi(strings.TrimSpace(value))
			switch key {
			case "passed":
				passed = n
			case "failed":
				failed = n
			case "skipped":
				skipped = n
			case "total":
				total = n
			}
		}
	} else {
		total = 1
		if exitCode == 0 {
			passed = 1
		} else {
			failed = 1
		}
	}
	if exitCode != 0 && failed == 0 {
		failed = 1
		if total <= 0 {
			total = 1
		}
	}
	return
}

func (r *runner) tee(s string) {
	io.WriteString(r.stdout, s)
	r.logFile.WriteString(s)
}

// emit prints a finished file's output and adds its counts to the totals.
func (r *runner) emit(res fileResult) {
	path := relativePath(r.root, res.file)
	if res.timedOut {
		res.out = append(res.out, fmt.Sprintf("⏱️  TIMEOUT after %ds: killed %s (raise with --timeout or BASHX_TIMEOUT)\n", r.timeout, path)...)
	}
	if r.files != 0 {
		r.tee("\n")
	}
	r.tee(string(res.out))
	p, f, s, t := readCounts(res.result, res.exitCode)
	r.passed += p
	r.failed += f
	r.skipped += s
	r.total += t
	r.files++
	state := "passed"
	if s != 0 {
		state = "skipped"
	}
	if res.exitCode != 0 || f > 0 {
		r.failedFiles = append(r.failedFiles, res.id)
		state = "failed"
	}
	r.collectCases(res, path, state)
}

// collectCases appends the file's cases to cases.tsv, path first, plus a
// "(whole file)" case when the file recorded none or failed without one.
func (r *runner) collectCases(res fileResult, path, state string) {
	fileField := escapeField(path)
	data, err := os.ReadFile(res.cases)
	if err == nil {
		var b strings.Builder
		hasFailed := false
		for _, line := range strings.SplitAfter(string(data), "\n") {
			if line == "" {
				continue
			}
			line = strings.TrimSuffix(line, "\n")
			if strings.HasPrefix(line, "failed\t") {
				hasFailed = true
			}
			b.WriteString(fileField + "\t" + line + "\n")
		}
		r.casesOut.WriteString(b.String())
		if state != "failed" || hasFailed {
			return
		}
	} else if state == "passed" {
		if _, err := os.Stat(res.result); err == nil {
			return // bashx API, no case run (--filter)
		}
	}
	ms := 0
	if res.elapsed != "" {
		if f, err := strconv.ParseFloat(res.elapsed, 64); err == nil {
			ms = int(f * 1000)
		}
	}
	output := ""
	if state != "passed" {
		output = strings.TrimRight(stripANSI(string(res.out)), "\n")
	}
	fmt.Fprintf(r.casesOut, "%s\t%s\t%d\t(whole file)\t%s\n", fileField, state, ms, escapeField(output))
}

func (r *runner) sweep() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, pgid := range r.pgids {
		syscall.Kill(-pgid, syscall.SIGKILL)
	}
}

// runAll runs the files on `jobs` workers and emits each result as it lands.
func (r *runner) runAll(files []string, jobs int) []fileResult {
	results := make([]fileResult, len(files))
	done := make(chan fileResult)
	queue := make(chan int)
	st := newStatus(r)
	for w := 0; w < jobs; w++ {
		go func() {
			for id := range queue {
				st.started(id, relativePath(r.root, files[id]))
				done <- r.runOne(id, files[id])
			}
		}()
	}
	go func() {
		for i := range files {
			queue <- i
		}
		close(queue)
	}()
	st.start()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for remaining := len(files); remaining > 0; {
		select {
		case res := <-done:
			st.finished(res.id)
			st.clear()
			r.emit(res)
			results[res.id] = res
			remaining--
			st.render()
		case <-ticker.C:
			st.render()
		}
	}
	st.stop()
	return results
}

func runnerMain(lib string, args []string) int {
	kind, jobsStr := "", os.Getenv("BASHX_JOBS")
	timeoutStr := os.Getenv("BASHX_TIMEOUT")
	if timeoutStr == "" {
		timeoutStr = "60"
	}
	shard := "1/1"
	var durations, recordDurations, coverageDir, report, root string
	for _, arg := range args {
		key, value, _ := strings.Cut(arg, "=")
		switch {
		case key == "--kind":
			kind = value
		case key == "--jobs":
			jobsStr = value
		case key == "--timeout":
			timeoutStr = value
		case key == "--shard":
			shard = value
		case key == "--durations":
			durations = value
		case key == "--record-durations":
			recordDurations = value
		case key == "--coverage":
			coverageDir = value
		case key == "--report":
			report = value
		case key == "--filter":
			os.Setenv("BASHX_FILTER", value)
		case arg == "-v" || arg == "--verbose":
			os.Setenv("BASHX_VERBOSE", "1")
		case arg == "-h" || arg == "--help":
			fmt.Print(runnerUsage)
			return 0
		case strings.HasPrefix(arg, "-"):
			fmt.Fprintf(os.Stderr, "Unknown option: %s\n%s", arg, runnerUsage)
			return 2
		default:
			root = arg
		}
	}
	if root == "" {
		if out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output(); err == nil {
			root = strings.TrimSpace(string(out))
		} else {
			root, _ = os.Getwd()
		}
	}
	if st, err := os.Stat(root); err != nil || !st.IsDir() {
		fmt.Fprintf(os.Stderr, "Not a directory: %s\n", root)
		return 2
	}
	root = absDir(root)
	if jobsStr == "" {
		jobsStr = strconv.Itoa(runtime.NumCPU())
	}
	if !positiveRe.MatchString(jobsStr) {
		fmt.Fprintf(os.Stderr, "Invalid --jobs=%s\n", jobsStr)
		return 2
	}
	if !positiveRe.MatchString(timeoutStr) {
		fmt.Fprintf(os.Stderr, "Invalid --timeout=%s\n", timeoutStr)
		return 2
	}
	m := shardRe.FindStringSubmatch(shard)
	var shardIndex, shardCount int
	if m != nil {
		shardIndex, _ = strconv.Atoi(m[1])
		shardCount, _ = strconv.Atoi(m[2])
	}
	if m == nil || shardIndex < 1 || shardIndex > shardCount {
		fmt.Fprintf(os.Stderr, "Invalid --shard=%s (want I/N with 1 <= I <= N)\n", shard)
		return 2
	}
	jobs, _ := strconv.Atoi(jobsStr)
	timeout, _ := strconv.Atoi(timeoutStr)
	if durations == "" {
		durations = root + "/.bashx/durations.tsv"
	}

	all := discover(root, kind)
	if len(all) == 0 {
		k, dk := "", ""
		if kind != "" {
			k, dk = kind+" ", "."+kind
		}
		fmt.Fprintf(os.Stderr, "No %stest files (*%s.test.sh) under %s\n", k, dk, root)
		return 1
	}
	files := plan(root, durations, shardIndex, shardCount, all)

	tmp := os.Getenv("TMPDIR")
	if tmp == "" {
		tmp = "/tmp"
	}
	work, err := os.MkdirTemp(tmp, "bashx-run.")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	r := &runner{lib: lib, root: root, work: work, timeout: timeout, stdout: os.Stdout, pgids: map[int]int{}, expected: len(files)}
	defer os.RemoveAll(work)
	defer r.sweep()
	trapSignals(r)

	if coverageDir != "" {
		os.MkdirAll(filepath.Join(coverageDir, "traces"), 0o755)
		coverageDir = absDir(coverageDir)
		os.Setenv("BASHX_COVERAGE_TRACE_DIR", filepath.Join(coverageDir, "traces"))
		r.coverage = true
	}
	r.logFile, _ = os.Create(filepath.Join(work, "combined.log"))
	r.casesOut, _ = os.Create(filepath.Join(work, "cases.tsv"))
	started := time.Now()

	var results []fileResult
	if len(files) > 0 {
		results = r.runAll(files, jobs)
	}
	r.casesOut.Close()

	if recordDurations != "" {
		os.MkdirAll(filepath.Dir(recordDurations), 0o755)
		type row struct{ elapsed, rel string }
		var rows []row
		for _, res := range results {
			if res.elapsed != "" {
				rows = append(rows, row{res.elapsed, relativePath(root, res.file)})
			}
		}
		sort.SliceStable(rows, func(i, j int) bool { return rows[i].rel < rows[j].rel })
		var b strings.Builder
		for _, x := range rows {
			b.WriteString(x.elapsed + "\t" + x.rel + "\n")
		}
		os.WriteFile(recordDurations, []byte(b.String()), 0o644)
		fmt.Printf("⏱️  Durations written to %s\n", recordDurations)
	}

	if coverageDir != "" {
		os.Unsetenv("BASHX_COVERAGE_TRACE_DIR")
		traces := filepath.Join(coverageDir, "traces")
		f, _ := os.Create(filepath.Join(coverageDir, "covered.tsv"))
		w := bufio.NewWriter(f)
		coveredLines(root, traces, w)
		w.Flush()
		f.Close()
		os.RemoveAll(traces)
		summary, _ := coverageReport(lib, root, "summary", "", []string{filepath.Join(coverageDir, "covered.tsv")})
		fmt.Printf("🧭 Coverage: %s", summary)
	}

	line := fmt.Sprintf("📊 Test Summary: %d passed, %d failed", r.passed, r.failed)
	if r.skipped != 0 {
		line += fmt.Sprintf(", %d skipped", r.skipped)
	}
	line += fmt.Sprintf(", %d total (%dms)", r.total, time.Since(started).Milliseconds())
	r.tee("\n" + line + "\n")
	sort.Ints(r.failedFiles)
	var failedPaths []string
	for _, id := range r.failedFiles {
		failedPaths = append(failedPaths, relativePath(root, files[id]))
	}
	if len(failedPaths) > 0 {
		r.tee("\nFailed test files:\n")
		for _, p := range failedPaths {
			r.tee("  • " + p + "\n")
		}
	}
	r.logFile.Close()

	if report != "" {
		logData, _ := os.ReadFile(filepath.Join(work, "combined.log"))
		casesData, _ := os.ReadFile(filepath.Join(work, "cases.tsv"))
		sum := summary{r.passed, r.failed, r.skipped, r.total, r.files}
		if err := writeReport(report, string(logData), string(casesData), sum, failedPaths); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		fmt.Printf("\n📄 Report generated: test_report.%s\n", report)
	}
	if r.failed == 0 && len(failedPaths) == 0 {
		return 0
	}
	return 1
}

func absDir(dir string) string {
	if abs, err := filepath.Abs(dir); err == nil {
		return abs
	}
	return dir
}
