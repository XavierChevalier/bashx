#!/usr/bin/env bash
# Runs the Go runner as `bash runner.sh` would be run: lets lib/runner.test.sh
# check it (BASHX_TEST_RUNNER=go/runner-shim.bash bash lib/runner.test.sh).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bashx-go" test "$@"
