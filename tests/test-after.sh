#!/usr/bin/env bash
# SC2016: assert_contains patterns below are deliberately single-quoted so
# shell metacharacters ($host, ${...}) are compared literally against the
# rendered template's source text rather than expanded by this test script's
# shell. This directive must precede every command in the file, so it sits
# immediately after the shebang.
# shellcheck disable=SC2016
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

SUB=fixtures/sample-subapp.yml.erb
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for app in jupyterlab-ai codeserver-ai; do
    rendered="$TMP/$app-after.sh"
    FAKE_GROUPS='canvas170681-999' FAKE_STAGED_ROOT="$TMP/staged" \
      ruby render.rb --template "../ood/$app/template/after.sh.erb" --form "$SUB" \
      > "$rendered" 2>"$rendered.err" || {
        it "$app: after.sh.erb renders"; _fail "$(cat "$rendered.err")"; continue; }

    it "$app: after.sh.erb renders"
    _pass

    it "$app: waits 600 seconds, the family standard"
    assert_contains "$(cat "$rendered")" 'wait_until_port_used "${host}:${port}" 600'

    it "$app: reaps children of SCRIPT_PID on timeout"
    assert_contains "$(cat "$rendered")" 'pkill -P "${SCRIPT_PID}"'

    it "$app: calls clean_up 1 on timeout"
    assert_contains "$(cat "$rendered")" 'clean_up 1'

    it "$app: never suppresses failure with '|| true'"
    assert_not_contains "$(cat "$rendered")" '|| true'

    it "$app: never disables errexit to hide a failure"
    assert_not_contains "$(cat "$rendered")" 'set +e'

    # Success path: the port opens. JOBROOT points at a fixture job directory
    # holding a stand-in container.env, so deletion can be observed on the
    # real filesystem after the subshell exits.
    JOBROOT_OK="$TMP/$app-jobroot-ok"
    mkdir -p "$JOBROOT_OK"
    : > "$JOBROOT_OK/container.env"
    out=$(
        # shellcheck disable=SC2317,SC2329  # invoked indirectly by the sourced rendered template below
        wait_until_port_used() { return 0; }
        # shellcheck disable=SC2317,SC2329  # invoked indirectly by the sourced rendered template below
        clean_up() { echo "CLEAN_UP_CALLED=$1"; }
        # shellcheck disable=SC2317,SC2329  # invoked indirectly by the sourced rendered template below
        pkill() { echo "PKILL_CALLED"; }
        # shellcheck disable=SC2030  # deliberately scoped to this subshell; captured via stdout below
        export host=node1 port=7123 SCRIPT_PID=99999 JOBROOT="$JOBROOT_OK"
        # shellcheck disable=SC1090
        . "$rendered" 2>&1
    )
    it "$app: success path does not reap"
    assert_not_contains "$out" "PKILL_CALLED"

    it "$app: success path logs discovery"
    assert_contains "$out" "Discovered"

    it "$app: success path deletes the per-job environment file"
    assert_failure test -e "$JOBROOT_OK/container.env"

    # Failure path: the port never opens. Same JOBROOT/container.env setup,
    # a separate directory so the two paths cannot mask each other.
    JOBROOT_FAIL="$TMP/$app-jobroot-fail"
    mkdir -p "$JOBROOT_FAIL"
    : > "$JOBROOT_FAIL/container.env"
    out=$(
        # shellcheck disable=SC2317,SC2329  # invoked indirectly by the sourced rendered template below
        wait_until_port_used() { return 1; }
        # shellcheck disable=SC2317,SC2329  # invoked indirectly by the sourced rendered template below
        clean_up() { echo "CLEAN_UP_CALLED=$1"; }
        # shellcheck disable=SC2317,SC2329  # invoked indirectly by the sourced rendered template below
        pkill() { echo "PKILL_CALLED $*"; }
        # shellcheck disable=SC2031  # deliberately scoped to this subshell; captured via stdout below
        export host=node1 port=7123 SCRIPT_PID=99999 JOBROOT="$JOBROOT_FAIL"
        # shellcheck disable=SC1090
        . "$rendered" 2>&1
    )
    it "$app: failure path reaps children of SCRIPT_PID"
    assert_contains "$out" "PKILL_CALLED -P 99999"

    it "$app: failure path calls clean_up 1"
    assert_contains "$out" "CLEAN_UP_CALLED=1"

    it "$app: failure path logs a usable diagnostic"
    assert_contains "$out" "Timed out"

    it "$app: failure path deletes the per-job environment file"
    assert_failure test -e "$JOBROOT_FAIL/container.env"
done

finish
