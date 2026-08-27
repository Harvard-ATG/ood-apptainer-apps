#!/usr/bin/env bash
# Drives the full host-side launch path against the stub image: renders
# before.sh and script.sh, stages template/ the way OOD does, launches, waits
# for the port, and confirms signal delivery and teardown.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh
# shellcheck source=lib/fixture.sh
. lib/fixture.sh

fixture_create
trap fixture_destroy EXIT
# shellcheck disable=SC2034  # side effect of fixture_image (builds/caches the stub image and seeds the canonical image root); the path itself is unused here
IMAGE=$(fixture_image)
export HOME="$FAKE_HOME"
export USER=tester
export SLURM_JOB_ID=42
export OOD_AI_APPTAINER_BIN="${OOD_AI_APPTAINER_BIN:-$(command -v apptainer)}"
export OOD_AI_IMAGE_ROOT_FAST="$FAKE_IMAGE_ROOT_FAST"
export OOD_AI_IMAGE_ROOT_CANONICAL="$FAKE_IMAGE_ROOT_CANONICAL"
# Point the state layout at the fixture rather than the real /scratch.
export OOD_AI_SCRATCH_ROOT="$FAKE_SCRATCH"

# A sub-app fixture pointing at the fixture's own paths.
SUB="$FIXTURE_ROOT/e2e-subapp.yml.erb"
# ONE expression for the course path, not two. environment_root is
# course_folder + "/envs", so rewriting the base path fixes both. Two cascading
# expressions would have the second match inside the first's output, yielding
# /tmp/tmp.X/tmp/tmp.X/... and a path-escape rejection at launch.
sed -e "s#/shared/courseSharedFolders/170681outer/170681#$FAKE_COURSE_ROOT#g" \
    -e "s#jupyter-codeserver-ai/jupyterlab-20260827T000000Z-abc1234.sif#stub#" \
    fixtures/sample-subapp.yml.erb > "$SUB"

# OOD stages template/ into a session directory beneath the real home.
STAGED="$FAKE_HOME/ondemand/data/sys/ood-jupyterlab-ai/output/e2e-uuid"
mkdir -p "$STAGED/lib"
cp ../ood/jupyterlab-ai/template/lib/launch-common.sh "$STAGED/lib/"
cp ../ood/jupyterlab-ai/template/jupyterlab.script.sh "$STAGED/"
chmod 755 "$STAGED/jupyterlab.script.sh"

for tpl in before script after; do
    FAKE_GROUPS='canvas170681-999' FAKE_STAGED_ROOT="$STAGED" \
      ruby render.rb --template "../ood/jupyterlab-ai/template/$tpl.sh.erb" --form "$SUB" \
      > "$STAGED/$tpl.sh"
