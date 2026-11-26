#!/usr/bin/env bash
set -euo pipefail

# Tests of mutation testing (bashx mutate).
source "$(dirname "${BASH_SOURCE[0]}")/bashx.sh"

BASHX="${BASHX_BIN:-bashx}"

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
  out="$(cd "${dir}" && "${BASHX}" mutate -j 2 -o rel lib.sh 2>/dev/null)"
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
  out="$(cd "${dir}" && "${BASHX}" mutate -j 1 -o rel-lt lib.sh 2>/dev/null)"
  assert "${out}" contains "| rel-lt | \`-lt\` → \`-le\` | 1 | 1 | 0 | 0 | 0 | 100.0% |"
}

test_should_fail_under_the_minimum_score() {
  local dir rc=0
  dir="$(test::tmp_dir)/repo"
  make_fixture_repo "${dir}"
  (cd "${dir}" && "${BASHX}" mutate -j 1 -o rel -s 60 lib.sh >/dev/null 2>&1) || rc=$?
  assert "${rc}" == 1
}

test_should_refuse_tests_that_fail_unmutated() {
  local dir rc=0 err
  dir="$(test::tmp_dir)/repo"
  make_fixture_repo "${dir}"
  echo 'exit 3' >>"${dir}/lib.unit.test.sh"
  err="$(cd "${dir}" && "${BASHX}" mutate -j 1 lib.sh 2>&1 >/dev/null)" || rc=$?
  assert "${rc}" == 1
  assert "${err}" contains "fails before any mutation"
}

test_should_list_the_operators() {
  local out
  out="$("${BASHX}" mutate -L)"
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
  out="$(cd "${dir}" && "${BASHX}" mutate -n -o rel,stmt-del lib.sh lib2.sh)"
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
    out="$(cd "${dir}" && "${BASHX}" mutate -j 1 ${args} 2>&1)" || rc=$?
    echo "exit code of '${args}': ${out}"
    assert "${rc}" == "${want}"
  done
  out="$(cd "${dir}" && "${BASHX}" mutate -h)"
  assert "${out}" contains "Usage:"
  out="$(cd "${dir}" && "${BASHX}" mutate -o nomatch lib.sh 2>&1)" || true
  assert "${out}" contains "error: no operator matches -o nomatch"
  echo 'x() { :; }' >"${dir}/untested.sh"
  rc=0
  out="$(cd "${dir}" && "${BASHX}" mutate -j 1 untested.sh 2>&1)" || rc=$?
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
  out="$(cd "${dir}" && TMPDIR="${tmpdir}" MUTATION_PROGRESS_EVERY=1 "${BASHX}" mutate \
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
  out="$(cd "${dir}" && "${BASHX}" mutate -j 1 -k 2 -m 2 -o arith,stmt-del -t check2.sh lib2.sh 2>/dev/null)"
  assert "${out}" !contains "<details>"  # no survivor, no survivor list
  assert "${out}" contains "Tests: \`check2.sh\` ("
  assert "${out}" contains "· order 2 ·"
  assert "${out}" contains "| **Total** |  | 2 | 2 | 0 | 0 | 0 | 100.0% |"
  assert "${out}" contains "combination of"
}

test::main
