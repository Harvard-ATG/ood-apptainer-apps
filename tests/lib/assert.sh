# shellcheck shell=bash
# Minimal assertion helpers. No dependencies beyond coreutils, so this suite
# runs unchanged on a cluster compute node as part of QA.

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

_pass() { printf '  ok   %s\n' "$CURRENT_TEST"; }

_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL %s\n       %s\n' "$CURRENT_TEST" "$1" >&2
}

it() {
    CURRENT_TEST="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
}

assert_eq() {
    if [ "$1" = "$2" ]; then _pass; else _fail "expected '$2', got '$1'"; fi
}

assert_contains() {
    case "$1" in
        *"$2"*) _pass ;;
        *) _fail "expected to contain '$2'; got: $1" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) _fail "expected NOT to contain '$2'; got: $1" ;;
        *) _pass ;;
    esac
}

assert_file_mode() {
    local actual
    actual=$(stat -c '%a' "$1" 2>/dev/null) || { _fail "cannot stat '$1'"; return; }
    if [ "$actual" = "$2" ]; then _pass; else _fail "mode of '$1' is $actual, expected $2"; fi
}

assert_success() {
    if "$@" >/dev/null 2>&1; then _pass; else _fail "expected success from: $*"; fi
}

assert_failure() {
    if "$@" >/dev/null 2>&1; then _fail "expected failure from: $*"; else _pass; fi
}

finish() {
    printf '%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
    [ "$TESTS_FAILED" -eq 0 ]
}
