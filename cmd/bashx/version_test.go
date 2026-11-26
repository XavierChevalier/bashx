package main

import (
	"os"
	"regexp"
	"testing"
)

// release-please bumps them together; a hand edit of one would ship a wrong
// `bashx version` or a changelog out of step with the tag.
func TestAgreesOnTheVersionEverywhere(t *testing.T) {
	read := func(path, pattern string) string {
		t.Helper()
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		m := regexp.MustCompile(pattern).FindSubmatch(data)
		if m == nil {
			t.Fatalf("no version in %s", path)
		}
		return string(m[1])
	}
	manifest := read("../../.release-please-manifest.json", `"\."\s*:\s*"([^"]+)"`)
	for path, got := range map[string]string{
		"version.go":   version,
		"version.txt":  read("../../version.txt", `^(\S+)`),
		"CHANGELOG.md": read("../../CHANGELOG.md", `(?m)^## \[([0-9][^\]]*)\]`),
	} {
		if got != manifest {
			t.Errorf("%s says %s, .release-please-manifest.json %s", path, got, manifest)
		}
	}
}
