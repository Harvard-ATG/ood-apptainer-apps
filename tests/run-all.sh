#!/usr/bin/env bash
# Runs every test-*.sh in this directory. Exits nonzero if any suite fails.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

failed=0
for suite in test-*.sh; do
    printf '\n=== %s ===\n' "$suite"
    bash "$suite" || failed=$((failed + 1))
done

printf '\n'
if [ "$failed" -eq 0 ]; then
    printf 'ALL SUITES PASSED\n'
else
    printf '%d SUITE(S) FAILED\n' "$failed"
fi
exit "$failed"
