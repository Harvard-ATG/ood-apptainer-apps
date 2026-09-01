#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

SUB=fixtures/sample-subapp.yml.erb
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Stubs for the helpers OOD injects into the batch script.
cat > "$TMP/ood-stubs.sh" <<'STUBS'
find_port() { echo 7123; }
create_passwd() { head -c "${1:-32}" /dev/zero | tr '\0' 'a'; }
STUBS

render_before() {
    local app="$1"
    FAKE_GROUPS='canvas170681-999' FAKE_STAGED_ROOT="$TMP/staged" \
      ruby render.rb --template "../ood/$app/template/before.sh.erb" --form "$SUB"
}

# shellcheck source=scripts/lib/app-dirs.sh
. ../scripts/lib/app-dirs.sh
apps=$(ood_app_dirs) || { it "app discovery"; _fail "ood_app_dirs failed"; finish; exit 1; }

for app in $apps; do
    rendered="$TMP/$app-before.sh"
    render_before "$app" > "$rendered" 2>"$rendered.err" || {
        it "$app: before.sh.erb renders"
        _fail "$(cat "$rendered.err")"
        continue
    }

    it "$app: before.sh.erb renders"
    _pass

    # Run it in a subshell with the stubs and a decoy HOME, then dump the result.
    out=$(
        cd "$TMP" || exit 1
        mkdir -p staged && cd staged || exit 1
        # shellcheck disable=SC2030,SC2031  # HOME is deliberately scoped to this subshell; captured via stdout below
        export HOME=/decoy/home
        # shellcheck disable=SC2030,SC2031  # host is deliberately scoped to this subshell; captured via stdout below
        export host="compute-node-1"
        # shellcheck disable=SC1090,SC1091  # dynamically created stub sourced at runtime; not resolvable statically
        . "$TMP/ood-stubs.sh"
        # shellcheck disable=SC1090,SC1091  # rendered template sourced at runtime; not resolvable statically
        . "$rendered" >/dev/null 2>&1
        echo "HOME=$HOME"
        # shellcheck disable=SC2154  # port is exported by the sourced rendered template
        echo "port=$port"
        # shellcheck disable=SC2154  # password is exported by the sourced rendered template
        echo "password_len=${#password}"
        echo "JOBROOT=$JOBROOT"
        echo "MY_JUP_BASEURL=${MY_JUP_BASEURL:-unset}"
        echo "MY_JUP_PASSWD=${MY_JUP_PASSWD:-unset}"
    )

    it "$app: HOME is reasserted to the cluster home layout"
    assert_contains "$out" "HOME=/shared/home/"

    it "$app: HOME no longer holds the decoy value"
    assert_not_contains "$out" "HOME=/decoy/home"

    it "$app: port is exported from find_port"
    assert_contains "$out" "port=7123"

    it "$app: a 16-character credential is generated"
    assert_contains "$out" "password_len=16"

    it "$app: JOBROOT is the staged directory"
    assert_contains "$out" "JOBROOT=$TMP/staged"

    it "$app: uses id -nu rather than \$USER"
    assert_contains "$(cat "$rendered")" 'id -nu'

    it "$app: logs the original and corrected HOME"
    assert_contains "$(cat "$rendered")" 'original HOME'
done

it "jupyterlab: exports the hashed password, never the plaintext, for the server"
jl="$TMP/jupyterlab-ai-before.sh"
# The template quotes the value, so the rendered text is MY_JUP_PASSWD="sha1:...
assert_contains "$(cat "$jl")" 'MY_JUP_PASSWD="sha1:'

it "jupyterlab: base URL matches the OOD node proxy shape"
out=$(
    cd "$TMP/staged" || exit 1
    # shellcheck disable=SC2030,SC2031  # HOME/host are deliberately scoped to this subshell; captured via stdout below
    export HOME=/decoy/home host="compute-node-1"
    # shellcheck disable=SC1090,SC1091  # dynamically created stub sourced at runtime; not resolvable statically
    . "$TMP/ood-stubs.sh"
    # shellcheck disable=SC1090,SC1091  # rendered template sourced at runtime; not resolvable statically
    . "$jl" >/dev/null 2>&1
    echo "$MY_JUP_BASEURL"
)
assert_eq "$out" "/node/compute-node-1/7123/"

it "codeserver: does not define Jupyter-specific variables"
assert_not_contains "$(cat "$TMP/codeserver-ai-before.sh")" "MY_JUP_"

# Without a guard, a failing openssl leaves PASSWORD_SHA1 empty, so
# MY_JUP_PASSWD becomes "sha1:${SALT}:" -- the server still starts and
# readiness still succeeds, and every login is then silently rejected with no
# diagnostic. Assert the guard actually fires.
out=$(
    cd "$TMP/staged" || exit 1
    # shellcheck disable=SC2030,SC2031  # HOME/host are deliberately scoped to this subshell; captured via stdout below
    export HOME=/decoy/home host="compute-node-1"
    # shellcheck disable=SC1090,SC1091  # dynamically created stub sourced at runtime; not resolvable statically
    . "$TMP/ood-stubs.sh"
    # shellcheck disable=SC2317,SC2329  # invoked indirectly by the sourced rendered template below
    openssl() { return 1; }
    # shellcheck disable=SC1090,SC1091  # rendered template sourced at runtime; not resolvable statically
    . "$jl" 2>&1
)
status=$?

it "jupyterlab: exits nonzero when openssl cannot produce the password hash"
assert_eq "$status" "1"

it "jupyterlab: logs a diagnostic when openssl fails"
assert_contains "$out" "ERROR"

finish
