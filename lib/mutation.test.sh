#!/usr/bin/env bash
set -euo pipefail

# Tests of mutation testing (bashx mutate).
source "$(dirname "${BASH_SOURCE[0]}")/bashx.sh"

MUTATION_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mutation.sh"


# Mutants of the script on stdin as "op:line:text", one per line.
# Usage: mutants_of [operators] < script
mutants_of() {
  local -r ops="${1:-}"
  local file
  file="$(test::tmp_dir)/script.sh"
  cat >"${file}"
  mutation::generate "${file}" "$(mutation::select_operators "${ops}")" | tr '\037' ':'
}

test_should_make_one_mutant_per_match_of_an_operator() {
  local out
  out="$(mutants_of rel,logic <<<'[[ "$a" -eq 1 && "$b" -eq 2 ]]')"
  assert "${out}" == 'rel-eq:1:[[ "$a" -ne 1 && "$b" -eq 2 ]]
rel-eq:1:[[ "$a" -eq 1 && "$b" -ne 2 ]]
logic-and:1:[[ "$a" -eq 1 || "$b" -eq 2 ]]'
}

test_should_skip_comments_heredoc_bodies_and_no_mutate_lines() {
  local out
  out="$(mutants_of bool <<'EOF'
#!/usr/bin/env bash
# true
cat <<TXT
true
TXT
x=true # no-mutate: equivalent
z=true # no-mutate
y=true # keep this comment: true
EOF
)"
  assert "${out}" == "bool-true:8:y=false # keep this comment: true"
}

test_should_not_double_a_negation() {
  local out
  out="$(mutants_of cond <<<'if [[ ! -f x ]]; then echo; fi')"
  assert "${out}" == "cond-drop-neg:1:if [[ -f x ]]; then echo; fi"
}

test_should_mutate_arithmetic_only_inside_double_parentheses() {
  local out
  out="$(mutants_of arith <<'EOF'
echo a - b > out
n=$((a - b))
EOF
)"
  assert "${out}" == 'arith-sub:2:n=$((a + b))'
}

test_should_delete_commands_but_not_keywords_or_bare_declarations() {
  local out
  out="$(mutants_of stmt-del <<'EOF'
f() {
  local x
  local -r y="$1"
  if true; then
    echo "${y}"
  fi
  case "$x" in
    a) echo a ;;
  esac
}
EOF
)"
  assert "${out}" == "stmt-del:3:  :
stmt-del:5:    :"
}

test_should_pair_mutants_on_different_lines_only() {
  local file out
  file="$(test::tmp_dir)/script.sh"
  printf '%s\n' '[[ 1 -eq 1 && 2 -eq 2 ]]' 'return 0' >"${file}"
  out="$(mutation::generate "${file}" "$(mutation::select_operators rel,ret)" | mutation::pairs | cut -d $'\037' -f1,2,4 | tr '\037' ':')"
  assert "${out}" == "rel-eq+ret-0:1:2
rel-eq+ret-0:1:2"
}

test_should_select_operators_by_name_or_group() {
  local out
  out="$(mutation::select_operators "str-z,ret" | cut -f1 | paste -sd,)"
  assert "${out}" == "str-z,ret-0,ret-1"
}

test_should_sample_the_same_mutants_on_every_run() {
  local first second
  first="$(seq 100 | mutation::sample 5)"
  second="$(seq 100 | mutation::sample 5)"
  assert "${second}" == "${first}"
  assert "$(wc -l <<<"${first}")" == 5
}

# Repo in <dir> with lib.sh (two behaviours) and a test that pins only one.
make_fixture_repo() {
  local -r dir="$1"
  mkdir -p "${dir}"
  cat >"${dir}/lib.sh" <<'EOF'
#!/usr/bin/env bash
is_big() { [[ "$1" -gt 10 ]]; }
is_small() { [[ "$1" -lt 3 ]]; }
EOF
  cat >"${dir}/lib.unit.test.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
is_big 11 && ! is_big 10
EOF
  git -C "${dir}" init -q
}

test_should_report_killed_and_surviving_mutants() {
  local dir out before
  dir="$(test::tmp_dir)/repo"
  make_fixture_repo "${dir}"
  before="$(cksum <"${dir}/lib.sh")"
  out="$(cd "${dir}" && "${MUTATION_SH}" -j 2 -o rel lib.sh 2>/dev/null)"
  assert "${out}" contains "| rel-lt | \`-lt\` → \`-le\` | 1 | 0 | 0 | 1 | 0 | 0.0% |"
  assert "${out}" contains "| rel-gt | \`-gt\` → \`-ge\` | 1 | 1 | 0 | 0 | 0 | 100.0% |"
  assert "${out}" contains "\`lib.sh:3\` rel-lt"
  assert "$(cksum <"${dir}/lib.sh")" == "${before}"  # the checkout is never mutated
}

