[Documentation](README.md) › Mutation testing

# Mutation testing

Coverage says a line ran. Mutation testing says a test would notice if it
were wrong. `bashx mutate` changes one operator of a script at a time (a
*mutant*: `-gt` → `-ge`, `&&` → `||`, a command deleted…), runs the script's
tests against it, and counts what they catch.

Every option is in the [command line reference](cli.md#bashx-mutate).

```bash
bashx mutate lib/backup.sh                       # one script, its own tests
bashx mutate lib/*.sh                            # several, with a summary table
bashx mutate -n lib/*.sh                         # count the mutants, run nothing
bashx mutate -o rel,logic -s 90 lib/backup.sh    # some operators, fail under 90 %
bashx mutate -k 2 -m 300 lib/backup.sh           # pairs of mutations, 300 sampled
bashx mutate -L                                  # the operators
```

## Results

| Status | Meaning |
| --- | --- |
| killed | a test failed: the behaviour is pinned |
| timeout | a test ran past its deadline (3 × the unmutated run + 5 s, at least 10 s); counts as killed |
| survived | every test passed: no test checks this, or the mutant is equivalent |
| invalid | the mutant does not parse (`bash -n`); left out of the score |

Score = (killed + timeout) / (killed + timeout + survived).

The report is Markdown: one row per operator, the survivors with their line,
and a summary when there are several scripts.

```text
| Operator | Mutation | Mutants | Killed | Timeout | Survived | Invalid | Score |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| rel-gt | `-gt` → `-ge` | 4 | 4 | 0 | 0 | 0 | 100.0% |
| stmt-del | command → `:` | 12 | 11 | 0 | 1 | 0 | 91.7% |
| **Total** |  | 16 | 15 | 0 | 1 | 0 | 93.8% |

- `lib/calc.sh:42` stmt-del: `echo "calc: not an integer" >&2` → `:`
```

## Which tests run

By default the script's own tests: `<dir>/<name>.test.sh` and
`<dir>/<name>.*.test.sh`. Give others with `-t` (repeatable). They must pass
on the unmodified script first.

## How it runs

- Each job (`-j`, default: CPU count) works in its own copy of the project
  (files git tracks, plus untracked ones that are not ignored), committed in
  a fresh git repo so `git` commands in tests still work. Your working tree
  is never written to; the copies are deleted at the end.
- A mutant stops at the first test file that fails.
- Only code is mutated: comments, trailing comments and heredoc bodies are
  left alone.

## Operators

| Operator | Mutation | Only on lines matching |
| --- | --- | --- |
| rel-eq | `-eq` → `-ne` |  |
| rel-ne | `-ne` → `-eq` |  |
| rel-lt | `-lt` → `-le` |  |
| rel-le | `-le` → `-lt` |  |
| rel-gt | `-gt` → `-ge` |  |
| rel-ge | `-ge` → `-gt` |  |
| str-eq | `==` → `!=` |  |
| str-ne | `!=` → `==` |  |
| str-z | `-z` → `-n` |  |
| str-n | `-n` → `-z` |  |
| arith-lt | `<` → `<=` | `((` |
| arith-le | `<=` → `<` | `((` |
| arith-gt | `>` → `>=` | `((` |
| arith-ge | `>=` → `>` | `((` |
| arith-add | `+` → `-` | `((` |
| arith-sub | `-` → `+` | `((` |
| arith-mul | `*` → `/` | `((` |
| arith-div | `/` → `*` | `((` |
| arith-mod | `%` → `*` | `((` |
| arith-incr | `++` → `--` |  |
| cond-neg | `[[` → `[[ !` |  |
| cond-drop-neg | `! ` → nothing |  |
| logic-and | `&&` → `\|\|` |  |
| logic-or | `\|\|` → `&&` |  |
| ret-0 | `return 0` / `exit 0` → `1` |  |
| ret-1 | `return 1` / `exit 1` → `0` |  |
| bool-true | `true` → `false` |  |
| bool-false | `false` → `true` |  |
| stmt-del | a command → `:` |  |

`-o` takes names or groups: `-o rel,logic,stmt-del`.

## Reading survivors

A survivor is one of two things:

1. **A missing test.** The behaviour can change and nothing notices. Add the
   case that kills it: an assertion on the message, the boundary value, the
   branch never taken.
2. **An equivalent mutant.** The change cannot be observed. For example
   `[[ ${n} -lt 0 ]] && n=0` → `-le`: for 0 it also sets 0. Mark the line so
   it is no longer mutated, with the reason:

   ```bash
   [[ ${n} -lt 0 ]] && n=0 # no-mutate: -le also yields 0 for 0
   ```

Before marking a line, check whether the code can be simpler: a branch whose
mutation nothing can observe is often a branch that is not needed.

`stmt-del` survivors on log lines are common: decide line by line whether the
message is part of the contract (then assert on it).

## Pairs (`-k 2`)

`-k 2` applies two mutations at once, on two different lines. There are about
n²/2 pairs for n mutants (`-n` prints both counts), so sample them with `-m`.
Pairs are almost always killed when their single mutations are (the coupling
effect): they cost a lot and rarely find more. Use them as a spot check.

## Cost

Every mutant runs the tests once. With `m` mutants, tests taking `t` seconds
and `j` jobs, a run takes about `m × t / j`. Keep the tests of a script fast,
run mutation on the scripts that matter, and use `-o` and `-m` to try it out.

## Limits

- Line-based: an operator inside a string literal (`echo "a && b"`) is also
  mutated. Such mutants usually survive; mark the line if it matters.
- Needs a git repository and GNU `timeout`, `shuf`, `realpath`.

---

Previous: [Coverage](coverage.md) · Next: [CI](ci.md)
