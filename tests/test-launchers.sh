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

run_launcher() {
    local script="$1"; shift
    local envf="$FIXTURE_ROOT/env.list"
    lc_write_env_file "$envf" "$@" || return 1
    lc_build_binds "$FAKE_COURSE_ROOT" "$FAKE_SCRATCH" "$FAKE_JOB_STATE" "$FAKE_JOB_TMP" "$FAKE_SSH_MASK"
    # The stub server holds a socket, so run it detached and stop it once it has
    # recorded its argv.
    lc_run "$APB" "$IMAGE" "$envf" "$STAGED/$script" >/dev/null 2>&1 &
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

finish