test_should_kill_a_mutant_whose_test_file_exits_0_with_failed_cases() {
  local dir out
  dir="$(test::tmp_dir)/repo"
  make_fixture_repo "${dir}"
  cat >"${dir}/lib.unit.test.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
failed=0
is_small 2 && ! is_small 3 || failed=1
echo "failed=${failed}" >"${BASHX_RESULT_FILE:-/dev/null}"
EOF
  out="$(cd "${dir}" && "${MUTATION_SH}" -j 1 -o rel-lt lib.sh 2>/dev/null)"
  assert "${out}" contains "| rel-lt | \`-lt\` → \`-le\` | 1 | 1 | 0 | 0 | 0 | 100.0% |"
}

test_should_fail_under_the_minimum_score() {
  local dir rc=0
  dir="$(test::tmp_dir)/repo"
  make_fixture_repo "${dir}"
  (cd "${dir}" && "${MUTATION_SH}" -j 1 -o rel -s 60 lib.sh >/dev/null 2>&1) || rc=$?
  assert "${rc}" == 1
}

test_should_refuse_tests_that_fail_unmutated() {
  local dir rc=0 err
  dir="$(test::tmp_dir)/repo"
  make_fixture_repo "${dir}"
  echo 'exit 3' >>"${dir}/lib.unit.test.sh"
  err="$(cd "${dir}" && "${MUTATION_SH}" -j 1 lib.sh 2>&1 >/dev/null)" || rc=$?
  assert "${rc}" == 1
  assert "${err}" contains "fails before any mutation"
}

test_should_end_a_heredoc_only_at_its_terminator() {
  local out
  out="$(mutants_of bool <<'EOF'
cat <<TXT
true
true
TXT
x=true
EOF
)"
  assert "${out}" == "bool-true:5:x=false"
}

test_should_not_delete_lines_that_continue_or_open_a_block() {
  local out
  out="$(mutants_of stmt-del <<'EOF'
echo a |
  cat
echo b &&
  true
echo c ||
  true
echo d \
  e
arr=(
  1
)
{
  echo f
}
;;
  echo g ;;
:
  a)
EOF
)"
  assert "${out}" == "stmt-del:2:  :
stmt-del:4:  :
stmt-del:6:  :
stmt-del:8:  :
stmt-del:10:  :
stmt-del:13:  :"
}

# Report of a hand-made run: two tests, one survivor pair, a timeout, an
# operator pair, a long source line with backticks. The function is called
# with caller variables of the same names, which it must not read.
test_should_report_a_run_as_markdown_and_tsv() {
  local dir us pad out
  dir="$(test::tmp_dir)"
  us=$'\x1f'
  pad="$(printf 'x%.0s' {1..100})"
  mkdir -p "${dir}/sandbox-0"
  printf '%s\n' '#!/usr/bin/env bash' 'is_big() { [[ "$1" -gt 10 ]]; }' \
    "  is_small() { [[ \"\$1\" -lt 3 ]]; } # see \`x\` ${pad}" >"${dir}/sandbox-0/lib.sh"
  printf '%s\n' "1${us}rel-gt${us}2${us}is_big() { [[ \"\$1\" -ge 10 ]]; }" \
    "2${us}rel-lt${us}3${us}  is_small() { [[ \"\$1\" -le 3 ]]; }" \
    "3${us}stmt-del${us}3${us}  :" \
    "4${us}rel-gt+rel-lt${us}2${us}is_big() { [[ \"\$1\" -ge 10 ]]; }${us}3${us}  is_small() { [[ \"\$1\" -le 3 ]]; }" \
    >"${dir}/mutants"
  printf '1\tkilled\t12\n2\tsurvived\t30\n3\ttimeout\t1000\n4\tsurvived\t5\n' >"${dir}/results"

  # END shows the blank line the report ends with.
  out="$(
    # shellcheck disable=SC2034 # decoys: the function must not read them
    local workdir=/decoy script=decoy order=9 baseline_ms=1 elapsed=1 tsv=/decoy joined=/decoy tests_md=decoy
    mutation::report_script "${dir}" lib.sh 1 1234 56 "${dir}/out.tsv" tests/a.unit.test.sh b.unit.test.sh
    echo END
  )"
  assert "${out}" == "$(cat <<EOF
