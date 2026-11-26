package main

import (
	"bufio"
	"bytes"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const coverageUsage = `Usage: bashx coverage report [-r <root>] [-x <regex>] [-f summary|markdown|tsv|uncovered] <covered.tsv>...
       bashx coverage covered [-r <root>] <trace dir>

  report   score the union of covered.tsv files (from bashx test --coverage)
           against the project's scripts
           summary:   covered=<n> coverable=<n> pct=<n.n>  (default)
           markdown:  one line for a PR comment
           tsv:       path, covered, coverable per script
           uncovered: "<path>:<line>: <code>" for every line no test ran
  covered  print "<path>\t<line>" for every project line the traces ran
  -r       project root (default: git root of the current directory, or it)
  -x       also leave out scripts whose path matches this extended regex
           (tests and fixtures/ are always left out)
`

func coverageMain(lib string, args []string) int {
	if len(args) == 0 {
		fmt.Print(coverageUsage)
		return 1
	}
	cmd := args[0]
	if cmd == "-h" || cmd == "--help" {
		fmt.Print(coverageUsage)
		return 0
	}
	fs := flag.NewFlagSet("coverage", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	root := fs.String("r", "", "")
	exclude := fs.String("x", "", "")
	format := fs.String("f", "summary", "")
	help := fs.Bool("h", false, "")
	if err := fs.Parse(args[1:]); err != nil {
		fmt.Print(coverageUsage)
		return 1
	}
	if *help {
		fmt.Print(coverageUsage)
		return 0
	}
	rest := fs.Args()
	if *root == "" {
		if out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output(); err == nil {
			*root = strings.TrimSpace(string(out))
		} else {
			*root, _ = os.Getwd()
		}
	}
	*root = absDir(*root)
	switch cmd {
	case "covered":
		if len(rest) != 1 {
			fmt.Print(coverageUsage)
			return 1
		}
		if st, err := os.Stat(rest[0]); err != nil || !st.IsDir() {
			fmt.Fprintf(os.Stderr, "no trace dir %s\n", rest[0])
			return 1
		}
		w := bufio.NewWriter(os.Stdout)
		coveredLines(*root, rest[0], w)
		w.Flush()
	case "report":
		if len(rest) < 1 {
			fmt.Print(coverageUsage)
			return 1
		}
		switch *format {
		case "summary", "markdown", "tsv", "uncovered":
		default:
			fmt.Fprintf(os.Stderr, "unknown format %s\n", *format)
			return 1
		}
		out, err := coverageReport(lib, *root, *format, *exclude, rest)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		fmt.Print(out)
	default:
		fmt.Print(coverageUsage)
		return 1
	}
	return 0
}

// normalise is /a/./b/../c -> /a/c, without following links.
func normalise(path string) string {
	parts := strings.Split(path, "/")
	kept := parts[:0]
	for _, p := range parts {
		switch p {
		case "", ".":
		case "..":
			if len(kept) > 0 {
				kept = kept[:len(kept)-1]
			}
		default:
			kept = append(kept, p)
		}
	}
	return "/" + strings.Join(kept, "/")
}

var traceRe = regexp.MustCompile(`^\++([^:]+):([0-9]+): `)

// coveredLines prints "<path>\t<line>" for every line under root the traces
// ran, each once.
func coveredLines(root, traces string, w io.Writer) {
	rootPrefix := normalise(root)
	if rootPrefix != "/" {
		rootPrefix += "/"
	}
	var files []string
	filepath.WalkDir(traces, func(path string, d os.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() && strings.HasSuffix(d.Name(), ".trace") {
			files = append(files, path)
		}
		return nil
	})
	sort.Strings(files)
	seen := map[string]bool{}
	type key struct{ cwd, path string }
	resolved := map[key]string{} // "" when outside the root
	buf := make([]byte, 0, 64*1024)
	for _, file := range files {
		f, err := os.Open(file)
		if err != nil {
			continue
		}
		rd := bufio.NewReaderSize(f, 256*1024)
		cwd := ""
		first := true
		for {
			// Only a line's start matters: read it, skip the rest of long ones.
			chunk, err := rd.ReadSlice('\n')
			line := chunk
			if err == bufio.ErrBufferFull {
				buf = append(buf[:0], chunk...)
				line = buf
				for err == bufio.ErrBufferFull {
					_, err = rd.ReadSlice('\n')
				}
			}
			if len(line) == 0 && err != nil {
				break
			}
			if first {
				first = false
				if bytes.HasPrefix(line, []byte("#cwd ")) {
					cwd = string(bytes.TrimRight(line[5:], "\n"))
					continue
				}
			}
			if len(line) > 0 && line[0] == '+' {
				if m := traceRe.FindSubmatch(line); m != nil {
					path := strings.TrimLeft(string(m[1]), "+")
					k := key{cwd, path}
					rel, ok := resolved[k]
					if !ok {
						abs := path
						if !strings.HasPrefix(abs, "/") {
							base := cwd
							if base == "" {
								base = root
							}
							abs = base + "/" + abs
						}
						abs = normalise(abs)
						if strings.HasPrefix(abs, rootPrefix) {
							rel = abs[len(rootPrefix):]
						}
						resolved[k] = rel
					}
					if rel != "" {
						entry := rel + "\t" + string(m[2])
						if !seen[entry] {
							seen[entry] = true
							io.WriteString(w, entry+"\n")
						}
					}
				}
			}
			if err != nil {
				break
			}
		}
		f.Close()
	}
}

// coverageScripts lists the scripts the score is about.
func coverageScripts(lib, root, exclude string) ([]string, error) {
	var list []string
	if out, err := exec.Command("git", "-C", root, "ls-files", "-co", "--exclude-standard", "--", "*.sh").Output(); err == nil {
		list = splitLines(string(out))
	} else {
		filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() && d.Name() == ".git" {
				return filepath.SkipDir
			}
			if !d.IsDir() && strings.HasSuffix(d.Name(), ".sh") {
				list = append(list, relativePath(root, path))
			}
			return nil
		})
	}
	own := ""
	if bashxRoot := absDir(filepath.Join(lib, "..")); bashxRoot != root && strings.HasPrefix(bashxRoot, root+"/") {
		own = strings.TrimPrefix(bashxRoot, root+"/") + "/"
	}
	var ex *regexp.Regexp
	if exclude != "" {
		var err error
		if ex, err = regexp.Compile(exclude); err != nil {
			return nil, err
		}
	}
	testsRe := regexp.MustCompile(`\.test\.sh$|(^|/)fixtures/`)
	var scripts []string
	for _, s := range list {
		if testsRe.MatchString(s) || (own != "" && strings.HasPrefix(s, own)) || (ex != nil && ex.MatchString(s)) {
			continue
		}
		scripts = append(scripts, s)
	}
	return scripts, nil
}

