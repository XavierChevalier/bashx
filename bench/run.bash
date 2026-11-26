#!/usr/bin/env bash
# Benchmark of the bash runner (bin/bashx) against the Go port (go/bashx-go).
# Both run the same test files, through the same API (lib/bashx.sh).
#
#   go -C go build -o bashx-go . && bench/run.bash [runs]   (default 5 runs)
#
# Prints a Markdown table: median wall time, and median CPU (user + sys, the
# runner and every process it waited for) of each scenario.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS="${1:-5}"
BASH_X="${ROOT}/bin/bashx"
GO_X="${ROOT}/go/bashx-go"
JOBS="${BENCH_JOBS:-4}"
[[ -x "${GO_X}" ]] || { echo "build it first: go -C go build -o bashx-go ." >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bashx-bench.XXXXXX")"
trap 'rm -rf -- "${WORK}"' EXIT
export CI=1 BASHX_PLAIN_OUTPUT=1

# <dir> <files> <body>: <files> test files running <body>.
make_files() {
  local -r dir="$1" n="$2" body="$3"
  local i
  mkdir -p "${dir}"
  for ((i = 0; i < n; i++)); do printf '#!/usr/bin/env bash\n%s\n' "${body}" >"${dir}/f${i}.test.sh"; done
}

# <dir> <files> <cases>: files using the API, <cases> passing cases each.
make_api_files() {
  local -r dir="$1" n="$2" cases="$3"
  local body='source "${BASHX_LIB}/bashx.sh"' j
  for ((j = 0; j < cases; j++)); do body+=$'\n'"test_case_${j}() { assert \"\$((${j} + 1))\" == $((j + 1)); }"; done
  make_files "${dir}" "${n}" "${body}"$'\n''test::main'
}

# Traces of the repository's own suite, for the coverage post-processing.
make_traces() {
  local -r dir="$1"
  local file
  mkdir -p "${dir}"
  while IFS= read -r file; do
    (cd "$(dirname "${file}")" && BASHX_LIB="${ROOT}/lib" BASH_ENV="${ROOT}/lib/coverage-trace.bash" \
      BASHX_COVERAGE_TRACE_DIR="${dir}" bash "${file}" >/dev/null 2>&1 </dev/null) || true
  done < <(find "${ROOT}/lib" "${ROOT}/bin" "${ROOT}/examples" -name '*.test.sh')
}

# Median of the numbers on stdin.
median() { sort -n | awk '{ v[NR] = $1 } END { print (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }'; }

# <label> <command>...: runs it RUNS times (after a warm-up) from WORK/cwd,
# prints "wall cpu" medians in ms.
measure() {
  local -r times="${WORK}/times"
  local i
  : >"${times}"
  (cd "${WORK}/cwd" && "$@" >/dev/null 2>&1) || true
  for ((i = 0; i < RUNS; i++)); do
    (
      cd "${WORK}/cwd"
      TIMEFORMAT='%3R %3U %3S'
      { time "$@" >/dev/null 2>&1; } 2>>"${times}" || true
    )
  done
  printf '%s %s\n' \
    "$(awk '{ print $1 * 1000 }' "${times}" | median)" \
    "$(awk '{ print ($2 + $3) * 1000 }' "${times}" | median)"
}

row() {
  local -r label="$1" bash_cmd="$2" go_cmd="$3"
  local b g
  # shellcheck disable=SC2086 # the commands are word lists on purpose
  read -r -a b <<<"$(measure ${bash_cmd})"
  # shellcheck disable=SC2086
  read -r -a g <<<"$(measure ${go_cmd})"
  printf '| %s | %d | %d | %d | %d | ×%.2f |\n' "${label}" "${b[0]}" "${g[0]}" "${b[1]}" "${g[1]}" \
    "$(awk -v a="${b[0]}" -v b="${g[0]}" 'BEGIN { print a / b }')" >&2
  printf '| %s | %d | %d | %d | %d | ×%.2f |\n' "${label}" "${b[0]}" "${g[0]}" "${b[1]}" "${g[1]}" \
    "$(awk -v a="${b[0]}" -v b="${g[0]}" 'BEGIN { print a / b }')" >>"${WORK}/table"
}

main() {
  mkdir -p "${WORK}/cwd"
  make_files "${WORK}/empty" 200 'exit 0'
  make_api_files "${WORK}/api" 50 20
  make_files "${WORK}/sleepy" 40 'sleep 0.05'
  make_traces "${WORK}/traces"
  BASHX_LIB="${ROOT}/lib" "${BASH_X}" coverage covered -r "${ROOT}" "${WORK}/traces" >"${WORK}/covered.tsv"

  local -r j="--jobs=${JOBS}"
  : >"${WORK}/table"
  echo "bash $(bash --version | head -1 | awk '{ print $4 }'), $(go version | awk '{ print $3 }'), ${JOBS} jobs, $(nproc) CPUs, median of ${RUNS} runs" >&2
  row "startup: \`test --help\`" "${BASH_X} test --help" "${GO_X} test --help"
  row "200 files \`exit 0\` (no API)" "${BASH_X} test ${j} ${WORK}/empty" "${GO_X} test ${j} ${WORK}/empty"
  row "40 files \`sleep 0.05\`" "${BASH_X} test ${j} ${WORK}/sleepy" "${GO_X} test ${j} ${WORK}/sleepy"
  row "50 files × 20 cases (API)" "${BASH_X} test ${j} ${WORK}/api" "${GO_X} test ${j} ${WORK}/api"
  row "same + \`--report=json\`" "${BASH_X} test ${j} --report=json ${WORK}/api" "${GO_X} test ${j} --report=json ${WORK}/api"
  row "same + \`--report=junit\`" "${BASH_X} test ${j} --report=junit ${WORK}/api" "${GO_X} test ${j} --report=junit ${WORK}/api"
  row "coverage covered ($(find "${WORK}/traces" -name '*.trace' | wc -l | tr -d ' ') traces, $(du -sh "${WORK}/traces" | cut -f1))" \
    "${BASH_X} coverage covered -r ${ROOT} ${WORK}/traces" "${GO_X} coverage covered -r ${ROOT} ${WORK}/traces"
  row "coverage report" "${BASH_X} coverage report -r ${ROOT} ${WORK}/covered.tsv" "${GO_X} coverage report -r ${ROOT} ${WORK}/covered.tsv"
  row "bashx's own suite" "${BASH_X} test ${j} ${ROOT}" "${GO_X} test ${j} ${ROOT}"
  row "bashx's own suite \`--coverage\`" "${BASH_X} test ${j} --coverage=${WORK}/cov ${ROOT}" "${GO_X} test ${j} --coverage=${WORK}/cov ${ROOT}"

  echo
  echo "| Scenario | bash wall (ms) | Go wall (ms) | bash CPU (ms) | Go CPU (ms) | Wall speed-up |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: |"
  cat "${WORK}/table"
}

main
