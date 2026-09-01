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
APB="${OOD_APPTAINER_BIN:-$(command -v apptainer)}"

STAGED="$FAKE_HOME/ondemand/data/sys/ood-codeserver-ai/output/settings-uuid"
mkdir -p "$STAGED"
cp ../ood/codeserver-ai/template/codeserver.script.sh "$STAGED/"
chmod 755 "$STAGED/codeserver.script.sh"

SETTINGS="$FAKE_JOB_STATE/code-server/User/settings.json"

# <seed_override>, when given, is bind-mounted over the image's own
# /etc/code-server/settings.json -- the only way a test can present a
# different seed to the launcher without rebuilding the shared stub image
# that every other suite in this file also relies on.
launch() {
    local status="$1" seed_override="${2:-}"
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
    if [ -n "$seed_override" ]; then
        LC_BINDS+=( -B "${seed_override}:/etc/code-server/settings.json" )
    fi
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

it "the degraded settings file is also valid JSON"
# The parse-success assertion above only ever ran against the healthy-launch
# file. A merge bug that corrupts output only when the interpreter key is
# absent (e.g. a dangling comma left by conditionally omitting a key) would
# pass every check above and go unnoticed without this.
assert_success node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$SETTINGS"

# --- corrupt seed: unparseable /etc/code-server/settings.json --------------
# /etc/code-server/settings.json is image-owned and immutable; an unparseable
# one means a broken image. Failing the launch outright beats a session that
# looks fine with every image-level setting silently gone.
CORRUPT_SEED="$FIXTURE_ROOT/corrupt-settings.json"
printf '{ this is not valid json' > "$CORRUPT_SEED"

VALID_SEED_OVERRIDE="$FIXTURE_ROOT/valid-settings.json"
printf '{}' > "$VALID_SEED_OVERRIDE"

# Positive control: the override mechanism itself (a bind mount standing in
# for the image's seed) must be able to succeed. Without this, a failure on
# the corrupt seed below would only prove the bind mount broke the launch,
# not that the unparseable JSON did.
launch ok "$VALID_SEED_OVERRIDE"
BODY=$(cat "$SETTINGS" 2>/dev/null || echo "")

it "a syntactically valid seed override still lets the launch succeed"
assert_success test -s "$FAKE_JOB_STATE/argv.log"

it "the override actually replaced the image's seed, not a silent no-op"
# VALID_SEED_OVERRIDE is an empty {}, so telemetry.telemetryLevel -- present
# only in the image's own /etc/code-server/settings.json -- must be absent
# from the merged result. If the bind mount above were a no-op, the launcher
# would still read the image's real seed and this key would still be
# present, so the previous assertion alone would pass identically whether or
# not the override took effect.
assert_not_contains "$BODY" '"telemetry.telemetryLevel"'

it "an unparseable image settings seed fails the launch rather than degrading silently"
assert_failure launch ok "$CORRUPT_SEED"

it "an unparseable seed leaves no settings file behind"
assert_failure test -e "$SETTINGS"

finish
