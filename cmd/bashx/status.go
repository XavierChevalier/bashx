package main

import (
	"fmt"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

// status is the ephemeral footer on stderr (as in Jest/Vitest): erased before
// every permanent line and redrawn after; off outside a TTY, in CI and with
// BASHX_PLAIN_OUTPUT.
type status struct {
	r                *runner
	active           bool
	height, frame    int
	head, run, reset string
	begin            time.Time
	mu               sync.Mutex
	inflight         []int
	paths            map[int]string
	starts           map[int]time.Time
}

var spinner = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

func newStatus(r *runner) *status {
	return &status{r: r, paths: map[int]string{}, starts: map[int]time.Time{}, begin: time.Now()}
}

func (s *status) start() {
	termName := os.Getenv("TERM")
	if !isTerminal(2) || termName == "" || termName == "dumb" || os.Getenv("CI") != "" || os.Getenv("BASHX_PLAIN_OUTPUT") != "" {
		return
	}
	s.active = true
	if os.Getenv("NO_COLOR") == "" {
		s.head, s.run, s.reset = "\033[36m", "\033[2m", "\033[0m"
	}
	fmt.Fprint(os.Stderr, "\033[?25l")
}

func (s *status) started(id int, path string) {
	s.mu.Lock()
	s.inflight = append(s.inflight, id)
	s.paths[id] = path
	s.starts[id] = time.Now()
	s.mu.Unlock()
}

func (s *status) finished(id int) {
	s.mu.Lock()
	for i, x := range s.inflight {
		if x == id {
			s.inflight = append(s.inflight[:i], s.inflight[i+1:]...)
			break
		}
	}
	delete(s.paths, id)
	delete(s.starts, id)
	s.mu.Unlock()
}

func (s *status) clear() {
	if !s.active {
		return
	}
	fmt.Fprint(os.Stderr, strings.Repeat("\033[1A\r\033[K", s.height))
	s.height = 0
}

func (s *status) stop() {
	if !s.active {
		return
	}
	s.clear()
	fmt.Fprint(os.Stderr, "\033[?25h")
	s.active = false
}

func (s *status) render() {
	if !s.active {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.inflight) == 0 {
		return
	}
	cols, rows := 80, 24
	if w, h, ok := terminalSize(2); ok {
		if w >= 20 {
			cols = w
		}
		if h >= 6 {
			rows = h
		}
	}
	r := s.r
	frame := spinner[s.frame%len(spinner)]
	s.frame++
	head := fmt.Sprintf("%s Test Files %d/%d  Tests %d passed", frame, r.files, r.expected, r.passed)
	if r.failed != 0 {
		head += fmt.Sprintf(", %d failed", r.failed)
	}
	head += fmt.Sprintf("  %ds", int(time.Since(s.begin).Seconds()))
	lines, colors := []string{"", head}, []string{"", s.head}
	budget := rows - 4
	if budget > 8 {
		budget = 8
	}
	if budget <= 0 {
		budget = 1
	}
	for shown, id := range s.inflight {
		if shown >= budget {
			lines = append(lines, fmt.Sprintf("   … +%d more", len(s.inflight)-shown))
			colors = append(colors, s.run)
			break
		}
		suffix := ""
		if secs := int(time.Since(s.starts[id]).Seconds()); secs >= 2 {
			suffix = fmt.Sprintf(" %ds", secs)
		}
		lines = append(lines, "   ❯ "+s.paths[id]+suffix)
		colors = append(colors, s.run)
	}
	var b strings.Builder
	b.WriteString("\033[?2026h")
	b.WriteString(strings.Repeat("\033[1A\r\033[K", s.height))
	for i, line := range lines {
		if utf8.RuneCountInString(line) > cols {
			line = string([]rune(line)[:cols-1]) + "…"
		}
		b.WriteString(colors[i] + line + s.reset + "\n")
	}
	b.WriteString("\033[?2026l")
	fmt.Fprint(os.Stderr, b.String())
	s.height = len(lines)
}

// trapSignals: on INT or TERM, kill every test file's group, clean up, exit 130.
func trapSignals(r *runner) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-ch
		fmt.Fprint(os.Stderr, "\033[?25h")
		r.sweep()
		os.RemoveAll(r.work)
		os.Exit(130)
	}()
}
