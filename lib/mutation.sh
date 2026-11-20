#!/usr/bin/env bash
# Mutation testing for bash: change one operator of a script at a time (a
# mutant), run the script's tests, and count the mutants they catch.
# A surviving mutant is a behaviour no test pins down.
#
# Mutants run in throwaway copies of the project (one per job, never the
# working tree itself), so the tests run unchanged against the mutated file.
# See docs/mutation-testing.md.
set -o errexit -o pipefail -o nounset

MUTATION_US=$'\x1f'
MUTATION_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function usage() {
  cat <<USAGE
Usage: bashx mutate [options] <script.sh>...

Mutates each script, runs its tests (<dir>/<name>.test.sh and
<dir>/<name>.*.test.sh by default) against every mutant, prints a Markdown
report.

  -t <test>     test file to run (repeatable; default: the script's own tests)
  -o <ops>      operators or groups, comma-separated (default: all; see -L)
  -k <order>    1 = one mutation per mutant, 2 = pairs on two lines (default: 1)
  -m <max>      run at most <max> mutants, sampled deterministically (default: all)
  -j <jobs>     parallel project copies (default: CPU count)
  -T <seconds>  per-test deadline (default: 3 x baseline + 5, at least 10)
  -s <score>    exit 1 when a script scores under <score> % (default: off)
  -r <file>     also write one TSV row per mutant to <file>
  -n            dry run: count the mutants, run nothing
  -L            list the operators
  -h            this help

Lines with a "# no-mutate[: why]" comment are left alone.
USAGE
}

# One operator per line: name, ERE that locates it (with its context), the
# literal it replaces inside that match, the replacement, and an optional ERE
# the whole line must match. stmt-del is handled by mutation::deletable.
function mutation::operators() {
  local -r t=$'\t'
  cat <<OPERATORS
rel-eq${t} -eq ${t}-eq${t}-ne${t}
rel-ne${t} -ne ${t}-ne${t}-eq${t}
rel-lt${t} -lt ${t}-lt${t}-le${t}
rel-le${t} -le ${t}-le${t}-lt${t}
rel-gt${t} -gt ${t}-gt${t}-ge${t}
rel-ge${t} -ge ${t}-ge${t}-gt${t}
str-eq${t} == ${t}==${t}!=${t}
str-ne${t} != ${t}!=${t}==${t}
str-z${t}\\[\\[ -z ${t}-z${t}-n${t}
str-n${t}\\[\\[ -n ${t}-n${t}-z${t}
arith-lt${t} < ${t}<${t}<=${t}\\(\\(
arith-le${t} <= ${t}<=${t}<${t}\\(\\(
arith-gt${t} > ${t}>${t}>=${t}\\(\\(
arith-ge${t} >= ${t}>=${t}>${t}\\(\\(
arith-add${t} \\+ ${t}+${t}-${t}\\(\\(
arith-sub${t} - ${t}-${t}+${t}\\(\\(
arith-mul${t} \\* ${t}*${t}/${t}\\(\\(
arith-div${t} / ${t}/${t}*${t}\\(\\(
arith-mod${t} % ${t}%${t}*${t}\\(\\(
arith-incr${t}\\+\\+${t}++${t}--${t}
cond-neg${t}\\[\\[ [^!]${t}[[${t}[[ !${t}
cond-drop-neg${t}(if|elif|while|&&|\\|\\||\\[\\[) ! ${t}! ${t}${t}
logic-and${t} && ${t}&&${t}||${t}
logic-or${t} \\|\\| ${t}||${t}&&${t}
ret-0${t}(return|exit) 0([^0-9]|\$)${t} 0${t} 1${t}
ret-1${t}(return|exit) 1([^0-9]|\$)${t} 1${t} 0${t}
bool-true${t}(^|[^[:alnum:]_:-])true([^[:alnum:]_:-]|\$)${t}true${t}false${t}
bool-false${t}(^|[^[:alnum:]_:-])false([^[:alnum:]_:-]|\$)${t}false${t}true${t}
stmt-del${t}${t}<command>${t}:${t}
OPERATORS
}

# Operators selected by a comma list of names or group prefixes ("rel",
# "arith-add"); every operator when the list is empty.
# Usage: mutation::select_operators <list>
function mutation::select_operators() {
  local -r list="$1"
  mutation::operators | awk -F'\t' -v list="${list}" '
    BEGIN { n = split(list, want, ",") }
    {
      if (n == 0) { print; next }
      for (i = 1; i <= n; i++) {
        if ($1 == want[i] || index($1, want[i] "-") == 1) { print; next }
      }
    }'
}

# First-order mutants of <file>, one per line: op US line US mutated line.
# Skips blank and comment lines, heredoc bodies, "# no-mutate" lines, and
# trailing comments. Every match of an operator on a line is its own mutant.
# Usage: mutation::generate <file> <operators>
function mutation::generate() {
  local -r file="$1" operators="$2"
  # ENVIRON, not -v: awk -v would eat the backslashes of the regexes.
  MUTATION_OPS="${operators}" awk -F'\t' -v us="${MUTATION_US}" '
    BEGIN {
      nops = split(ENVIRON["MUTATION_OPS"], rows, "\n")
      for (i = 1; i <= nops; i++) {
        split(rows[i], f, "\t")
        name[i] = f[1]; re[i] = f[2]; from[i] = f[3]; to[i] = f[4]; guard[i] = f[5]
      }
      FS = "\n"
    }
    heredoc != "" {
      t = $0; sub(/^[ \t]+/, "", t)
      if (t == heredoc) heredoc = ""
      next
    }
    {
      if ($0 !~ /<<</ && match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
        heredoc = substr($0, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*["\047]?/, "", heredoc)
      }
    }
    /^[ \t]*(#|$)/ { next }
    /[ \t]#[ \t]*no-mutate([ \t:]|$)/ { next }
    {
      code = $0; comment = ""
      if (match(code, /[ \t]#/)) { comment = substr(code, RSTART); code = substr(code, 1, RSTART - 1) }
      for (i = 1; i <= nops; i++) {
        if (name[i] == "stmt-del") { if (deletable(code)) emit(i, indent(code) ":"); continue }
        if (guard[i] != "" && code !~ guard[i]) continue
        rest = code; off = 0
        while (rest != "" && match(rest, re[i])) {
          m = substr(rest, RSTART, RLENGTH)
          p = index(m, from[i])
          start = off + RSTART + p - 1
          emit(i, substr(code, 1, start - 1) to[i] substr(code, start + length(from[i])))
          adv = RSTART + p + length(from[i]) - 2
          off += adv; rest = substr(rest, adv + 1)
        }
      }
    }
    function emit(i, mutated) { print name[i] us NR us mutated comment }
    function indent(s) { match(s, /^[ \t]*/); return substr(s, 1, RLENGTH) }
    function deletable(s,   t) {
      t = s; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
      if (t ~ /^;;/ || t ~ /;;$/) return 0
      sub(/[ \t;]+$/, "", t)
      if (t ~ /^(if|then|else|elif|fi|for|while|until|do|done|case|esac|function|select|set|shopt)([ \t;]|$)/) return 0
      if (t ~ /^(local|declare|readonly|typeset|export)( +-[a-zA-Z]+)*( +[A-Za-z_][A-Za-z0-9_]*)+$/) return 0
      if (t ~ /^[{}()]/ || t ~ /(\{|\(|\\|\||&&|then|do|in)$/) return 0
      if (t ~ /^[^(]*\)/ || t == ":") return 0
      return 1
    }
  ' "${file}"
}

# Second-order mutants: every pair of first-order mutants on two different
# lines, as op1+op2 (names sorted) US line1 US text1 US line2 US text2.
# Usage: mutation::pairs < first-order mutants
function mutation::pairs() {
  awk -F"${MUTATION_US}" -v us="${MUTATION_US}" '
    { op[NR] = $1; line[NR] = $2; text[NR] = $3 }
    END {
      for (i = 1; i <= NR; i++) for (j = i + 1; j <= NR; j++) {
        if (line[i] == line[j]) continue
        print (op[i] <= op[j] ? op[i] "+" op[j] : op[j] "+" op[i]) us line[i] us text[i] us line[j] us text[j]
      }
    }'
}

# Keeps <max> lines, the same ones on every run (0 keeps all).
# Usage: mutation::sample <max> < lines
function mutation::sample() {
  local -r max="$1"
  if ((max == 0)); then
    cat
  else
    shuf -n "${max}" --random-source=<(yes)
  fi
}

# The tests of <script>: <dir>/<name>.test.sh and <dir>/<name>.*.test.sh.
# Usage: mutation::own_tests <script>
function mutation::own_tests() {
  local -r script="$1"
  local -r base="${script%.sh}"
  local file
  for file in "${base}.test.sh" "${base}".*.test.sh; do
    [[ ! -f "${file}" ]] || echo "${file}"
  done
}

# Copy of the project's working tree (tracked + untracked, not ignored) in
# <dest>, committed in a fresh git repo so `git rev-parse` and `git ls-files`
# answer inside it as they do in the checkout.
# Usage: mutation::sandbox <repo_root> <dest>
function mutation::sandbox() {
  local -r root="$1" dest="$2"
  mkdir -p "${dest}"
  # Files that exist (a tracked file deleted in the working tree is listed
  # too), one per line for `tar -T`, which GNU, BSD and busybox tar all read.
  local -r list="${dest}.files"
  git -C "${root}" ls-files -z -co --exclude-standard \
    | (cd "${root}" && while IFS= read -r -d '' file; do
      [[ ! -e "${file}" && ! -L "${file}" ]] || printf '%s\n' "${file}"
    done) >"${list}"
  (cd "${root}" && tar -cf - -T "${list}") | tar -xf - -C "${dest}"
  rm -f -- "${list}"
  git -C "${dest}" init -q
  git -C "${dest}" add -A
  git -C "${dest}" -c user.name=mutation -c user.email=mutation@localhost \
    -c commit.gpgsign=false commit -qm sandbox --no-verify
}

# Exit code of one test file run from its directory in <sandbox> (124 = past
# the deadline). As in `bashx test`, failed cases in BASHX_RESULT_FILE fail the
# file even when it exits 0 (a library's EXIT trap can swallow the status).
# Usage: mutation::run_test <sandbox> <timeout> <relative test>
function mutation::run_test() {
  local -r sandbox="$1" deadline="$2" test_file="$3"
  local -r result="${sandbox}/.mutation-result"
  local rc=0
  rm -f -- "${result}"
  (cd "${sandbox}/$(dirname "${test_file}")" && BASHX_RESULT_FILE="${result}" BASHX_LIB="${MUTATION_LIB}" NO_COLOR=1 \
    timeout -k 5 "${deadline}" bash "$(basename "${test_file}")") >/dev/null 2>&1 </dev/null || rc=$?
  if ((rc == 0)) && grep -qE '^failed=[1-9]' "${result}" 2>/dev/null; then rc=1; fi
  echo "${rc}"
}

# Writes <file> with the mutations of one record applied (line US text ...).
# Usage: mutation::apply <original> <dest> <line> <text> [<line> <text>]...
function mutation::apply() {
  local -r original="$1" dest="$2"
  shift 2
  local -a lines
  mapfile -t lines <"${original}"
  while (($# >= 2)); do
    lines[$1 - 1]="$2"
    shift 2
  done
  printf '%s\n' "${lines[@]}" >"${dest}"
}

# Runs the mutants of <queue> (id US op US line US text ...) in <sandbox>,
# appends "id<TAB>status<TAB>ms" to <results>. status: killed, timeout,
# survived, invalid (the mutant does not parse).
# Usage: mutation::worker <sandbox> <rel script> <timeout> <queue> <results> <rel test>...
function mutation::worker() {
  local -r sandbox="$1" script="$2" deadline="$3" queue="$4" results="$5"
  shift 5
  local -r target="${sandbox}/${script}" original="${sandbox}/.mutation-original"
  cp "${target}" "${original}"
  local id status start rc test_file
  local -a fields
  while IFS="${MUTATION_US}" read -r -a fields; do
    id="${fields[0]}"
    start="$(date +%s%N)"
    mutation::apply "${original}" "${target}" "${fields[@]:2}"
    status=survived
    if ! bash -n "${target}" 2>/dev/null; then
      status=invalid
    else
      for test_file in "$@"; do
        rc="$(mutation::run_test "${sandbox}" "${deadline}" "${test_file}")"
        if ((rc == 124 || rc == 137)); then status=timeout; break; fi
        if ((rc != 0)); then status=killed; break; fi
      done
    fi
    printf '%s\t%s\t%s\n' "${id}" "${status}" $((($(date +%s%N) - start) / 1000000)) >>"${results}"
  done <"${queue}"
  cp "${original}" "${target}"
}

# Prints the deadline in seconds for tests that took <ms> unmutated.
# Usage: mutation::deadline <baseline ms>
function mutation::deadline() {
  local -r ms="$1"
  local secs=$(((3 * ms + 999) / 1000 + 5))
  ((secs >= 10)) || secs=10 # no-mutate: > 10 also yields 10
  echo "${secs}"
}

# Markdown table of the run, one row per operator (or operator pair), then
# the survivors. Reads the joined rows: id, op, status, ms, line, text...
# Usage: mutation::report_table <script> <joined rows file> <original>
function mutation::report_table() {
  local -r script="$1" joined="$2" original="$3"
  echo "| Operator | Mutation | Mutants | Killed | Timeout | Survived | Invalid | Score |"
  echo "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"
  MUTATION_OPS="$(mutation::operators)" awk -F'\t' '
    BEGIN {
      n = split(ENVIRON["MUTATION_OPS"], rows, "\n")
      for (i = 1; i <= n; i++) { split(rows[i], f, "\t"); desc[f[1]] = "`" esc(f[3]) "` → `" esc(f[4]) "`"; rank[f[1]] = i }
      desc["stmt-del"] = "command → `:`"
    }
    {
      if (!($2 in total)) order[++seen] = $2
      total[$2]++; count[$2, $3]++; all[$3]++; sum++
    }
    END {
      for (i = 1; i <= seen; i++) for (j = i + 1; j <= seen; j++) if (key(order[j]) < key(order[i])) { t = order[i]; order[i] = order[j]; order[j] = t }
      for (i = 1; i <= seen; i++) {
        op = order[i]
        d = (op in desc) ? desc[op] : pair(op)
        row(op, d, total[op], count[op, "killed"], count[op, "timeout"], count[op, "survived"], count[op, "invalid"])
      }
      row("**Total**", "", sum, all["killed"], all["timeout"], all["survived"], all["invalid"])
    }
    function esc(s,   out, i, c) { for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); out = out (c == "|" ? "\\|" : c) }; return out }
    function key(op,   p) { p = index(op, "+"); if (!p) return sprintf("%04d", rank[op]); return sprintf("%04d%04d", rank[substr(op, 1, p - 1)], rank[substr(op, p + 1)]) }
    function pair(op,   p) { p = index(op, "+"); return "combination of " substr(op, 1, p - 1) " and " substr(op, p + 1) }
    function row(op, d, tot, k, t, s, inv,   v) {
      v = k + t + s
      printf "| %s | %s | %d | %d | %d | %d | %d | %s |\n", op, d, tot, k, t, s, inv, (v ? sprintf("%.1f%%", (k + t) * 100 / v) : "n/a")
    }
  ' "${joined}"
  mutation::report_survivors "${script}" "${joined}" "${original}"
}

# Up to 40 survivors as "script:line op: before → after".
# Usage: mutation::report_survivors <script> <joined rows file> <original>
function mutation::report_survivors() {
  local -r script="$1" joined="$2" original="$3"
  local survivors
  survivors="$(awk -F'\t' '$3 == "survived"' "${joined}" | sort -t $'\t' -k5,5n)"
  [[ -n "${survivors}" ]] || return 0
  echo
  echo "<details><summary>Survivors ($(wc -l <<<"${survivors}"))</summary>"
  echo
  local -a lines fields
  mapfile -t lines <"${original}"
  local row before after i
  while IFS= read -r row; do
    IFS=$'\t' read -r -a fields <<<"${row}"
    for ((i = 4; i + 1 < ${#fields[@]}; i += 2)); do # no-mutate: fields come in pairs, <= is the same
      before="$(mutation::trim "${lines[fields[i] - 1]}")"
      after="$(mutation::trim "${fields[i + 1]}")"
      echo "- \`${script}:${fields[i]}\` ${fields[1]}: \`${before}\` → \`${after}\`"
    done
  done < <(head -n 40 <<<"${survivors}")
  echo
  echo "</details>"
}

function mutation::trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s//\`/\'}"
  echo "${s:0:120}"
}

# Prints the mutant records of <script> for <order>, sampled to <max>:
# id US op US line US text [US line US text].
# Usage: mutation::mutants <script> <operators> <order> <max>
function mutation::mutants() {
  local -r script="$1" operators="$2" order="$3" max="$4"
  if ((order == 1)); then
    mutation::generate "${script}" "${operators}"
  else
    mutation::generate "${script}" "${operators}" | mutation::pairs
  fi | mutation::sample "${max}" | awk -v us="${MUTATION_US}" '{ print NR us $0 }'
}

# Dry run row: | script | lines | order-1 mutants | order-2 pairs |
# Usage: mutation::count <repo root> <script> <operators>
function mutation::count() {
  local -r root="$1" script="$2" operators="$3"
  local first pairs
  first="$(mutation::generate "${root}/${script}" "${operators}" | wc -l)"
  pairs="$(mutation::generate "${root}/${script}" "${operators}" | mutation::pairs | wc -l)"
  echo "| \`${script}\` | $(wc -l <"${root}/${script}") | ${first} | ${pairs} |"
}

# Runs every mutant of one script on <jobs> sandboxes and prints its report.
# Leaves "<mutants> <killed> <timeout> <survived> <invalid> <seconds>" in
# <workdir>/summary for the run summary.
# Usage: mutation::run_script <workdir> <script> <operators> <order> <max> <deadline> <tsv> <test>...
function mutation::run_script() {
  local -r workdir="$1" script="$2" operators="$3" order="$4" max="$5" deadline_opt="$6" tsv="$7"
  shift 7
  local -a tests=("$@") sandboxes # no-mutate: main's own tests hold the same files
  mapfile -t sandboxes < <(find "${workdir}" -maxdepth 1 -name 'sandbox-*' | sort)
  local -r jobs="${#sandboxes[@]}" queue="${workdir}/mutants" results="${workdir}/results"
  local started=${SECONDS} baseline_ms deadline test_file start rc
  rm -f -- "${queue}".* "${results}".* # no-mutate: stale rows carry old ids, overwritten by this run's

  start="$(date +%s%N)"
  for test_file in "${tests[@]}"; do
    rc="$(mutation::run_test "${sandboxes[0]}" 600 "${test_file}")"
    if ((rc != 0)); then
      echo "error: ${test_file} fails before any mutation (exit ${rc}): fix it first" >&2
      return 1 # no-mutate: main stops on the missing summary either way
    fi
  done
  baseline_ms=$((($(date +%s%N) - start) / 1000000))
  deadline="${deadline_opt:-$(mutation::deadline "${baseline_ms}")}"

  mutation::mutants "${sandboxes[0]}/${script}" "${operators}" "${order}" "${max}" >"${queue}"
  local -r total="$(wc -l <"${queue}")"
  echo "mutation: ${script}: ${total} mutants, ${jobs} jobs, tests ${baseline_ms} ms unmutated" >&2

  local w
  local -a pids=() # no-mutate: bash still reports the status of a reaped pid
  for ((w = 0; w < jobs; w++)); do
    awk -v n="${jobs}" -v w="${w}" '(NR - 1) % n == w' "${queue}" >"${queue}.${w}"
    mutation::worker "${sandboxes[w]}" "${script}" "${deadline}" "${queue}.${w}" "${results}.${w}" "${tests[@]}" &
    pids+=("$!")
  done
  mutation::progress "${total}" "${results}" "${pids[@]}"
  for w in "${pids[@]}"; do wait "${w}"; done
  cat "${results}".* >"${results}" 2>/dev/null || true # no-mutate: && true only differs when cat fails, where errexit ignores it

  local -r elapsed=$((SECONDS - started))
  mutation::report_script "${workdir}" "${script}" "${order}" "${baseline_ms}" "${elapsed}" "${tsv}" "${tests[@]}"
}

# Waits for the workers, printing "done/total" on stderr every
# MUTATION_PROGRESS_EVERY seconds (default 10).
# Usage: mutation::progress <total> <results prefix> <pid>...
function mutation::progress() {
  local -r total="$1" results="$2" every="${MUTATION_PROGRESS_EVERY:-10}"
  shift 2
  local alive pid tick=0
  while true; do
    alive=0
    for pid in "$@"; do kill -0 "${pid}" 2>/dev/null && alive=1; done
    ((alive == 1)) || return 0
    sleep 1
    tick=$((tick + 1)) # no-mutate: counting down hits the same multiples
    ((tick % every != 0)) || echo "mutation: $(cat "${results}".* 2>/dev/null | wc -l)/${total}" >&2
  done
}

# Report of one script: header, table, survivors; appends the TSV rows.
# Usage: mutation::report_script <workdir> <script> <order> <baseline ms> <seconds> <tsv> <test>...
function mutation::report_script() {
  local -r workdir="$1" script="$2" order="$3" baseline_ms="$4" elapsed="$5" tsv="$6"
  shift 6
  local -r joined="${workdir}/joined"
  # id op status ms line text [line text]
  awk -F'\t' -v us="${MUTATION_US}" '
    NR == FNR { status[$1] = $2; ms[$1] = $3; next }
    {
      n = split($0, f, us)
      out = f[1] "\t" f[2] "\t" status[f[1]] "\t" ms[f[1]]
      for (i = 3; i <= n; i++) out = out "\t" f[i]
      print out
    }' "${workdir}/results" "${workdir}/mutants" >"${joined}"
  [[ -z "${tsv}" ]] || awk -F'\t' -v s="${script}" '{ print s "\t" $0 }' "${joined}" >>"${tsv}"

  local tests_md="" t
  for t in "$@"; do tests_md+="\`${t##*/}\` "; done
  echo "### \`${script}\`"
  echo
  echo "Tests: ${tests_md}(${baseline_ms} ms unmutated) · order ${order} · ${elapsed} s"
  echo
  mutation::report_table "${script}" "${joined}" "${workdir}/sandbox-0/${script}"
  echo
  awk -F'\t' -v e="${elapsed}" '
    { c[$3]++; n++ }
    END { print n + 0, c["killed"] + 0, c["timeout"] + 0, c["survived"] + 0, c["invalid"] + 0, e }' "${joined}" >"${workdir}/summary"
}

# Parses options into the globals opt_*.
function mutation::parse_args() {
  opt_tests=() opt_ops="" opt_order=1 opt_max=0 opt_jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
  opt_deadline="" opt_min_score="" opt_tsv="" opt_dry=0
  local opt
  OPTIND=1 # no-mutate: parsed once per process
  while getopts "t:o:k:m:j:T:s:r:nLh" opt; do
    case "${opt}" in
      t) opt_tests+=("${OPTARG}") ;;
      o) opt_ops="${OPTARG}" ;;
      k) opt_order="${OPTARG}" ;;
      m) opt_max="${OPTARG}" ;;
      j) opt_jobs="${OPTARG}" ;;
      T) opt_deadline="${OPTARG}" ;;
      s) opt_min_score="${OPTARG}" ;;
      r) opt_tsv="${OPTARG}" ;;
      n) opt_dry=1 ;;
      L) opt_dry=2 ;;
      h) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  opt_scripts=("${@:OPTIND}")
  [[ "${opt_order}" =~ ^[12]$ && "${opt_max}" =~ ^[0-9]+$ && "${opt_jobs}" =~ ^[1-9][0-9]*$ ]] \
    || { usage >&2; exit 2; }
  ((opt_dry == 2 || ${#opt_scripts[@]} > 0)) || { usage >&2; exit 2; }
}

# Prints the operators as a Markdown table.
function mutation::list_operators() {
  echo "| Operator | Mutation | Only on lines matching |"
  echo "| --- | --- | --- |"
  mutation::operators | awk -F'\t' '
    {
      d = ($1 == "stmt-del") ? "command → `:`" : "`" esc($3) "` → `" esc($4) "`"
      printf "| %s | %s | %s |\n", $1, d, ($5 == "" ? "" : "`" esc($5) "`")
    }
    function esc(s,   out, i, c) { for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); out = out (c == "|" ? "\\|" : c) }; return out }'
}

function main() {
  mutation::parse_args "$@"
  if ((opt_dry == 2)); then mutation::list_operators; return 0; fi

  local root operators script rel failed=0
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "error: bashx mutate runs inside a git repository (it copies the tracked files)" >&2
    return 2
  }
  operators="$(mutation::select_operators "${opt_ops}")"
  [[ -n "${operators}" ]] || { echo "error: no operator matches -o ${opt_ops}" >&2; return 2; }

  if ((opt_dry == 1)); then
    echo "| Script | Lines | Mutants (order 1) | Pairs (order 2) |"
    echo "| --- | ---: | ---: | ---: |"
    for script in "${opt_scripts[@]}"; do
      mutation::count "${root}" "$(realpath --relative-to="${root}" "${script}")" "${operators}"
    done
    return 0
  fi

  local workdir w
  workdir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the path is fixed
  trap "rm -rf -- '${workdir:?}'" EXIT
  echo "mutation: copying the repo into ${opt_jobs} sandboxes" >&2
  for ((w = 0; w < opt_jobs; w++)); do mutation::sandbox "${root}" "${workdir}/sandbox-${w}" & done
  wait # no-mutate: without it the copies race the first run, not reliably observable
  [[ -z "${opt_tsv}" ]] || printf 'script\tid\toperator\tstatus\tms\tline\ttext\n' >"${opt_tsv}"

  local -a tests summaries=() # no-mutate: main is the outermost scope
  local summary
  echo "## Mutation testing"
  echo
  for script in "${opt_scripts[@]}"; do
    rel="$(realpath --relative-to="${root}" "${script}")"
    if ((${#opt_tests[@]} > 0)); then
      mapfile -t tests < <(for t in "${opt_tests[@]}"; do realpath --relative-to="${root}" "${t}"; done)
    else
      mapfile -t tests < <(cd "${root}" && mutation::own_tests "${rel}")
    fi
    ((${#tests[@]} > 0)) || { echo "error: no test for ${rel}: pass -t <test>" >&2; return 2; }
    mutation::run_script "${workdir}" "${rel}" "${operators}" "${opt_order}" "${opt_max}" \
      "${opt_deadline}" "${opt_tsv}" "${tests[@]}" || return 1
    summary="$(cat "${workdir}/summary")"
    summaries+=("${rel} ${summary}")
    mutation::below_min_score "${summary}" "${opt_min_score}" || failed=1
  done
  mutation::report_summary "${summaries[@]}"
  return "${failed}"
}

# Returns 1 when the score of "<n> <killed> <timeout> <survived> ..." is under <min>.
# Usage: mutation::below_min_score <summary> <min score>
function mutation::below_min_score() {
  local -r min="$2"
  [[ -n "${min}" ]] || return 0 # no-mutate: awk compares to "" as a string, never below
  local k t s
  read -r _ k t s _ <<<"$1"
  awk -v k="${k}" -v t="${t}" -v s="${s}" -v min="${min}" \
    'BEGIN { v = k + t + s; exit (v > 0 && (k + t) * 100 / v < min) ? 1 : 0 }'
}

# Cross-script table: one row per "script n killed timeout survived invalid seconds".
# Usage: mutation::report_summary <row>...
function mutation::report_summary() {
  (($# > 1)) || return 0
  echo "### Summary"
  echo
  echo "| Script | Mutants | Killed | Timeout | Survived | Invalid | Score | Time |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
  printf '%s\n' "$@" | awk '
    { printf "| `%s` | %d | %d | %d | %d | %d | %s | %d s |\n", $1, $2, $3, $4, $5, $6, score($3, $4, $5), $7
      for (i = 2; i <= 7; i++) tot[i] += $i }
    END { printf "| **Total** | %d | %d | %d | %d | %d | %s | %d s |\n", tot[2], tot[3], tot[4], tot[5], tot[6], score(tot[3], tot[4], tot[5]), tot[7] }
    function score(k, t, s) { return (k + t + s) ? sprintf("%.1f%%", (k + t) * 100 / (k + t + s)) : "n/a" }'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
