#!/usr/bin/env bash
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

# Stage the launchers where the container will find them, mirroring how OOD
# stages template/ into the session directory beneath the real home.
STAGED="$FAKE_HOME/ondemand/data/sys/ood-jupyterlab-ai/output/test-uuid"
mkdir -p "$STAGED"
cp ../ood/jupyterlab-ai/template/jupyterlab.script.sh "$STAGED/"
cp ../ood/codeserver-ai/template/codeserver.script.sh "$STAGED/"
chmod 755 "$STAGED"/*.script.sh

it "jupyterlab.script.sh is committed executable"
assert_eq "$(stat -c '%a' ../ood/jupyterlab-ai/template/jupyterlab.script.sh)" "755"

it "codeserver.script.sh is committed executable"
assert_eq "$(stat -c '%a' ../ood/codeserver-ai/template/codeserver.script.sh)" "755"

it "jupyterlab launcher execs rather than forks"
assert_contains "$(cat ../ood/jupyterlab-ai/template/jupyterlab.script.sh)" "exec "

# The env file script.sh.erb writes sets PATH=/usr/local/bin:/usr/bin:/bin and
# deliberately EXCLUDES /opt/conda/bin, where the image keeps jupyter. That
# exclusion is not an oversight: students get a terminal inside JupyterLab, and
# the image's conda bin on their PATH would make `python` resolve to the image
# interpreter rather than the course environment -- the same "silently lacks
# every course package" failure the deleted base kernelspec guards against.
# The consequence is that a bare `exec jupyter lab` either does not resolve at
# all, or resolves to ${COURSE_ENV}/bin/jupyter once the launcher prepends the
# course bin, which the launcher's own comment forbids. So the exec target must
# be an absolute, image-owned path.
JL_EXEC_TARGET=$(grep -E '^exec ' ../ood/jupyterlab-ai/template/jupyterlab.script.sh \
    | head -1 | awk '{print $2}')

it "jupyterlab launcher execs an ABSOLUTE path, not a bare command name"
assert_eq "${JL_EXEC_TARGET:0:1}" "/"

it "jupyterlab launcher execs the image-owned jupyter, which the env-file PATH cannot reach"
assert_eq "$JL_EXEC_TARGET" "/opt/conda/bin/jupyter"

it "codeserver launcher execs rather than forks"
assert_contains "$(cat ../ood/codeserver-ai/template/codeserver.script.sh)" "exec "

# The same reasoning as the JupyterLab block above, and for a stronger reason:
# codeserver.script.sh prepends ${COURSE_ENV}/bin to PATH, so the FIRST element
# of PATH when it execs is a staff-writable directory on a shared filesystem. A
# bare `exec code-server` resolves there before it reaches the image, which the
# launcher's own comment claims cannot happen. The planted-binary test at the
# bottom of this file proves the consequence; these two pin the mechanism.
CS_EXEC_TARGET=$(grep -E '^exec ' ../ood/codeserver-ai/template/codeserver.script.sh \
    | head -1 | awk '{print $2}')

it "codeserver launcher execs an ABSOLUTE path, not a bare command name"
assert_eq "${CS_EXEC_TARGET:0:1}" "/"

it "codeserver launcher execs the image-owned code-server"
# /usr/local/bin/code-server is the real image's symlink into
# /usr/local/lib/code-server, and the stub image mirrors that path.
assert_eq "$CS_EXEC_TARGET" "/usr/local/bin/code-server"

# The launcher's own stdout+stderr, kept rather than discarded: a degraded
# session is required to SAY SO, and that is only assertable if the log survives.
LAUNCH_LOG="$FIXTURE_ROOT/launch.log"

run_launcher() {
    local script="$1"; shift
    local envf="$FIXTURE_ROOT/env.list"
    lc_write_env_file "$envf" "$@" || return 1
    lc_build_binds "$FAKE_COURSE_ROOT" "$FAKE_SCRATCH" "$FAKE_JOB_STATE" "$FAKE_JOB_TMP" "$FAKE_SSH_MASK"
    : > "$LAUNCH_LOG"
    # The stub server holds a socket, so run it detached and stop it once it has
    # recorded its argv.
    lc_run "$APB" "$IMAGE" "$envf" "$STAGED/$script" >"$LAUNCH_LOG" 2>&1 &
    local pid=$!
    local waited=0
    while [ ! -s "$FAKE_JOB_STATE/argv.log" ] && [ "$waited" -lt 100 ]; do
        sleep 0.1; waited=$((waited + 1))
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    [ -s "$FAKE_JOB_STATE/argv.log" ]
}

# --- JupyterLab ---
rm -f "$FAKE_JOB_STATE/argv.log" "$FAKE_JOB_STATE/server.pid"
run_launcher jupyterlab.script.sh \
    "MY_JUP_PORT=7123" \
    "MY_JUP_PASSWD=sha1:abc:def-hashed-not-plaintext" \
    "MY_JUP_BASEURL=/node/node1/7123/" \
    "COURSE_ENV=$FAKE_ENV_ROOT/default" \
    "JUPYTER_PATH=/state/jupyter/data" \
    "STUB_PORT=7123" \
    "STATE_DIR=/state" \
    "PATH=/usr/local/bin:/usr/bin:/bin"
JL_ARGV=$(cat "$FAKE_JOB_STATE/argv.log" 2>/dev/null || echo "")

it "jupyterlab: the server was invoked"
assert_contains "$JL_ARGV" "jupyter"

it "jupyterlab: the server was reached by its absolute path under the launch PATH"
# argv[0] is the name the launcher actually exec'd, recorded from inside the
# container while PATH was exactly the env-file value above. The stub mirrors
# the real image's /opt/conda/bin layout for this reason.
assert_contains "$JL_ARGV" "/opt/conda/bin/jupyter"

it "jupyterlab: binds all interfaces"
assert_contains "$JL_ARGV" "--ip=0.0.0.0"

it "jupyterlab: uses the OOD-selected port"
assert_contains "$JL_ARGV" "--port=7123"

it "jupyterlab: disables port retries so the proxy URL stays valid"
assert_contains "$JL_ARGV" "--port-retries=0"

it "jupyterlab: sets the node-proxy base URL"
assert_contains "$JL_ARGV" "--ServerApp.base_url=/node/node1/7123/"

it "jupyterlab: passes only the hashed credential"
assert_contains "$JL_ARGV" "sha1:abc:def-hashed-not-plaintext"

it "jupyterlab: allows the cross-origin proxy connection"
assert_contains "$JL_ARGV" "--ServerApp.allow_origin=*"

it "jupyterlab: runs as the direct child of container init, with no shell between"
# Apptainer's --pid namespace has its own init shim as PID 1, which reaps
# zombies (load-bearing: JupyterLab spawns kernels) and forwards signals. So the
# server is not PID 1 -- but if the launcher forked instead of exec'ing, the
# server's parent would be the launcher script rather than init.
assert_eq "$(cat "$FAKE_JOB_STATE/server.ppid" 2>/dev/null)" "1"

# --- code-server ---
rm -f "$FAKE_JOB_STATE/argv.log" "$FAKE_JOB_STATE/server.pid"
run_launcher codeserver.script.sh \
    "CODE_SERVER_PORT=7124" \
    "PASSWORD=plaintext-must-not-reach-argv" \
    "COURSE_ENV=$FAKE_ENV_ROOT/default" \
    "COURSE_ENV_STATUS=ok" \
    "STUB_PORT=7124" \
    "STATE_DIR=/state" \
    "PATH=/usr/local/bin:/usr/bin:/bin"
CS_ARGV=$(cat "$FAKE_JOB_STATE/argv.log" 2>/dev/null || echo "")

it "codeserver: the server was invoked"
assert_contains "$CS_ARGV" "code-server"

it "codeserver: binds all interfaces on the OOD port"
assert_contains "$CS_ARGV" "--bind-addr=0.0.0.0:7124"

it "codeserver: uses password auth"
assert_contains "$CS_ARGV" "--auth=password"

it "codeserver: the password never appears in argv"
assert_not_contains "$CS_ARGV" "plaintext-must-not-reach-argv"

it "codeserver: uses the image-owned immutable extensions directory"
assert_contains "$CS_ARGV" "--extensions-dir=/opt/code-server/extensions"

it "codeserver: keeps user data in job-local state"
assert_contains "$CS_ARGV" "--user-data-dir=/state/code-server"

it "codeserver: extensions-dir and user-data-dir are distinct"
assert_not_contains "$CS_ARGV" "--extensions-dir=/state"

it "codeserver: disables the update check"
assert_contains "$CS_ARGV" "--disable-update-check"

it "codeserver: disables telemetry"
assert_contains "$CS_ARGV" "--disable-telemetry"

it "codeserver: runs as the direct child of container init, with no shell between"
assert_eq "$(cat "$FAKE_JOB_STATE/server.ppid" 2>/dev/null)" "1"

# /state is bound from the host at $FAKE_JOB_STATE, so the settings file the
# launcher wrote inside the container is visible here at the host path.
SETTINGS_FILE="$FAKE_JOB_STATE/code-server/User/settings.json"

it "codeserver: generates a settings.json for the workspace"
assert_success test -f "$SETTINGS_FILE"

it "codeserver: workspace trust is disabled -- the single most security-relevant in-container setting"
assert_contains "$(cat "$SETTINGS_FILE")" '"security.workspace.trust.enabled": false'

it "codeserver: points the Python extension at the course interpreter"
# The settings file is a MERGE of the image's seed and generated keys (see
# tests/test-settings-merge.sh for that coverage); here we only need proof the
# interpreter key survives an end-to-end launch through the real launcher.
assert_contains "$(cat "$SETTINGS_FILE")" '"python.defaultInterpreterPath"'

# --- code-server: the staff-writable course environment must not be able to
# substitute its own server.
#
# ${COURSE_ENV}/bin is the first element of PATH by the time the launcher
# execs, and the course folder is bound into the container at its own host
# path, so a file planted here is exactly what a bare `exec code-server` would
# find. This asserts the CONSEQUENCE -- which binary actually ran, recorded
# from inside the container -- rather than the launcher's comment about it.
rm -f "$FAKE_JOB_STATE/argv.log" "$FAKE_JOB_STATE/server.pid"
cat > "$FAKE_ENV_ROOT/default/bin/code-server" <<'INTRUDER'
#!/bin/sh
: "${STATE_DIR:=/state}"
mkdir -p "$STATE_DIR"
printf '%s\n' "COURSE-ENV-INTRUDER-RAN" "$0" "$@" > "$STATE_DIR/argv.log"
exit 0
INTRUDER
chmod 755 "$FAKE_ENV_ROOT/default/bin/code-server"
run_launcher codeserver.script.sh \
    "CODE_SERVER_PORT=7125" \
    "PASSWORD=plaintext-must-not-reach-argv" \
    "COURSE_ENV=$FAKE_ENV_ROOT/default" \
    "COURSE_ENV_STATUS=ok" \
    "STUB_PORT=7125" \
    "STATE_DIR=/state" \
    "PATH=/usr/local/bin:/usr/bin:/bin"
CS_PLANTED_ARGV=$(cat "$FAKE_JOB_STATE/argv.log" 2>/dev/null || echo "")
rm -f "$FAKE_ENV_ROOT/default/bin/code-server"

it "codeserver: a code-server planted in the staff-writable course environment does NOT run"
assert_not_contains "$CS_PLANTED_ARGV" "COURSE-ENV-INTRUDER-RAN"

it "codeserver: the image-owned server ran instead"
# Not merely the absence of the intruder: a launcher that failed to start
# anything at all would also satisfy the assertion above.
assert_contains "$CS_PLANTED_ARGV" "/usr/local/bin/code-server"

# --- code-server, State C: the interpreter is present and executable but does
# not RUN.
#
# This is the shape of a course environment broken by a failed staff update.
# The host side cannot answer it -- the compute node and the image do not share
# a libc -- so lc_classify_course_env still reports status=ok and the launcher
# is the only place the question is real. Pointing
# python.defaultInterpreterPath at an interpreter that dies is worse than not
# setting it: the setting looks configured, so nothing looks wrong. The
# JupyterLab side has probed for this from the start; this asserts code-server
# now behaves the same way.
#
# Runs LAST in this file: fixture_break_course_python replaces the fixture's
# course interpreter for good.
rm -f "$FAKE_JOB_STATE/argv.log" "$FAKE_JOB_STATE/server.pid" "$SETTINGS_FILE"
fixture_break_course_python
run_launcher codeserver.script.sh \
    "CODE_SERVER_PORT=7126" \
    "PASSWORD=plaintext-must-not-reach-argv" \
    "COURSE_ENV=$FAKE_ENV_ROOT/default" \
    "COURSE_ENV_STATUS=ok" \
    "STUB_PORT=7126" \
    "STATE_DIR=/state" \
    "PATH=/usr/local/bin:/usr/bin:/bin"
CS_BROKEN_SETTINGS=$(cat "$SETTINGS_FILE" 2>/dev/null || echo "")
CS_BROKEN_LOG=$(cat "$LAUNCH_LOG" 2>/dev/null || echo "")

it "codeserver: a broken course interpreter does NOT get written as the default interpreter"
# The consequence, not the log line: `[ -x ]` alone passes here, so this is
# the assertion that fails if the probe is removed.
assert_not_contains "$CS_BROKEN_SETTINGS" "python.defaultInterpreterPath"

it "codeserver: the degraded session still generates settings, merged with the image seed"
# Degrading must not mean writing nothing: the image's own keys still have to
# reach the session, or a broken course environment silently costs the student
# workspace trust as well.
assert_contains "$CS_BROKEN_SETTINGS" '"security.workspace.trust.enabled": false'

it "codeserver: the degraded session still starts"
assert_contains "$(cat "$FAKE_JOB_STATE/argv.log" 2>/dev/null || echo "")" "/usr/local/bin/code-server"

it "codeserver: the degraded session SAYS SO in the session log"
# The silent half of the divergence: code-server used to configure the broken
# interpreter and log nothing at all, so the only symptom a student or staff
# member ever saw was Python not working.
assert_contains "$CS_BROKEN_LOG" "no usable course environment"

it "codeserver: the degraded session log states the interpreter key was not set"
assert_contains "$CS_BROKEN_LOG" "python.defaultInterpreterPath is NOT set"

finish
