#!/bin/sh
# run.sh - run the test suite under every available POSIX shell.
#
# Usage: tests/run.sh [TEST_FILE...]
#
# Runs each tests/t_*.sh (or the files given) once per shell in
# AO_TEST_SHELLS (default: "sh dash"; shells that are not installed are
# skipped). No network, no model calls: the agent CLIs are fakes.
#
# Exit codes: 0 all passed; 1 a test failed; 2 no shell available.
set -u
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
[ $# -gt 0 ] || set -- "$here"/t_*.sh
status=0
ran=0
for shell in ${AO_TEST_SHELLS:-sh dash}; do
  command -v "$shell" >/dev/null 2>&1 || { echo "skip shell: $shell (not installed)"; continue; }
  ran=1
  for t in "$@"; do
    AO_TEST_SHELL=$shell "$shell" "$t" || status=1
  done
done
[ "$ran" -eq 1 ] || { echo "no test shell available" >&2; exit 2; }
[ "$status" -eq 0 ] && echo "ALL PASSED" || echo "FAILURES"
exit "$status"
