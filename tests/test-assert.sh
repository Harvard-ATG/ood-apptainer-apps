#!/usr/bin/env bash
# Tests the assertion library itself, including that failures are detected.
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/assert.sh
. lib/assert.sh

it "assert_eq passes on equal strings"
assert_eq "abc" "abc"

it "assert_contains finds a substring"
assert_contains "hello world" "lo wo"

it "assert_not_contains passes when absent"
assert_not_contains "hello" "zzz"

it "assert_file_mode reads octal mode"
tmp=$(mktemp); chmod 600 "$tmp"
assert_file_mode "$tmp" 600
rm -f "$tmp"

it "assert_success accepts a zero exit"
assert_success true

it "assert_failure accepts a nonzero exit"
assert_failure false

# A failing assertion must increment TESTS_FAILED. Run it in a subshell so this
# suite still reports success.
it "a failed assertion is counted"
before_failed=$TESTS_FAILED
assert_eq "x" "y" 2>/dev/null
if [ "$TESTS_FAILED" -eq $((before_failed + 1)) ]; then
    TESTS_FAILED=$before_failed
    CURRENT_TEST="a failed assertion is counted"
    _pass
else
    TESTS_FAILED=$before_failed
    _fail "TESTS_FAILED did not increment"
fi

finish
