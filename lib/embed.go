// Package lib holds the bash side of bashx, embedded in the binary: the test
// API that test files source, and the tracer `bashx test --coverage` loads
// into every bash process.
package lib

import "embed"

// Files: bashx.sh and coverage-trace.bash.
//
//go:embed bashx.sh coverage-trace.bash
var Files embed.FS
