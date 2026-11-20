#!/usr/bin/env bash
# bashx test runner: finds the test files under a root and runs them in
# parallel, each in its own process group with a deadline, then prints a
# summary. Called by `bashx test`; see docs/running-tests.md.
#
# Test files: *.test.sh, or *.<kind>.test.sh to filter them with --kind.
# A file whose header has `# @requires <command>...` is skipped unless every
# command is on PATH.
# Shards (--shard=I/N) are balanced on a durations file (--durations, default
# <root>/.bashx/durations.tsv, written by --record-durations).
set -euo pipefail

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

runner::usage() {
  cat <<'USAGE'
Usage: bashx test [options] [<root>]

Runs every *.test.sh under <root> (default: the git root, or the current dir).

  --kind=KIND             only *.KIND.test.sh (e.g. unit, integration)
  --jobs=N                files run in parallel (default: CPU count, BASHX_JOBS)
  --timeout=SECONDS       deadline per file (default: 60, BASHX_TIMEOUT)
  --shard=I/N             run part I of N (CI matrix), balanced on durations
  --durations=FILE        durations for --shard (default: <root>/.bashx/durations.tsv)
  --record-durations=FILE write each file's wall time to FILE
  --coverage=DIR          trace the run, write DIR/covered.tsv, print the score
  --report=FORMAT         also write test_report.FORMAT (markdown, json, junit)
  -h, --help              this help
USAGE
}

runner::cpu_count() {
  getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4
}

# Test files under <root>, sorted. Skips .git, node_modules, virtualenvs and
# other dependency dirs, and nested git repositories (submodules, vendored
# clones such as bashx itself): their tests are theirs to run.
# Usage: runner::discover <root> [<kind>]
runner::discover() {
  local -r root="$1" kind="${2:-}"
  local pattern='*.test.sh'
  [[ -z "${kind}" ]] || pattern="*.${kind}.test.sh"
  find "${root}" \
    \( -name .git -o -name node_modules -o -name .venv -o -name venv -o -name .cache -o -name .bashx \) -prune -o \
    -type f -name "${pattern}" -print \
    | awk -v nested="$(find "${root}" -mindepth 2 -name .git 2>/dev/null | sed 's|\.git$||')" '
      BEGIN { n = split(nested, dirs, "\n") }
      { for (i = 1; i <= n; i++) if (dirs[i] != "" && index($0, dirs[i]) == 1) next; print }' \
    | LC_ALL=C sort
}

# Relative path of <file> under <root> (unchanged when outside it).
runner::relative_path() {
  local -r root="$1" file="$2"
  local rel="${file#"${root}/"}"
  printf '%s' "${rel}"
}

