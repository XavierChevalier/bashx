package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/XavierChevalier/bashx/lib"
)

// libDir is the directory test files source bashx.sh from: $BASHX_LIB when
// set (a checkout of bashx, a vendored copy), else the files embedded in the
// binary, written once to the user's cache dir under a name that changes with
// their content.
func libDir() (string, error) {
	if d := os.Getenv("BASHX_LIB"); d != "" {
		return filepath.Abs(d)
	}
	names, err := fs.Glob(lib.Files, "*")
	if err != nil {
		return "", err
	}
	sum := sha256.New()
	contents := map[string][]byte{}
	for _, name := range names {
		data, err := lib.Files.ReadFile(name)
		if err != nil {
			return "", err
		}
		contents[name] = data
		fmt.Fprintf(sum, "%s\x00%d\x00", name, len(data))
		sum.Write(data)
	}
	base, err := os.UserCacheDir()
	if err != nil {
		base = os.TempDir()
	}
	parent := filepath.Join(base, "bashx")
	dir := filepath.Join(parent, fmt.Sprintf("lib-%s-%s", version, hex.EncodeToString(sum.Sum(nil))[:12]))
	if _, err := os.Stat(filepath.Join(dir, "bashx.sh")); err == nil {
		return dir, nil
	}
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return "", err
	}
	// Written aside, then renamed: parallel runs may extract at the same time.
	tmp, err := os.MkdirTemp(parent, ".lib-")
	if err != nil {
		return "", err
	}
	for name, data := range contents {
		if err := os.WriteFile(filepath.Join(tmp, name), data, 0o644); err != nil {
			os.RemoveAll(tmp)
			return "", err
		}
	}
	os.Chmod(tmp, 0o755)
	if err := os.Rename(tmp, dir); err != nil {
		os.RemoveAll(tmp)
		if _, statErr := os.Stat(filepath.Join(dir, "bashx.sh")); statErr != nil {
			return "", err
		}
	}
	return dir, nil
}
