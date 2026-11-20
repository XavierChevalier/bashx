# Example: calculator

A small library (`calc.sh`) and its tests (`calc.test.sh`). From the
repository root:

```bash
bin/bashx test examples/calculator                       # 5 cases
bin/bashx test --coverage=/tmp/cov examples/calculator   # 100 % of the lines run
bin/bashx mutate examples/calculator/calc.sh             # ... yet one mutant survives
```

The survivor is the error message of `calc::_require_integers`: the tests
check that bad input fails, never what it prints. Add a case asserting the
message and run `bashx mutate` again: 100 %.
