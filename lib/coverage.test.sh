#!/usr/bin/env bash
set -euo pipefail

# Tests of line coverage (bashx coverage).
source "$(dirname "${BASH_SOURCE[0]}")/bashx.sh"

COVERAGE_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coverage.sh"
# shellcheck source=coverage.sh
# shellcheck disable=SC1090,SC1091
source "${COVERAGE_SH}"

# Script with every multi-line shape, numbered in the comments below.
write_sample() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
f() {
  local x=1
  echo a \
    b
  arr=(
    one
  )
  awk '
    { print }
  ' <<<"z"
  if [[ "${x}" -eq 1 ]]; then
    echo yes # trailing comment
  else
    echo no
  fi
  case "${x}" in
    1) echo one ;;
    *)
      echo other
      ;;
  esac
  cat <<X
body
X
}
f
EOF
}

test_should_count_each_statement_once_on_its_first_line() {
  local dir
  dir="$(test::tmp_dir)"
  write_sample "${dir}/s.sh"
  local -r coverable="$(coverage::lines "${dir}/s.sh" | awk -F'\t' '$3 == 1 { printf "%s ", $1 }')"
  # Not: shebang, f() {, continuation (5), array body (7-8), awk body (10-11),
  # then/else/fi, case patterns (19), ;;, esac, heredoc body, }.
  assert "${coverable}" == "3 4 6 9 12 13 15 17 18 20 23 27 "
  # A line xtrace reports inside a statement maps to its first line.
  assert "$(coverage::lines "${dir}/s.sh" | awk -F'\t' '$1 == 8 { print $2 }')" == "6"
  assert "$(coverage::lines "${dir}/s.sh" | awk -F'\t' '$1 == 11 { print $2 }')" == "9"
}

test_should_cover_what_xtrace_reports_for_the_sample() {
  local dir
  dir="$(test::tmp_dir)"
  git -C "${dir}" init -q
  write_sample "${dir}/s.sh"
  git -C "${dir}" add s.sh
  mkdir "${dir}/traces"
  # Through the real tracer: as root, bash ignores a PS4 from the environment.
  (cd "${dir}" && BASH_ENV="$(dirname "${COVERAGE_SH}")/coverage-trace.bash" \
    BASHX_COVERAGE_TRACE_DIR="${dir}/traces" bash s.sh >/dev/null)
  bash "${COVERAGE_SH}" covered -r "${dir}" "${dir}/traces" >"${dir}/covered.tsv"
  # Everything but the two branches not taken (else, *) ran.
  echo "trace: $(cat "${dir}"/traces/*.trace | head -5 | tr '\n' '|') covered: $(tr '\n\t' '| ' <"${dir}/covered.tsv")"
  assert "$(bash "${COVERAGE_SH}" report -r "${dir}" "${dir}/covered.tsv")" == "covered=10 coverable=12 pct=83.3"
  assert "$(bash "${COVERAGE_SH}" report -r "${dir}" -f tsv "${dir}/covered.tsv" | tail -n +2)" == "s.sh	10	12"
}

test_should_map_trace_paths_to_the_repo_and_drop_the_rest() {
  local dir
  dir="$(test::tmp_dir)"
  mkdir "${dir}/traces"
  printf '%s\n' \
    "+${dir}/a.sh:3: echo" \
    "+++./b.sh:7: true" \
    "+c.sh:1: x" \
    "+${dir}/a.sh:3: echo again" \
    "+/elsewhere/d.sh:2: y" \
    "not a trace line" >"${dir}/traces/9.trace"
  assert "$(coverage::covered "${dir}" "${dir}/traces")" == "a.sh	3
b.sh	7
c.sh	1"
}

# Each trace starts with the directory its process started in: relative paths
# (`source ./lib.sh` from a test's own directory) resolve against it.
test_should_resolve_relative_paths_against_the_process_directory() {
  local dir
  dir="$(test::tmp_dir)"
  # A root spelled with "//" (macOS TMPDIR ends in "/") still matches.
  dir="${dir%/*}//${dir##*/}"
  mkdir "${dir}/traces"
  printf '%s\n' "#cwd ${dir}/sub" "+./x.sh:2: a" "+../y.sh:5: b" "+${dir}/z.sh:1: c" >"${dir}/traces/1.trace"
  printf '%s\n' "#cwd /elsewhere" "+./w.sh:1: d" >"${dir}/traces/2.trace"
  assert "$(coverage::covered "${dir}" "${dir}/traces" | sort)" == "sub/x.sh	2
y.sh	5
z.sh	1"
}