done
chmod 755 "$STAGED"/*.sh

# Stand-ins for the helpers OOD injects.
cat > "$STAGED/ood-stubs.sh" <<'STUBS'
find_port() { echo 7231; }
create_passwd() {
    # Filter a CONTINUOUS stream, then truncate. Truncating /dev/urandom to N
    # bytes first and filtering afterwards discards ~60% of them, yielding 5-12
    # characters instead of N -- which makes the credential-isolation assertions
    # flaky, because a 2-character secret collides by accident with the hex and
    # paths in an environment dump.
    LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "${1:-32}"
}
wait_until_port_used() {
    # Deliberately ignores the caller's timeout. after.sh passes the real 600s
    # budget, which would make a failing readiness check sleep for ten minutes.
    # That the template really passes 600 is asserted by test-after.sh; here we
    # only need to detect the port opening.
    local target="$1" timeout=20 waited=0
    local host="${target%%:*}" port="${target##*:}"
    while [ "$waited" -lt "$timeout" ]; do
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then exec 3<&-; return 0; fi
        sleep 1; waited=$((waited + 1))
    done
    return 1
}
clean_up() { echo "CLEAN_UP_CALLED=$1"; }
STUBS

LOG="$FIXTURE_ROOT/session.log"
(
    cd "$STAGED" || exit 1
    export host=127.0.0.1
    # shellcheck disable=SC1090,SC1091  # dynamically created stub sourced at runtime; not resolvable statically
    . ./ood-stubs.sh
    # shellcheck disable=SC1090,SC1091  # rendered template sourced at runtime; not resolvable statically
    . ./before.sh
    # before.sh reasserts HOME to the cluster layout, which does not exist in
    # the fixture; restore the fixture home so the rest of the run is coherent.
    export HOME="$FAKE_HOME"
    # shellcheck disable=SC2154  # port is exported by the sourced rendered template
    export STUB_PORT="$port"
    # Record the plaintext credential so the assertions below can prove it
    # never reached a command line. The hashed value is expected on argv.
    # shellcheck disable=SC2154  # password is exported by the sourced rendered template
    printf '%s' "$password" > "$FIXTURE_ROOT/plaintext-password"
    bash ./script.sh > "$LOG" 2>&1 &
    echo $! > "$FIXTURE_ROOT/script.pid"
    SCRIPT_PID=$(cat "$FIXTURE_ROOT/script.pid")
    export SCRIPT_PID
    # after.sh deletes the environment file once startup no longer needs it
    # (Finding 2), so snapshot it here -- outside $STAGED, unaffected by that
    # deletion -- while waiting for script.sh to have written it.
    waited=0
    while [ ! -s container.env ] && [ "$waited" -lt 100 ]; do
        sleep 0.1; waited=$((waited + 1))
    done
    cp -a container.env "$FIXTURE_ROOT/container.env.snapshot" 2>/dev/null
    # shellcheck disable=SC1090,SC1091  # rendered template sourced at runtime; not resolvable statically
    . ./after.sh > "$FIXTURE_ROOT/after.log" 2>&1
    echo "after_status=$?" >> "$FIXTURE_ROOT/after.log"
)
SCRIPT_PID=$(cat "$FIXTURE_ROOT/script.pid" 2>/dev/null || echo "")

it "script.sh selected an image root and logged it"
# The e2e fixture has no fast copy, so lc_select_image always falls back to
# the canonical root. Assert on that root specifically -- "apptainerImages"
# alone would pass regardless of which branch fired, since both roots
# contain that substring.
assert_contains "$(cat "$LOG")" "$FAKE_IMAGE_ROOT_CANONICAL"

it "script.sh validated and logged the course environment"
assert_contains "$(cat "$LOG")" "course environment=$FAKE_ENV_ROOT/default"

it "script.sh resolved the apptainer executable"
assert_contains "$(cat "$LOG")" "apptainer="

it "the environment file was created mode 0600"
assert_file_mode "$FIXTURE_ROOT/container.env.snapshot" 600

it "the environment file contains no unexpanded variable"
assert_not_contains "$(cat "$FIXTURE_ROOT/container.env.snapshot")" '$'

it "the environment file omits HOME, which --home sets"
assert_not_contains "$(grep '^HOME=' "$FIXTURE_ROOT/container.env.snapshot" || echo '')" "HOME="

it "the environment file is deleted once startup no longer needs it"
assert_failure test -e "$STAGED/container.env"

it "the server recorded its argv inside the container"
assert_success test -s "$FAKE_JOB_STATE/argv.log"

it "the server runs as the direct child of container init, with no shell between"
assert_eq "$(cat "$FAKE_JOB_STATE/server.ppid" 2>/dev/null)" "1"

it "readiness succeeded, so after.sh did not clean up"
assert_not_contains "$(cat "$FIXTURE_ROOT/after.log")" "CLEAN_UP_CALLED"

it "readiness logged discovery"
assert_contains "$(cat "$FIXTURE_ROOT/after.log")" "Discovered"

it "the plaintext credential never reached the server's argv"
PLAINTEXT=$(cat "$FIXTURE_ROOT/plaintext-password" 2>/dev/null || echo "__missing__")
assert_not_contains "$(cat "$FAKE_JOB_STATE/argv.log")" "$PLAINTEXT"

it "the generated credential is long enough for the leak assertions to mean anything"
# A short credential collides by accident with hex and paths in an environment
# dump, producing false failures. Guard the stub rather than trusting it.
assert_eq "$(printf '%s' "$PLAINTEXT" | wc -c | tr -d ' ')" "16"

it "the plaintext credential never reached the environment file"
assert_not_contains "$(cat "$FIXTURE_ROOT/container.env.snapshot")" "$PLAINTEXT"

it "the hashed credential IS on argv, which is the intended design"
assert_contains "$(cat "$FAKE_JOB_STATE/argv.log")" "sha1:"

it "reaping children of SCRIPT_PID stops the session"
if [ -n "$SCRIPT_PID" ]; then
    pkill -P "$SCRIPT_PID" 2>/dev/null
    sleep 2
    if kill -0 "$SCRIPT_PID" 2>/dev/null; then kill "$SCRIPT_PID" 2>/dev/null; fi
    sleep 1
    if pgrep -f 'jupyterlab.script.sh' >/dev/null 2>&1; then
        _fail "the in-container server survived the reap"
    else
        _pass
    fi
else
    _fail "script.sh pid was not captured"
fi

finish