# Files of shard <index>/<count>, longest first. Longest processing time
# first: each file, by decreasing duration (ties by path), goes to the least
# loaded shard (lowest index on ties). Files missing from <durations> weigh 1 s.
# Usage: runner::plan <root> <durations.tsv> <index> <count> <file>...
runner::plan() {
  local -r root="$1" durations="$2" index="$3" count="$4"
  shift 4
  local -A weight=()
  local secs rel file
  if [[ -f "${durations}" ]]; then
    while IFS=$'\t' read -r secs rel; do
      [[ "${secs}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && weight["${rel}"]="${secs}"
    done <"${durations}"
  fi
  for file in "$@"; do
    rel="$(runner::relative_path "${root}" "${file}")"
    printf '%s\t%s\t%s\n' "${weight[${rel}]:-1}" "${rel}" "${file}"
  done \
    | LC_ALL=C sort -t $'\t' -k1,1gr -k2,2 \
    | awk -F'\t' -v n="${count}" -v k="${index}" '
      {
        best = 1
        for (i = 2; i <= n; i++) if (load[i] + 0 < load[best] + 0) best = i
        load[best] += $1
        if (best == k) print $3
      }'
}

# Commands listed by `# @requires` in the file header (comments before the
# first command), one per line.
# Usage: runner::requirements <file>
runner::requirements() {
  awk '
    /^#!/ { next }
    /^[[:space:]]*$/ { next }
    /^#/ {
      if (sub(/^#[[:space:]]*@requires[[:space:]]+/, "")) { n = split($0, cmds, /[[:space:]]+/); for (i = 1; i <= n; i++) if (cmds[i] != "") print cmds[i] }
      next
    }
    { exit }
  ' "$1"
}

# ── Status block ─────────────────────────────────────────────────────────────
# An ephemeral footer on stderr (as in Jest/Vitest): erased before every
# permanent line and redrawn after; off outside a TTY, in CI and with
# BASHX_PLAIN_OUTPUT.

STATUS_SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
STATUS_MAX_RUNNING_LINES=8
STATUS_POLL_INTERVAL=0.1
_STATUS_ACTIVE=0
_STATUS_HEIGHT=0
_STATUS_FRAME=0
_STATUS_COLS=80
_STATUS_ROWS=24
_STATUS_HEAD_COLOR=""
_STATUS_RUN_COLOR=""
_STATUS_RESET=""
_STATUS_INFLIGHT=()
declare -A _STATUS_PID=()
declare -A _STATUS_PATH=()
declare -A _STATUS_START=()

runner::status_measure() {
  local size rows cols
  size="$(stty size </dev/tty 2>/dev/null || true)"
  rows="${size% *}"
  cols="${size##* }"
  [[ "${cols}" =~ ^[0-9]+$ ]] || cols="$(tput cols 2>/dev/null || echo 80)"
  [[ "${rows}" =~ ^[0-9]+$ ]] || rows="$(tput lines 2>/dev/null || echo 24)"
  ((cols >= 20)) || cols=80
  ((rows >= 6)) || rows=24
  _STATUS_COLS="${cols}"
  _STATUS_ROWS="${rows}"
}

runner::status_start() {
  [[ -t 2 && "${TERM:-dumb}" != "dumb" && -z "${CI:-}" && -z "${BASHX_PLAIN_OUTPUT:-}" ]] || return 0
  _STATUS_ACTIVE=1
  if [[ -z "${NO_COLOR:-}" ]]; then
    _STATUS_HEAD_COLOR=$'\033[36m' _STATUS_RUN_COLOR=$'\033[2m' _STATUS_RESET=$'\033[0m'
  fi
  runner::status_measure
  trap 'runner::status_measure' WINCH
  printf '\033[?25l' >&2
}

runner::status_clear() {
  ((_STATUS_ACTIVE == 1)) || return 0
  local i
  for ((i = 0; i < _STATUS_HEIGHT; i++)); do printf '\033[1A\r\033[K' >&2; done
  _STATUS_HEIGHT=0
}

runner::status_stop() {
  ((_STATUS_ACTIVE == 1)) || return 0
  runner::status_clear
  printf '\033[?25h' >&2
  _STATUS_ACTIVE=0
}

runner::status_render() {
  ((_STATUS_ACTIVE == 1)) || return 0
  local frame="${STATUS_SPINNER_FRAMES[_STATUS_FRAME % ${#STATUS_SPINNER_FRAMES[@]}]}"
  _STATUS_FRAME=$((_STATUS_FRAME + 1))
  local head="${frame} Test Files ${runner__files}/${runner__expected_files}  Tests ${runner__passed} passed"
  ((runner__failed == 0)) || head+=", ${runner__failed} failed"
  head+="  $((SECONDS - runner__started_at))s"
  local -a lines=("" "${head}") colors=("" "${_STATUS_HEAD_COLOR}")
  local budget=$((_STATUS_ROWS - 4))
  ((budget <= STATUS_MAX_RUNNING_LINES)) || budget="${STATUS_MAX_RUNNING_LINES}"
  ((budget > 0)) || budget=1
  local shown=0 id secs suffix
  for id in "${_STATUS_INFLIGHT[@]+"${_STATUS_INFLIGHT[@]}"}"; do
    if ((shown >= budget)); then
      lines+=("   … +$((${#_STATUS_INFLIGHT[@]} - shown)) more")
      colors+=("${_STATUS_RUN_COLOR}")
      break
    fi
    secs=$((SECONDS - _STATUS_START[${id}]))
    suffix=""
    ((secs < 2)) || suffix=" ${secs}s"
    lines+=("   ❯ ${_STATUS_PATH[${id}]}${suffix}")
    colors+=("${_STATUS_RUN_COLOR}")
    shown=$((shown + 1))
  done
  printf '\033[?2026h' >&2
  runner::status_clear
  local idx line
  for idx in "${!lines[@]}"; do
    line="${lines[${idx}]}"
    ((${#line} <= _STATUS_COLS)) || line="${line:0:_STATUS_COLS - 1}…"
    printf '%s%s%s\n' "${colors[${idx}]}" "${line}" "${_STATUS_RESET}" >&2
  done
  printf '\033[?2026l' >&2
  _STATUS_HEIGHT="${#lines[@]}"
}

# ── One file ─────────────────────────────────────────────────────────────────

# Runs one test file, isolated: own process group, no stdin, a deadline. Writes
# <work>/<id>.{out,result,exit,elapsed} (and .timeout when the deadline fired).
# Runs in the background; the main loop polls for <id>.exit.
# Usage: runner::run_one <file> <work dir> <id> <timeout s> <display path>
runner::run_one() {
  local -r file="$1" work="$2" id="$3" timeout_s="$4" display="$5"
  local -r out="${work}/${id}.out" result="${work}/${id}.result"
  local started missing="" cmd
  started="$(test::_now_us)"

  while IFS= read -r cmd; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=" ${cmd}"
  done < <(runner::requirements "${file}")
  if [[ -n "${missing}" ]]; then
    printf '🧪 ./%s\n└── ○ Skipped (requires%s)\n' "${display}" "${missing}" >"${out}"
    printf 'passed=0\nfailed=0\nskipped=1\ntotal=0\n' >"${result}"
    echo 0 >"${work}/${id}.exit"
    return 0
  fi

  # --coverage: every bash the test starts loads the tracer.
  local -a env=(BASHX_RESULT_FILE="${result}" BASHX_LIB="${RUNNER_DIR}")
  [[ -z "${BASHX_COVERAGE_TRACE_DIR:-}" ]] || env+=(BASH_ENV="${RUNNER_DIR}/coverage-trace.bash")

  # The deadline rides on perl's alarm, which survives exec: a background
  # watchdog would keep a caller's command substitution open.
  local exit_code=0 pid
  if command -v perl >/dev/null 2>&1; then
    (cd "$(dirname "${file}")" && env "${env[@]}" perl -e 'setpgrp(0,0); alarm shift @ARGV; exec @ARGV' \
      "${timeout_s}" bash "${file}") >"${out}" 2>&1 </dev/null &
    pid=$!
    printf '%s' "${pid}" >"${work}/${id}.pgid"
  else
    (cd "$(dirname "${file}")" && env "${env[@]}" bash "${file}") >"${out}" 2>&1 </dev/null &
    pid=$!
  fi
  wait "${pid}" || exit_code=$?
  # SIGALRM (142): the deadline fired; report it as coreutils timeout does.
  if ((exit_code == 142)); then
    printf '%s' "${timeout_s}" >"${work}/${id}.timeout"
    exit_code=124
  fi
  # Sweep the group so leaked readers cannot outlive the file.
  [[ ! -f "${work}/${id}.pgid" ]] || kill -KILL -"$(cat "${work}/${id}.pgid")" 2>/dev/null || true
  local ended
  ended="$(test::_now_us)"
  awk -v a="${started}" -v b="${ended}" 'BEGIN { printf "%.1f\n", (b - a) / 1e6 }' >"${work}/${id}.elapsed"
  echo "${exit_code}" >"${work}/${id}.exit"
}

# Reads <work>/<id>.result into file_passed / file_failed / file_skipped /
# file_total. Without a result file the exit code counts as one test.
# Usage: runner::read_counts <result file> <exit code>
runner::read_counts() {
  local -r result="$1" exit_code="$2"
  file_passed=0 file_failed=0 file_skipped=0 file_total=0
  if [[ -f "${result}" ]]; then
    local key value
    while IFS='=' read -r key value; do
      case "${key}" in
        passed) file_passed="${value}" ;;
        failed) file_failed="${value}" ;;
        skipped) file_skipped="${value}" ;;
        total) file_total="${value}" ;;
      esac
    done <"${result}"
  else
    file_total=1
    if ((exit_code == 0)); then file_passed=1; else file_failed=1; fi
  fi
  # A non-zero exit is a failure even when every recorded case passed.
  if ((exit_code != 0 && file_failed == 0)); then
    file_failed=1
    ((file_total > 0)) || file_total=1
  fi
}

# Prints a finished file's output and adds its counts to the totals.
# Usage: runner::emit <work dir> <id> <file>
runner::emit() {
  local -r work="$1" id="$2" file="$3"
  local exit_code
  exit_code="$(cat "${work}/${id}.exit" 2>/dev/null || echo 1)"
  [[ -n "${exit_code}" ]] || exit_code=1
  if [[ -f "${work}/${id}.timeout" ]]; then
    printf '⏱️  TIMEOUT after %ss: killed %s (raise with --timeout or BASHX_TIMEOUT)\n' \
      "$(cat "${work}/${id}.timeout")" "$(runner::relative_path "${runner__root}" "${file}")" >>"${work}/${id}.out"
  fi
  runner::status_clear
  ((runner__files == 0)) || echo | tee -a "${runner__log}"
  tee -a "${runner__log}" <"${work}/${id}.out"

  local file_passed file_failed file_skipped file_total
  runner::read_counts "${work}/${id}.result" "${exit_code}"
  runner__passed=$((runner__passed + file_passed))
  runner__failed=$((runner__failed + file_failed))
  runner__skipped=$((runner__skipped + file_skipped))
  runner__total=$((runner__total + file_total))
  runner__files=$((runner__files + 1))
  if ((exit_code != 0 || file_failed > 0)); then
    runner__failed_files+=("$(runner::relative_path "${runner__root}" "${file}")")
  fi
}

# Kills every process group a test file was given (EXIT trap).
runner::sweep() {
  local -r work="${1:-}"
  [[ -n "${work}" && -d "${work}" ]] || return 0
  local pgid_file
  for pgid_file in "${work}"/*.pgid; do
    [[ -f "${pgid_file}" ]] || continue
    kill -KILL -"$(cat "${pgid_file}")" 2>/dev/null || true
  done
}

# Runs <files> on <jobs> workers, streaming each result as it lands.
# Usage: runner::run_all <work dir> <jobs> <timeout> <file>...
runner::run_all() {
  local -r work="$1" jobs="$2" timeout_s="$3"
  shift 3
  local -a files=("$@") pending
  local next=0 reaped id
  runner::status_start
  # Poll instead of `wait -n`: the status block keeps animating and results
  # stream out as soon as each file lands.
  while ((next < ${#files[@]} || ${#_STATUS_INFLIGHT[@]} > 0)); do
    while ((${#_STATUS_INFLIGHT[@]} < jobs && next < ${#files[@]})); do
      runner::run_one "${files[next]}" "${work}" "${next}" "${timeout_s}" \
        "$(runner::relative_path "${runner__root}" "${files[next]}")" &
      _STATUS_PID[${next}]=$!
      _STATUS_PATH[${next}]="$(runner::relative_path "${runner__root}" "${files[next]}")"
      _STATUS_START[${next}]="${SECONDS}"
      _STATUS_INFLIGHT+=("${next}")
      next=$((next + 1))
    done
    reaped=0
    pending=()
    for id in "${_STATUS_INFLIGHT[@]}"; do
      if [[ -f "${work}/${id}.exit" ]]; then
        wait "${_STATUS_PID[${id}]}" 2>/dev/null || true
        unset "_STATUS_PID[${id}]" "_STATUS_PATH[${id}]" "_STATUS_START[${id}]"
        runner::emit "${work}" "${id}" "${files[id]}"
        reaped=1
      else
        pending+=("${id}")
      fi
    done
    _STATUS_INFLIGHT=("${pending[@]+"${pending[@]}"}")
    ((${#_STATUS_INFLIGHT[@]} == 0)) || runner::status_render
    ((reaped == 1)) || sleep "${STATUS_POLL_INTERVAL}"
  done
  runner::status_stop
}

# Writes test_report.<format> with the reporter of that name.
# Usage: runner::report <format> <log>
runner::report() {
  local -r format="$1" log="$2"
  local -r reporter="${RUNNER_DIR}/reporters/${format}.sh"
  [[ -f "${reporter}" ]] || {
    echo "Unknown report format: ${format} (markdown, json, junit)" >&2
    return 1
  }
  "${reporter}" "test_report.${format}" "${log}" "${runner__passed}" "${runner__failed}" \
    "${runner__skipped}" "${runner__total}" "${runner__files}" "${runner__failed_files[@]+"${runner__failed_files[@]}"}"
  echo
  echo "📄 Report generated: test_report.${format}"
}

runner::main() {
  local kind="" jobs="${BASHX_JOBS:-}" timeout_s="${BASHX_TIMEOUT:-60}" shard="1/1"
  local durations="" record_durations="" coverage_dir="" report="" root="" arg
  for arg in "$@"; do
    case "${arg}" in
      --kind=*) kind="${arg#*=}" ;;
      --jobs=*) jobs="${arg#*=}" ;;
      --timeout=*) timeout_s="${arg#*=}" ;;
      --shard=*) shard="${arg#*=}" ;;
      --durations=*) durations="${arg#*=}" ;;
      --record-durations=*) record_durations="${arg#*=}" ;;
      --coverage=*) coverage_dir="${arg#*=}" ;;
      --report=*) report="${arg#*=}" ;;
      -h | --help) runner::usage; return 0 ;;
      -*) echo "Unknown option: ${arg}" >&2; runner::usage >&2; return 2 ;;
      *) root="${arg}" ;;
    esac
  done
  [[ -n "${root}" ]] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  [[ -d "${root}" ]] || { echo "Not a directory: ${root}" >&2; return 2; }
  root="$(cd "${root}" && pwd)"
  [[ -n "${jobs}" ]] || jobs="$(runner::cpu_count)"
  [[ "${jobs}" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --jobs=${jobs}" >&2; return 2; }
  [[ "${timeout_s}" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --timeout=${timeout_s}" >&2; return 2; }
  if [[ ! "${shard}" =~ ^([0-9]+)/([0-9]+)$ ]] || ((BASH_REMATCH[1] < 1 || BASH_REMATCH[1] > BASH_REMATCH[2])); then
    echo "Invalid --shard=${shard} (want I/N with 1 <= I <= N)" >&2
    return 2
  fi
  local -r shard_index="${BASH_REMATCH[1]}" shard_count="${BASH_REMATCH[2]}"
  [[ -n "${durations}" ]] || durations="${root}/.bashx/durations.tsv"

  local -a all=() files=()
  mapfile -t all < <(runner::discover "${root}" "${kind}")
  if ((${#all[@]} == 0)); then
    echo "No ${kind:+${kind} }test files (*${kind:+.${kind}}.test.sh) under ${root}" >&2
    return 1
  fi
  mapfile -t files < <(runner::plan "${root}" "${durations}" "${shard_index}" "${shard_count}" "${all[@]}")

  local work
  work="$(mktemp -d "${TMPDIR:-/tmp}/bashx-run.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: the path is fixed
  trap "runner::status_stop; runner::sweep '${work}'; rm -rf -- '${work}'" EXIT
  trap 'runner::status_stop; exit 130' INT TERM

  if [[ -n "${coverage_dir}" ]]; then
    mkdir -p "${coverage_dir}/traces"
    coverage_dir="$(cd "${coverage_dir}" && pwd)"
    export BASHX_COVERAGE_TRACE_DIR="${coverage_dir}/traces"
  fi

  # Totals, read by emit, the status block and the reporters.
  runner__root="${root}" runner__log="${work}/combined.log"
  runner__files=0 runner__passed=0 runner__failed=0 runner__skipped=0 runner__total=0
  runner__expected_files="${#files[@]}" runner__started_at="${SECONDS}"
  runner__failed_files=()
  : >"${runner__log}"
  local -r started_us="$(test::_now_us)"

  ((${#files[@]} == 0)) || runner::run_all "${work}" "${jobs}" "${timeout_s}" "${files[@]}"

  if [[ -n "${record_durations}" ]]; then
    local i
    mkdir -p "$(dirname "${record_durations}")"
    for i in "${!files[@]}"; do
      [[ -f "${work}/${i}.elapsed" ]] || continue
      printf '%s\t%s\n' "$(cat "${work}/${i}.elapsed")" "$(runner::relative_path "${root}" "${files[i]}")"
    done | LC_ALL=C sort -t $'\t' -k2,2 >"${record_durations}"
    echo "⏱️  Durations written to ${record_durations}"
  fi

  if [[ -n "${coverage_dir}" ]]; then
    unset BASHX_COVERAGE_TRACE_DIR
    "${RUNNER_DIR}/coverage.sh" covered -r "${root}" "${coverage_dir}/traces" >"${coverage_dir}/covered.tsv"
    rm -rf "${coverage_dir:?}/traces"
    echo "🧭 Coverage: $("${RUNNER_DIR}/coverage.sh" report -r "${root}" "${coverage_dir}/covered.tsv")"
  fi

  local ms=$((($(test::_now_us) - started_us) / 1000)) line
  line="📊 Test Summary: ${runner__passed} passed, ${runner__failed} failed"
  ((runner__skipped == 0)) || line+=", ${runner__skipped} skipped"
  line+=", ${runner__total} total (${ms}ms)"
  { echo; echo "${line}"; } | tee -a "${runner__log}"
  if ((${#runner__failed_files[@]} > 0)); then
    echo | tee -a "${runner__log}"
    echo "Failed test files:" | tee -a "${runner__log}"
    printf '  • %s\n' "${runner__failed_files[@]}" | tee -a "${runner__log}"
  fi

  [[ -z "${report}" ]] || runner::report "${report}" "${runner__log}"
  ((runner__failed == 0 && ${#runner__failed_files[@]} == 0))
}

# shellcheck source=bashx.sh
source "${RUNNER_DIR}/bashx.sh"
trap - EXIT

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  runner::main "$@"
fi