test_should_leave_out_scripts_matching_an_exclusion() {
  local dir
  dir="$(test::tmp_dir)"
  mkdir -p "${dir}/lib" "${dir}/vendor"
  printf 'echo 1\necho 2\n' >"${dir}/lib/a.sh"
  printf 'echo 1\n' >"${dir}/vendor/v.sh"
  printf 'lib/a.sh\t1\n' >"${dir}/covered.tsv"
  # Not a git repository: every *.sh counts.
  assert "$(bash "${COVERAGE_SH}" report -r "${dir}" "${dir}/covered.tsv")" == "covered=1 coverable=3 pct=33.3"
  assert "$(bash "${COVERAGE_SH}" report -r "${dir}" -x '^vendor/' "${dir}/covered.tsv")" == "covered=1 coverable=2 pct=50.0"
}

test_should_score_the_union_of_several_covered_files_and_skip_tests() {
  local dir
  dir="$(test::tmp_dir)"
  git -C "${dir}" init -q
  mkdir -p "${dir}/lib/fixtures"
  printf 'echo 1\necho 2\necho 3\necho 4\n' >"${dir}/lib/a.sh"
  printf 'echo 1\n' | tee "${dir}/lib/a.unit.test.sh" >"${dir}/lib/fixtures/fake.sh"
  git -C "${dir}" add -A
  printf 'lib/a.sh\t1\nlib/a.unit.test.sh\t1\n' >"${dir}/shard1.tsv"
  printf 'lib/a.sh\t1\nlib/a.sh\t4\n' >"${dir}/shard2.tsv"
  assert "$(bash "${COVERAGE_SH}" report -r "${dir}" "${dir}/shard1.tsv" "${dir}/shard2.tsv")" == "covered=2 coverable=4 pct=50.0"
  assert "$(bash "${COVERAGE_SH}" report -r "${dir}" -f markdown "${dir}/shard1.tsv" "${dir}/shard2.tsv")" == "**Coverage:** 50.0% of bash lines (2/4)"
}

test_should_list_the_lines_no_test_ran() {
  local dir
  dir="$(test::tmp_dir)"
  mkdir -p "${dir}/lib"
  printf '%s\n' 'a() {' '  echo a' '}' 'b() {' '    echo b' '  return 1' '}' >"${dir}/lib/x.sh"
  printf 'echo z\n' >"${dir}/y.sh"
  printf 'lib/x.sh\t2\n' >"${dir}/covered.tsv"
  assert "$(bash "${COVERAGE_SH}" report -r "${dir}" -f uncovered "${dir}/covered.tsv")" == "lib/x.sh:5: echo b
lib/x.sh:6: return 1
y.sh:1: echo z"
}

# A project vendoring bashx scores its own scripts, not bashx's.
test_should_leave_a_vendored_bashx_out() {
  local dir
  dir="$(test::tmp_dir)"
  mkdir -p "${dir}/vendor/bashx"
  cp -R "$(dirname "${COVERAGE_SH}")" "${dir}/vendor/bashx/lib"
  printf 'echo a\n' >"${dir}/app.sh"
  printf 'app.sh\t1\n' >"${dir}/covered.tsv"
  assert "$(bash "${dir}/vendor/bashx/lib/coverage.sh" report -r "${dir}" "${dir}/covered.tsv")" == "covered=1 coverable=1 pct=100.0"
}

test_should_refuse_an_unknown_command_or_format() {
  local rc=0
  bash "${COVERAGE_SH}" nope >/dev/null 2>&1 || rc=$?
  assert "${rc}" == 1
  rc=0
  bash "${COVERAGE_SH}" report -f xml /dev/null >/dev/null 2>&1 || rc=$?
  assert "${rc}" == 1
}

function main() {
  test::main
}

main "$@"
