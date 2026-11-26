package main

import (
	"fmt"
	"os"
	"strings"
)

type summary struct{ passed, failed, skipped, total, files int }

type caseRow struct{ file, status, ms, name, output string }

// parseCases reads cases.tsv as the reporters' `read -r file status ms name
// output` does (fields unescaped later).
func parseCases(data string) []caseRow {
	var rows []caseRow
	for _, line := range strings.Split(data, "\n") {
		if line == "" {
			continue
		}
		f := strings.SplitN(line, "\t", 5)
		for len(f) < 5 {
			f = append(f, "")
		}
		rows = append(rows, caseRow{f[0], f[1], f[2], f[3], f[4]})
	}
	return rows
}

func writeReport(format, log, cases string, s summary, failedFiles []string) error {
	var content string
	switch format {
	case "markdown":
		content = markdownReport(log, cases, s, failedFiles)
	case "json":
		content = jsonReport(log, cases, s, failedFiles)
	case "junit":
		content = junitReport(cases, s)
	default:
		return fmt.Errorf("Unknown report format: %s (markdown, json, junit)", format)
	}
	return os.WriteFile("test_report."+format, []byte(content), 0o644)
}

func markdownReport(log, cases string, s summary, failedFiles []string) string {
	var b strings.Builder
	b.WriteString("# Test Report\n\n| Passed | Failed | Skipped | Total | Files |\n| ---: | ---: | ---: | ---: | ---: |\n")
	fmt.Fprintf(&b, "| %d | %d | %d | %d | %d |\n", s.passed, s.failed, s.skipped, s.total, s.files)
	if len(failedFiles) > 0 {
		b.WriteString("\n## Failed test files\n\n")
		for _, f := range failedFiles {
			fmt.Fprintf(&b, "- `%s`\n", f)
		}
		b.WriteString("\n## Failed cases\n\n")
		for _, c := range parseCases(cases) {
			if c.status == "failed" {
				fmt.Fprintf(&b, "- `%s`: %s\n", unescapeField(c.file), unescapeField(c.name))
			}
		}
	}
	b.WriteString("\n## Output\n\n```\n")
	b.WriteString(stripANSI(log))
	b.WriteString("```\n")
	return b.String()
}

var jsonEscaper = strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "\t", "\\t", "\r", "\\r", "\n", "\\n", "\033", "\\u001b")

func jsonString(s string) string { return "\"" + jsonEscaper.Replace(s) + "\"" }

func jsonReport(log, cases string, s summary, failedFiles []string) string {
	var failed []string
	for _, f := range failedFiles {
		failed = append(failed, jsonString(f))
	}
	var cb strings.Builder
	sep := ""
	for _, c := range parseCases(cases) {
		ms := 0
		fmt.Sscanf(c.ms, "%d", &ms)
		fmt.Fprintf(&cb, "%s\n    {\"file\": %s, \"name\": %s, \"status\": \"%s\", \"duration_ms\": %d, \"output\": %s}", sep,
			jsonString(unescapeField(c.file)), jsonString(unescapeField(c.name)), c.status, ms, jsonString(unescapeField(c.output)))
		sep = ","
	}
	if sep != "" {
		cb.WriteString("\n  ")
	}
	return fmt.Sprintf("{\n  \"summary\": {\"passed\": %d, \"failed\": %d, \"skipped\": %d, \"total\": %d, \"files\": %d},\n  \"failed_files\": [%s],\n  \"cases\": [%s],\n  \"output\": %s\n}\n",
		s.passed, s.failed, s.skipped, s.total, s.files, strings.Join(failed, ", "), cb.String(), jsonString(strings.TrimRight(log, "\n")))
}

var xmlEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;")

// xmlEscape drops the control characters XML 1.0 refuses, then escapes.
func xmlEscape(s string) string {
	s = strings.Map(func(r rune) rune {
		if r < 0x20 && r != '\t' && r != '\n' && r != '\r' {
			return -1
		}
		return r
	}, s)
	return xmlEscaper.Replace(strings.TrimRight(s, "\n"))
}

func junitReport(cases string, s summary) string {
	var b strings.Builder
	b.WriteString("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
	fmt.Fprintf(&b, "<testsuites name=\"bashx\" tests=\"%d\" failures=\"%d\" skipped=\"%d\" errors=\"0\">\n", s.total, s.failed, s.skipped)
	fmt.Fprintf(&b, "  <testsuite name=\"bashx\" tests=\"%d\" failures=\"%d\" skipped=\"%d\" errors=\"0\">\n", s.total, s.failed, s.skipped)
	for _, c := range parseCases(cases) {
		ms := 0
		fmt.Sscanf(c.ms, "%d", &ms)
		attrs := fmt.Sprintf("classname=\"%s\" name=\"%s\" time=\"%.3f\"", xmlEscape(unescapeField(c.file)), xmlEscape(unescapeField(c.name)), float64(ms)/1000)
		output := xmlEscape(unescapeField(c.output))
		switch c.status {
		case "failed":
			fmt.Fprintf(&b, "    <testcase %s>\n      <failure message=\"test failed\">%s</failure>\n    </testcase>\n", attrs, output)
		case "skipped":
			fmt.Fprintf(&b, "    <testcase %s>\n      <skipped>%s</skipped>\n    </testcase>\n", attrs, output)
		default:
			fmt.Fprintf(&b, "    <testcase %s/>\n", attrs)
		}
	}
	b.WriteString("  </testsuite>\n</testsuites>\n")
	return b.String()
}
