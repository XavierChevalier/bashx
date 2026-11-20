#!/usr/bin/env bash
# Line coverage of a project's bash scripts by its test suite.
#
# `bashx test --coverage=DIR` traces every bash process the tests start
# (coverage-trace.bash). This script turns those traces into covered lines and
# a score over the project's scripts (*.sh, minus tests and fixtures).
#
# A "line" is one statement start: a command split over several lines
# (continuation, multi-line quote or array, heredoc) counts once, on its first
# line, whatever line xtrace reports for it. Structural lines (then, fi, done,
# }, case patterns, function headers) never count. Approximate like any bash
# coverage, but stable from one run to the next: the trend is what matters.
# See docs/coverage.md.
set -o errexit -o pipefail -o nounset

function usage() {
  cat <<USAGE
Usage: bashx coverage report [-r <root>] [-x <regex>] [-f summary|markdown|tsv|uncovered] <covered.tsv>...
       bashx coverage covered [-r <root>] <trace dir>

  report   score the union of covered.tsv files (from bashx test --coverage)
           against the project's scripts
           summary:   covered=<n> coverable=<n> pct=<n.n>  (default)
           markdown:  one line for a PR comment
           tsv:       path, covered, coverable per script
           uncovered: "<path>:<line>: <code>" for every line no test ran
  covered  print "<path>\t<line>" for every project line the traces ran
  -r       project root (default: git root of the current directory, or it)
  -x       also leave out scripts whose path matches this extended regex
           (tests and fixtures/ are always left out)
USAGE
}

# Scripts the score is about: *.sh files git knows or would track (every
# *.sh outside git),
# minus tests, fixtures/ and paths matching <exclude>.
# Usage: coverage::scripts <root> [<exclude regex>]
function coverage::scripts() {
  local -r root="$1" exclude="${2:-}"
  {
    git -C "${root}" ls-files -co --exclude-standard -- '*.sh' 2>/dev/null \
      || (cd "${root}" && find . -name '*.sh' -not -path '*/.git/*' | sed 's|^\./||')
  } | grep -vE '\.test\.sh$|(^|/)fixtures/' | { [[ -z "${exclude}" ]] && cat || grep -vE "${exclude}"; } || true
}

