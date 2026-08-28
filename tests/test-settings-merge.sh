#!/usr/bin/env bash
# The code-server settings file is a MERGE of the image's seed and the
# launch-generated keys. A launcher that copies the seed and then rewrites the
# same path with a heredoc discards every key the image ships while appearing to
# honour it, and the failure is quiet: workspace trust is among the generated
# keys, so the session looks correct while any image-level setting vanishes.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh
# shellcheck source=lib/fixture.sh
. lib/fixture.sh
# shellcheck source=../ood/lib/launch-common.sh
. ../ood/lib/launch-common.sh

fixture_create
trap fixture_destroy EXIT
IMAGE=$(fixture_image)
export HOME="$FAKE_HOME"
APB="${OOD_AI_APPTAINER_BIN:-$(command -v apptainer)}"

STAGED="$FAKE_HOME/ondemand/data/sys/ood-codeserver-ai/output/settings-uuid"
mkdir -p "$STAGED"
cp ../ood/codeserver-ai/template/codeserver.script.sh "$STAGED/"
chmod 755 "$STAGED/codeserver.script.sh"

SETTINGS="$FAKE_JOB_STATE/code-server/User/settings.json"

launch() {
    local status="$1"
    rm -rf "$FAKE_JOB_STATE/code-server" "$FAKE_JOB_STATE/argv.log"
    local envf="$FIXTURE_ROOT/env.list"
    lc_write_env_file "$envf" \
        "CODE_SERVER_PORT=7124" \
        "PASSWORD=plaintext-must-not-reach-argv" \
        "COURSE_ENV=$FAKE_ENV_ROOT/default" \
        "COURSE_ENV_STATUS=$status" \
        "STUB_PORT=7124" \
        "STATE_DIR=/state" \
        "PATH=/usr/local/bin:/usr/bin:/bin" || return 1
    lc_build_binds "$FAKE_COURSE_ROOT" "$FAKE_SCRATCH" "$FAKE_JOB_STATE" "$FAKE_JOB_TMP" "$FAKE_SSH_MASK"
    lc_run "$APB" "$IMAGE" "$envf" "$STAGED/codeserver.script.sh" >/dev/null 2>&1 &
    local pid=$! waited=0
    while [ ! -s "$FAKE_JOB_STATE/argv.log" ] && [ "$waited" -lt 100 ]; do
        sleep 0.1; waited=$((waited + 1))
    done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    [ -s "$FAKE_JOB_STATE/argv.log" ]
}

launch ok
BODY=$(cat "$SETTINGS" 2>/dev/null || echo "")

it "the settings file was generated"
assert_success test -s "$SETTINGS"

it "a key present ONLY in the image reaches the session"
# This is the assertion the whole task exists for.
assert_contains "$BODY" '"telemetry.telemetryLevel"'

it "a second image-only key reaches the session too"
assert_contains "$BODY" '"extensions.autoCheckUpdates"'

it "the course interpreter is set"
assert_contains "$BODY" "$FAKE_ENV_ROOT/default/bin/python"

it "workspace trust is disabled"
assert_contains "$BODY" '"security.workspace.trust.enabled": false'

it "the result is valid JSON"
assert_success node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$SETTINGS"

# --- degraded: no course environment --------------------------------------
launch missing
BODY=$(cat "$SETTINGS" 2>/dev/null || echo "")

it "a degraded session still gets a settings file"
assert_success test -s "$SETTINGS"

it "a degraded session omits the interpreter path rather than writing a broken one"
# Pointing python.defaultInterpreterPath at a path that does not resolve is
# worse than leaving VS Code to its own discovery: the setting looks configured.
assert_not_contains "$BODY" 'python.defaultInterpreterPath'

it "a degraded session still disables workspace trust"
# Without this the Claude Code extension does not load at all.
assert_contains "$BODY" '"security.workspace.trust.enabled": false'

it "a degraded session still carries the image's own keys"
assert_contains "$BODY" '"telemetry.telemetryLevel"'

finish
