#!/usr/bin/env bash
# A tiny library to test: integer arithmetic with input checks.

# Prints <a> + <b>.
# Usage: calc::add <a> <b>
calc::add() {
  calc::_require_integers "$@" || return
  echo $(($1 + $2))
}

# Prints <a> / <b>, rounded towards zero. Fails on a division by zero.
# Usage: calc::divide <a> <b>
calc::divide() {
  calc::_require_integers "$@" || return
  if (($2 == 0)); then
    echo "calc: division by zero" >&2
    return 1
  fi
  echo $(($1 / $2))
}

# Prints "negative", "zero" or "positive".
# Usage: calc::sign <n>
calc::sign() {
  calc::_require_integers "$1" || return
  if (($1 < 0)); then
    echo negative
  elif (($1 == 0)); then
    echo zero
  else
    echo positive
  fi
}

# Returns 2 unless every argument is an integer. Callers check it with
# `|| return`: under `if`, `||` or `&&`, bash ignores errexit, so a bare call
# would let them carry on with bad input.
calc::_require_integers() {
  local arg
  for arg in "$@"; do
    if [[ ! "${arg}" =~ ^-?[0-9]+$ ]]; then
      echo "calc: not an integer: '${arg}'" >&2
      return 2
    fi
  done
}