func splitLines(s string) []string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

// lineInfo is coverage::lines for one line: the line its statement starts on,
// and whether it counts.
type lineInfo struct {
	start     int
	coverable bool
}

var (
	heredocRe    = regexp.MustCompile(`<<-?[ \t]*["']?[A-Za-z_][A-Za-z0-9_]*`)
	heredocHead  = regexp.MustCompile(`^<<-?[ \t]*["']?`)
	structuralRe = regexp.MustCompile(`^(then|else|fi|do|done|esac|in|\{|\}|\(|\)|;;|;&|;;&)( *[;|&<>].*)?$`)
	functionRe   = regexp.MustCompile(`^(function[ \t]+[^ \t(]+|[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\))[ \t]*(\(\))?[ \t]*[{(]?$`)
	closingRe    = regexp.MustCompile(`^[^()]*\)$`)
)

// scriptLines splits a script into statements (continuations, multi-line
// quotes and arrays, heredocs count once, on their first line).
func scriptLines(text string) []lineInfo {
	lines := strings.Split(text, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	info := make([]lineInfo, len(lines))
	var heredoc string
	var quote byte
	cont, array := false, false
	start := 0
	for i, line := range lines {
		nr := i + 1
		inside := heredoc != "" || quote != 0 || cont || array
		if !inside {
			start = nr
		}
		if heredoc != "" {
			if strings.TrimLeft(line, " \t") == heredoc {
				heredoc = ""
			}
			info[i] = lineInfo{start, false}
			continue
		}
		code := scanCode(line, &quote)
		t := strings.Trim(code, " \t")
		if array && strings.HasPrefix(t, ")") {
			array = false
		} else if !inside && quote == 0 && strings.HasSuffix(t, "=(") {
			array = true
		}
		cont = quote == 0 && strings.HasSuffix(t, "\\")
		if quote == 0 && !strings.Contains(code, "<<<") {
			if m := heredocRe.FindString(code); m != "" {
				heredoc = heredocHead.ReplaceAllString(m, "")
			}
		}
		info[i] = lineInfo{start, !inside && coverable(t, nr)}
	}
	return info
}

// scanCode is the code part of a line (comment dropped), updating the open quote.
func scanCode(line string, quote *byte) string {
	var out strings.Builder
	n := len(line)
	for i := 0; i < n; i++ {
		c := line[i]
		if *quote == '\'' {
			if c == '\'' {
				*quote = 0
			}
			out.WriteByte(c)
			continue
		}
		if *quote == '"' {
			if c == '\\' {
				out.WriteString(line[i:min(i+2, n)])
				i++
				continue
			}
			if c == '"' {
				*quote = 0
			}
			out.WriteByte(c)
			continue
		}
		if c == '\\' {
			out.WriteString(line[i:min(i+2, n)])
			i++
			continue
		}
		if c == '#' && (i == 0 || line[i-1] == ' ' || line[i-1] == '\t' || line[i-1] == ';') {
			break
		}
		if c == '\'' || c == '"' {
			*quote = c
		}
		out.WriteByte(c)
	}
	return out.String()
}

func coverable(t string, nr int) bool {
	if t == "" || (nr == 1 && strings.HasPrefix(t, "#!")) {
		return false
	}
	return !structuralRe.MatchString(t) && !functionRe.MatchString(t) && !closingRe.MatchString(t)
}

// coverageReport scores the union of covered.tsv files against the scripts.
func coverageReport(lib, root, format, exclude string, coveredFiles []string) (string, error) {
	scripts, err := coverageScripts(lib, root, exclude)
	if err != nil {
		return "", err
	}
	ran := map[string]map[int]bool{}
	for _, cf := range coveredFiles {
		data, err := os.ReadFile(cf)
		if err != nil {
			return "", err
		}
		for _, line := range strings.Split(string(data), "\n") {
			path, rest, ok := strings.Cut(line, "\t")
			if !ok {
				continue
			}
			num, _, _ := strings.Cut(rest, "\t")
			n, err := strconv.Atoi(num)
			if err != nil {
				continue
			}
			if ran[path] == nil {
				ran[path] = map[int]bool{}
			}
			ran[path][n] = true
		}
	}
	type scriptScore struct {
		path               string
		covered, coverable int
		missing            []int
		text               []string
	}
	var scores []scriptScore
	done, total := 0, 0
	for _, s := range scripts {
		data, err := os.ReadFile(filepath.Join(root, s))
		if err != nil {
			continue
		}
		info := scriptLines(string(data))
		hit := map[int]bool{}
		for i, li := range info {
			if ran[s][i+1] {
				hit[li.start] = true
			}
		}
		sc := scriptScore{path: s}
		for i, li := range info {
			if !li.coverable {
				continue
			}
			sc.coverable++
			if hit[i+1] {
				sc.covered++
			} else {
				sc.missing = append(sc.missing, i+1)
			}
		}
		if sc.coverable == 0 {
			continue
		}
		if format == "uncovered" {
			sc.text = strings.Split(string(data), "\n")
		}
		done += sc.covered
		total += sc.coverable
		scores = append(scores, sc)
	}
	pct := 0.0
	if total > 0 {
		pct = 100 * float64(done) / float64(total)
	}
	var b strings.Builder
	switch format {
	case "uncovered":
		sort.Slice(scores, func(i, j int) bool { return scores[i].path < scores[j].path })
		for _, sc := range scores {
			for _, n := range sc.missing {
				fmt.Fprintf(&b, "%s:%d: %s\n", sc.path, n, strings.TrimLeft(sc.text[n-1], " \t"))
			}
		}
	case "tsv":
		sort.Slice(scores, func(i, j int) bool { return scores[i].path < scores[j].path })
		b.WriteString("path\tcovered\tcoverable\n")
		for _, sc := range scores {
			fmt.Fprintf(&b, "%s\t%d\t%d\n", sc.path, sc.covered, sc.coverable)
		}
	case "markdown":
		fmt.Fprintf(&b, "**Coverage:** %.1f%% of bash lines (%d/%d)\n", pct, done, total)
	default:
		fmt.Fprintf(&b, "covered=%d coverable=%d pct=%.1f\n", done, total, pct)
	}
	return b.String(), nil
}
