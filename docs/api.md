# API reference

Everything a test file gets from `source "${BASHX_LIB:-$(bashx lib)}/bashx.sh"`.
Sourcing it turns on `set -euo pipefail` and sets an EXIT trap
([why](writing-tests.md#the-exit-trap)).

## Lifecycle

| Function | Does |
| --- | --- |
| `test::init` | Starts the file: resets the counters, prints `🧪 ./path/of/file.test.sh`. |
| `test::run "<description>" <function> [args...]` | Runs one case in a subshell with errexit on and its own tmp dir. Prints `✓`, `✗` or `○` (skipped) with the duration. Always returns 0: the file goes on. |
| `test::skip ["<reason>"]` | Inside a case: ends it as skipped. |
| `test::summary` | Prints the tally. Returns 1 when a case failed, so it is the file's exit status as its last command. |

## Assertions

Each returns 0 when it holds; otherwise it prints what it expected and
returns 1, which ends the case (errexit). `[message]` is printed with the
failure.

| Assertion | Holds when |
| --- | --- |
| `test::assert_equals <expected> <actual> [message]` | the strings are equal |
| `test::assert_not_equals <unexpected> <actual> [message]` | the strings differ |
| `test::assert_contains <haystack> <needle> [message]` | `needle` is a substring of `haystack` |
| `test::assert_not_contains <haystack> <needle> [message]` | it is not |
| `test::assert_matches <string> <regex> [message]` | `string` matches the extended regex (`[[ =~ ]]`) |
| `test::assert_exit_code <code> <command> [args...]` | running the command (output discarded) exits with `code` |
| `test::assert_file_exists <file> [message]` | `file` is a regular file |
| `test::assert_file_not_exists <path> [message]` | nothing exists at `path` |
| `test::assert_file_contains <file> <needle> [message]` | the file exists and contains `needle` |
| `test::assert_file_not_contains <file> <needle> [message]` | the file exists and does not contain it |
| `test::assert_file_equals <file> <expected> [message]` | the file's content equals `expected`, a string or the content of the file `expected` names |

## Fixtures

| Function | Prints |
| --- | --- |
| `test::tmp_dir` | A new empty directory. Inside a case it is removed with the case; outside, with the file. |
| `test::suite_tmp_dir` | The file's shared directory, removed when the file exits. Needs `test::init` first. |
| `test::mock_command <name> <script> [<bin dir>]` | The directory of a new executable `<name>` running `<script>`. Prepend it to `PATH` in the case. Pass a bin dir to put several mocks together. |

## Environment

| Variable | Read by | Effect |
| --- | --- | --- |
| `BASHX_LIB` | test files | Directory of `bashx.sh`. Set by `bashx test` and `bashx mutate`. |
| `NO_COLOR` | `bashx.sh`, runner | Any value turns colours off. |
| `BASHX_RESULT_FILE` | `bashx.sh` | Where `test::summary` writes the counts. Set by the runner, not by you. |

The runner's own variables (`BASHX_JOBS`, `BASHX_TIMEOUT`,
`BASHX_PLAIN_OUTPUT`) are in [Running tests](running-tests.md).