### \`lib.sh\`

Tests: \`a.unit.test.sh\` \`b.unit.test.sh\` (1234 ms unmutated) · order 1 · 56 s

| Operator | Mutation | Mutants | Killed | Timeout | Survived | Invalid | Score |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| rel-lt | \`-lt\` → \`-le\` | 1 | 0 | 0 | 1 | 0 | 0.0% |
| rel-gt | \`-gt\` → \`-ge\` | 1 | 1 | 0 | 0 | 0 | 100.0% |
| rel-gt+rel-lt | combination of rel-gt and rel-lt | 1 | 0 | 0 | 1 | 0 | 0.0% |
| stmt-del | command → \`:\` | 1 | 0 | 1 | 0 | 0 | 100.0% |
| **Total** |  | 4 | 1 | 1 | 2 | 0 | 50.0% |

<details><summary>Survivors (2)</summary>

- \`lib.sh:2\` rel-gt+rel-lt: \`is_big() { [[ "\$1" -gt 10 ]]; }\` → \`is_big() { [[ "\$1" -ge 10 ]]; }\`
- \`lib.sh:3\` rel-gt+rel-lt: \`is_small() { [[ "\$1" -lt 3 ]]; } # see 'x' ${pad:0:77}\` → \`is_small() { [[ "\$1" -le 3 ]]; }\`
- \`lib.sh:3\` rel-lt: \`is_small() { [[ "\$1" -lt 3 ]]; } # see 'x' ${pad:0:77}\` → \`is_small() { [[ "\$1" -le 3 ]]; }\`

</details>

END
EOF
)"
  assert "$(cat "${dir}/summary")" == "4 1 1 2 0 56"
  assert "$(sed -n 3p "${dir}/out.tsv")" == "lib.sh	3	stmt-del	timeout	1000	3	  :"
  assert "$(wc -l <"${dir}/out.tsv")" == 4

  mutation::report_script "${dir}" lib.sh 1 1234 56 "" tests/a.unit.test.sh >/dev/null
  assert "$(wc -l <"${dir}/out.tsv")" == 4  # no TSV asked: nothing appended
}

# Helpers read their arguments, never the caller's variables of the same names.
test_should_ignore_the_caller_s_variables() {
  local dir us out
  dir="$(test::tmp_dir)"
  us=$'\x1f'
  printf '%s\n' 'x() { [[ 1 -eq 1 ]]; }' >"${dir}/lib.sh"
  printf '1\trel-eq\tsurvived\t5\t1\tx() { [[ 1 -ne 1 ]]; }\n' >"${dir}/joined"
  out="$(
    # shellcheck disable=SC2034 # decoys: the functions must not read them
    local script=decoy joined=/decoy original=/decoy operators="" order=2 max=0 root=/decoy
    mutation::report_survivors lib.sh "${dir}/joined" "${dir}/lib.sh"
    mutation::mutants "${dir}/lib.sh" "$(mutation::select_operators rel-eq)" 1 0 | tr "${us}" ':'
    mutation::count "${dir}" lib.sh "$(mutation::select_operators rel-eq)"
  )"
  assert "${out}" == "
<details><summary>Survivors (1)</summary>

- \`lib.sh:1\` rel-eq: \`x() { [[ 1 -eq 1 ]]; }\` → \`x() { [[ 1 -ne 1 ]]; }\`

</details>
1:rel-eq:1:x() { [[ 1 -ne 1 ]]; }
| \`lib.sh\` | 1 | 1 | 0 |"
  : >"${dir}/none"
  out="$(mutation::report_survivors lib.sh "${dir}/none" "${dir}/lib.sh")" || { echo "    status $? without survivors" >&2; return 1; }
  assert "${out}" == ""  # no survivor: no list
}

test_should_summarise_several_scripts_only() {
  local out
  out="$(mutation::report_summary "lib.sh 8 4 1 1 2 3" "lib2.sh 2 2 0 0 0 1")"
  assert "${out}" == "### Summary

| Script | Mutants | Killed | Timeout | Survived | Invalid | Score | Time |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| \`lib.sh\` | 8 | 4 | 1 | 1 | 2 | 83.3% | 3 s |
| \`lib2.sh\` | 2 | 2 | 0 | 0 | 0 | 100.0% | 1 s |
| **Total** | 10 | 6 | 1 | 1 | 2 | 87.5% | 4 s |"
  assert "$(mutation::report_summary "lib.sh 1 1 0 0 0 1")" == ""
}

test_should_compare_the_score_to_the_minimum() {
  local row rc results=""
  for row in "10 5 2 3 0 1|" "10 5 2 3 0 1|70" "10 5 2 3 0 1|71" "3 0 0 0 3 1|90"; do
    rc=0
    mutation::below_min_score "${row%|*}" "${row#*|}" || rc=$?
    results+="${rc}"
  done
  assert "${results}" == "0010"
}

test_should_give_slow_tests_a_longer_deadline() {
  local ms results=""
  for ms in 0 1666 2000 2001; do results+="$(mutation::deadline "${ms}") "; done
  assert "${results}" == "10 10 11 12 "
}

test_should_apply_one_or_two_mutations() {
  local dir
  dir="$(test::tmp_dir)"
  printf 'a\nb\nc\n' >"${dir}/orig"
  mutation::apply "${dir}/orig" "${dir}/one" 2 B
  mutation::apply "${dir}/orig" "${dir}/two" 1 A 3 C
  assert "$(paste -sd' ' "${dir}/one")|$(paste -sd' ' "${dir}/two")" == "a B c|A b C"
}

test_should_find_the_script_s_own_tests() {
  local dir out
  dir="$(test::tmp_dir)"
  touch "${dir}/a.sh" "${dir}/a.test.sh" "${dir}/a.unit.test.sh" "${dir}/a.integration.test.sh" "${dir}/b.unit.test.sh" "${dir}/ab.test.sh"
  out="$(
    # shellcheck disable=SC2034 # decoy: the function must not read it
    local script=b.sh
    cd "${dir}" && mutation::own_tests a.sh
  )"
  assert "${out}" == "a.test.sh
a.integration.test.sh
a.unit.test.sh"
}

test_should_copy_tracked_and_untracked_files_into_a_sandbox() {
  local dir
  dir="$(test::tmp_dir)"
  mkdir -p "${dir}/repo"
  git -C "${dir}/repo" init -q
  echo ignored.txt >"${dir}/repo/.gitignore"
  touch "${dir}/repo/tracked.sh" "${dir}/repo/untracked.sh" "${dir}/repo/ignored.txt"
  git -C "${dir}/repo" add tracked.sh .gitignore
  mutation::sandbox "${dir}/repo" "${dir}/box"
  assert "$(git -C "${dir}/box" ls-files | paste -sd' ')" == ".gitignore tracked.sh untracked.sh"
  assert "$(git -C "${dir}/box" rev-parse --show-toplevel)" == "$(cd "${dir}/box" && pwd -P)"
  assert "$(git -C "${dir}/box" rev-list --count HEAD)" == 1
}

test_should_read_a_test_s_exit_deadline_and_result_file() {
  local dir out=""
  dir="$(test::tmp_dir)"
  echo 'exit 0' >"${dir}/pass.sh"
  echo 'exit 3' >"${dir}/fail.sh"
  echo 'sleep 5' >"${dir}/slow.sh"
  echo 'echo failed=1 >"${BASHX_RESULT_FILE}"' >"${dir}/swallowed.sh"
  local t
  for t in pass fail slow swallowed pass; do out+="$(mutation::run_test "${dir}" 1 "${t}.sh") "; done
  assert "${out}" == "0 3 124 1 0 "  # a result file is not read by the next test
}

test_should_print_progress_while_workers_run() {
  local dir pid err
  dir="$(test::tmp_dir)"
  sleep 1.5 &
  pid=$!
  echo 1 >"${dir}/results.0"
  err="$(MUTATION_PROGRESS_EVERY=1 mutation::progress 5 "${dir}/results" "${pid}" 2>&1)"
  assert "$(head -1 <<<"${err}")" == "mutation: 1/5"
  sleep 1.5 &
  pid=$!
  assert "$(mutation::progress 5 "${dir}/results" "${pid}" 2>&1)" == ""  # every 10 s by default
}

test_should_list_the_operators() {
  local out
  out="$("${MUTATION_SH}" -L)"
  assert "$(wc -l <<<"${out}")" == 31
  assert "$(head -1 <<<"${out}")" == "| Operator | Mutation | Only on lines matching |"
  assert "${out}" contains "| logic-or | \`\\|\\|\` → \`&&\` |  |"
  assert "${out}" contains "| arith-lt | \`<\` → \`<=\` | \`\\(\\(\` |"
  assert "${out}" contains "| stmt-del | command → \`:\` |  |"
}

# Repo in <dir>: lib.sh (a killed, a surviving, a looping and two unparsable
# mutants with -o rel,stmt-del), lib2.sh (all killed), their colocated tests.
make_cli_repo() {
  local -r dir="$1"
  mkdir -p "${dir}"
  cat >"${dir}/lib.sh" <<'EOF'
#!/usr/bin/env bash
is_big() { [[ "$1" -gt 10 ]]; }
is_small() { [[ "$1" -lt 3 ]]; }
spin() { while [[ "$1" -eq 1 ]]; do :; done; }
msg="first
second"
EOF
  echo 'source ./lib.sh; is_big 11 && ! is_big 10 && is_small 1 && spin 0' >"${dir}/lib.unit.test.sh"
  cat >"${dir}/lib2.sh" <<'EOF'
#!/usr/bin/env bash
half() { echo $(($1 / 2)); }
double() { echo $(($1 * 2)); }
EOF
  # Checks lib.sh too: the last lib.sh mutant must have been undone.
  cksum <"${dir}/lib.sh" >"${dir}/lib.sum"
  echo '[[ "$(cksum <lib.sh)" == "$(cat lib.sum)" ]] || exit 1; source ./lib2.sh; [[ "$(half 4) $(double 4)" == "2 8" ]]' >"${dir}/lib2.unit.test.sh"
  git -C "${dir}" init -q
}

test_should_count_mutants_and_pairs_in_a_dry_run() {
  local dir out
  dir="$(test::tmp_dir)/repo"
  make_cli_repo "${dir}"
  out="$(cd "${dir}" && "${MUTATION_SH}" -n -o rel,stmt-del lib.sh lib2.sh)"
  assert "${out}" == "| Script | Lines | Mutants (order 1) | Pairs (order 2) |
| --- | ---: | ---: | ---: |
| \`lib.sh\` | 6 | 8 | 25 |
| \`lib2.sh\` | 3 | 2 | 1 |"
}

test_should_refuse_bad_options_with_usage() {
  local dir row args want rc out
  dir="$(test::tmp_dir)/repo"
  make_cli_repo "${dir}"
  for row in "-k 3 lib.sh|2" "-m x lib.sh|2" "-j 0 lib.sh|2" "|2" "-q lib.sh|2" "-o nomatch lib.sh|2" "-h|0"; do
    args="${row%|*}" want="${row#*|}" rc=0
    # shellcheck disable=SC2086 # args split on purpose
    out="$(cd "${dir}" && "${MUTATION_SH}" -j 1 ${args} 2>&1)" || rc=$?
    echo "exit code of '${args}': ${out}"
    assert "${rc}" == "${want}"
  done
  out="$(cd "${dir}" && "${MUTATION_SH}" -h)"
  assert "${out}" contains "Usage:"
  out="$(cd "${dir}" && "${MUTATION_SH}" -o nomatch lib.sh 2>&1)" || true
  assert "${out}" contains "error: no operator matches -o nomatch"
  echo 'x() { :; }' >"${dir}/untested.sh"
  rc=0
  out="$(cd "${dir}" && "${MUTATION_SH}" -j 1 untested.sh 2>&1)" || rc=$?
  assert "${rc}" == "2"
  assert "${out}" contains "error: no test for untested.sh: pass -t <test>"
}

# Full run on two scripts: every status, the summary, the TSV, the minimum
# score, progress on stderr; nothing left in TMPDIR, the checkout untouched.
test_should_run_every_mutant_of_several_scripts() {
  local dir tmpdir before out err rc=0 ms
  dir="$(test::tmp_dir)/repo"
  tmpdir="$(test::tmp_dir)/tmp"
  mkdir -p "${tmpdir}"
  make_cli_repo "${dir}"
  before="$(cat "${dir}"/*.sh | cksum)"
  out="$(cd "${dir}" && TMPDIR="${tmpdir}" MUTATION_PROGRESS_EVERY=1 "${MUTATION_SH}" \
    -j 2 -T 1 -s 90 -o rel,stmt-del,arith -r "${tmpdir}/../out.tsv" lib.sh lib2.sh 2>"${tmpdir}/../err")" || rc=$?
  err="$(cat "${tmpdir}/../err")"
  echo "lib.sh scores under 90 %: ${err}"
  assert "${rc}" == 1
  assert "$(head -1 <<<"${out}")|$(sed -n 2p <<<"${out}")" == "## Mutation testing|"
  assert "${out}" contains "| rel-eq | \`-eq\` → \`-ne\` | 1 | 0 | 1 | 0 | 0 | 100.0% |"
  assert "${out}" contains "| stmt-del | command → \`:\` | 5 | 3 | 0 | 0 | 2 | 100.0% |"
  assert "${out}" contains "| **Total** |  | 8 | 4 | 1 | 1 | 2 | 83.3% |"
  assert "${out}" contains "- \`lib.sh:3\` rel-lt: \`is_small() { [[ \"\$1\" -lt 3 ]]; }\` → \`is_small() { [[ \"\$1\" -le 3 ]]; }\`"
  assert "${out}" contains "| \`lib2.sh\` | 4 | 4 | 0 | 0 | 0 | 100.0% |"
  assert "${out}" contains "| **Total** | 12 | 8 | 1 | 1 | 2 | 90.0% |"
  local secs
  read -r ms secs < <(sed -n 's/^Tests: `lib.unit.test.sh` (\([0-9]*\) ms unmutated) · order 1 · \([0-9]*\) s$/\1 \2/p' <<<"${out}")
  [[ "${ms}" =~ ^[0-9]+$ ]] && ((ms > 0 && ms < 60000)) || { echo "    baseline: '${ms}'" >&2; return 1; }
  [[ "${secs}" =~ ^[0-9]+$ ]] && ((secs < 600)) || { echo "    elapsed: '${secs}'" >&2; return 1; }
  # lib2.sh starts after lib.sh (a 1 s timeout) and runs four quick mutants:
  # its time is its own, not counted from the start of the run.
  local lib_secs lib2_secs
  lib_secs="$(sed -n 's/^| `lib.sh` |.* | \([0-9]*\) s |$/\1/p' <<<"${out}")"
  lib2_secs="$(sed -n 's/^| `lib2.sh` |.* | \([0-9]*\) s |$/\1/p' <<<"${out}")"
  ((lib2_secs <= lib_secs)) || { echo "    lib2.sh ${lib2_secs} s > lib.sh ${lib_secs} s" >&2; return 1; }

  assert "${err}" contains "mutation: copying the repo into 2 sandboxes"
  assert "${err}" contains "mutation: lib.sh: 8 mutants, 2 jobs, tests"
  [[ "${err}" =~ mutation:\ [0-9]+/8 ]] || { echo "    no progress line: ${err}" >&2; return 1; }

  assert "$(head -1 "${tmpdir}/../out.tsv")" == "script	id	operator	status	ms	line	text"
  assert "$(tail -n +2 "${tmpdir}/../out.tsv" | wc -l)" == 12
  awk -F'\t' 'NR > 1 && !($5 ~ /^[0-9]+$/ && $5 < 60000) { bad = 1 } END { exit bad }' "${tmpdir}/../out.tsv" \
    || { echo "    ms column out of range" >&2; return 1; }
  assert "$(ls -A "${tmpdir}")" == ""  # work dir removed
  assert "$(cat "${dir}"/*.sh | cksum)" == "${before}"  # the checkout is never mutated
}

test_should_run_sampled_pairs_against_the_given_test() {
  local dir out
  dir="$(test::tmp_dir)/repo"
  make_cli_repo "${dir}"
  mv "${dir}/lib2.unit.test.sh" "${dir}/check2.sh"
  out="$(cd "${dir}" && "${MUTATION_SH}" -j 1 -k 2 -m 2 -o arith,stmt-del -t check2.sh lib2.sh 2>/dev/null)"
  assert "${out}" !contains "<details>"  # no survivor, no survivor list
  assert "${out}" contains "Tests: \`check2.sh\` ("
  assert "${out}" contains "· order 2 ·"
  assert "${out}" contains "| **Total** |  | 2 | 2 | 0 | 0 | 0 | 100.0% |"
  assert "${out}" contains "combination of"
}

main() {
  # shellcheck source=mutation.sh
  # shellcheck disable=SC1090,SC1091
  source "${MUTATION_SH}"

  test::run "should ignore the caller's variables" test_should_ignore_the_caller_s_variables
  test::run "should find the script's own tests" test_should_find_the_script_s_own_tests
  test::run "should read a test's exit deadline and result file" test_should_read_a_test_s_exit_deadline_and_result_file
  test::main
}

main "$@"