# For every line of a script: "<line>\t<statement start>\t<coverable 0|1>".
# Usage: coverage::lines <file>
function coverage::lines() {
  awk '
    BEGIN { sq = "\047" }
    {
      inside = (heredoc != "" || quote != "" || cont || array)
      if (!inside) start = NR
      if (heredoc != "") {
        t = $0; sub(/^[ \t]+/, "", t)
        if (t == heredoc) heredoc = ""
        print NR "\t" start "\t0"
        next
      }
      code = scan($0)
      t = code; gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (array && t ~ /^\)/) array = 0
      else if (!inside && quote == "" && t ~ /=\($/) array = 1
      cont = (quote == "" && t ~ /\\$/)
      if (quote == "" && code !~ /<<</ && match(code, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
        heredoc = substr(code, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*["\047]?/, "", heredoc)
      }
      print NR "\t" start "\t" ((!inside && coverable(t)) ? 1 : 0)
    }
    # Code part of the line (comment dropped), updating the open quote.
    function scan(line,   i, c, n, out) {
      n = length(line); out = ""
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (quote == sq) { if (c == sq) quote = ""; out = out c; continue }
        if (quote == "\"") {
          if (c == "\\") { out = out substr(line, i, 2); i++; continue }
          if (c == "\"") quote = ""
          out = out c; continue
        }
        if (c == "\\") { out = out substr(line, i, 2); i++; continue }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;]/)) break
        if (c == sq || c == "\"") quote = c
        out = out c
      }
      return out
    }
    function coverable(t) {
      if (t == "" || (NR == 1 && t ~ /^#!/)) return 0
      if (t ~ /^(then|else|fi|do|done|esac|in|\{|\}|\(|\)|;;|;&|;;&)( *[;|&<>].*)?$/) return 0
      if (t ~ /^(function[ \t]+[^ \t(]+|[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\))[ \t]*(\(\))?[ \t]*[{(]?$/) return 0
      if (t ~ /^[^()]*\)$/) return 0
      return 1
    }
  ' "$1"
}

# Usage: coverage::covered <root> <trace dir>
function coverage::covered() {
  local -r root="$1" traces="$2"
  [[ -d "${traces}" ]] || {
    echo "no trace dir ${traces}" >&2
    return 1
  }
  # Relative paths are resolved against the directory each process started in
  # (its "#cwd" line), or against the root without one.
  find "${traces}" -type f -name '*.trace' -print0 |
    xargs -0 -r awk -v root="${root%/}/" '
      FNR == 1 { cwd = "" }
      FNR == 1 && /^#cwd / { cwd = substr($0, 6); next }
      match($0, /^\++[^:]+:[0-9]+: /) {
        loc = substr($0, 1, RLENGTH - 2); sub(/^\++/, "", loc)
        n = split(loc, p, ":"); line = p[n]; path = substr(loc, 1, length(loc) - length(line) - 1)
        if (path !~ /^\//) path = normalize((cwd != "" ? cwd : root) "/" path)
        if (index(path, root) == 1) path = substr(path, length(root) + 1)
        else next
        if (!seen[path "\t" line]++) print path "\t" line
      }
      # /a/./b/../c -> /a/c
      function normalize(path,   n, parts, out, i, k) {
        n = split(path, parts, "/"); k = 0
        for (i = 1; i <= n; i++) {
          if (parts[i] == "" || parts[i] == ".") continue
          if (parts[i] == "..") { if (k > 0) k--; continue }
          out[++k] = parts[i]
        }
        path = ""
        for (i = 1; i <= k; i++) path = path "/" out[i]
        return path
      }'
}

# Usage: coverage::report <root> <format> <exclude regex> <covered.tsv>...
function coverage::report() {
  local -r root="$1" format="$2" exclude="$3"
  shift 3
  local script
  # "<path>\t<line>\t<statement start>\t<coverable>" for every tracked line.
  local -r table="$(mktemp)"
  # shellcheck disable=SC2064 # expand now: the local is gone at RETURN time
  trap "rm -f '${table}'" RETURN
  while IFS= read -r script; do
    [[ -f "${root}/${script}" ]] || continue
    coverage::lines "${root}/${script}" | awk -v s="${script}" '{ print s "\t" $0 }'
  done < <(coverage::scripts "${root}" "${exclude}") >"${table}"
  awk -F'\t' -v table="${table}" -v format="${format}" -v root="${root}" '
    FILENAME != table { ran[$1 "\t" $2] = 1; next }
    ran[$1 "\t" $2] { hit[$1 "\t" $3] = 1 }
    $4 == 1 { line[$1 "\t" $2] = $1; coverable[$1]++ }
    END {
      for (k in line) { total++; if (hit[k]) { covered[line[k]]++; done++ } }
      pct = total ? 100 * done / total : 0
      if (format == "uncovered") {
        for (k in line) if (!hit[k]) { split(k, p, "\t"); missing[p[1]] = missing[p[1]] " " p[2] " " }
        for (s in missing) {
          n = 0
          while ((getline text < (root "/" s)) > 0) {
            n++
            if (index(missing[s], " " n " ")) { sub(/^[ \t]+/, "", text); print s ":" n ": " text }
          }
          close(root "/" s)
        }
      } else if (format == "tsv") {
        print "path\tcovered\tcoverable"
        for (s in coverable) print s "\t" (covered[s] + 0) "\t" coverable[s]
      } else if (format == "markdown") {
        printf "**Coverage:** %.1f%% of bash lines (%d/%d)\n", pct, done, total
      } else {
        printf "covered=%d coverable=%d pct=%.1f\n", done, total, pct
      }
    }' "$@" "${table}"
}

function main() {
  local -r cmd="${1:-}"
  [[ -n "${cmd}" ]] || {
    usage
    return 1
  }
  shift
  local root="" format="summary" exclude="" opt
  OPTIND=1
  while getopts "r:f:x:h" opt; do
    case "${opt}" in
      r) root="${OPTARG}" ;;
      x) exclude="${OPTARG}" ;;
      f) format="${OPTARG}" ;;
      h)
        usage
        return 0
        ;;
      *)
        usage
        return 1
        ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "${root}" ]] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  root="$(cd "${root}" && pwd)"
  case "${cmd}" in
    covered)
      [[ $# -eq 1 ]] || {
        usage
        return 1
      }
      coverage::covered "${root}" "$1"
      ;;
    report)
      [[ $# -ge 1 ]] || {
        usage
        return 1
      }
      case "${format}" in
        summary | markdown | tsv | uncovered) ;;
        *)
          echo "unknown format ${format}" >&2
          return 1
          ;;
      esac
      if [[ "${format}" == uncovered ]]; then
        coverage::report "${root}" "${format}" "${exclude}" "$@" | LC_ALL=C sort -t: -k1,1 -k2,2n
      else
        coverage::report "${root}" "${format}" "${exclude}" "$@"
      fi
      ;;
    -h | --help) usage ;;
    *)
      usage
      return 1
      ;;
  esac
}

[[ "${BASH_SOURCE[0]}" != "${0}" ]] || main "$@"
