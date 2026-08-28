#!/usr/bin/env bash
# The terminal a student actually gets.
#
# Apptainer exports PS1="Apptainer> " from its own /.singularity.d/env/99-base.sh
# into the container environment, and every child process inherits it. An
# interactive bash overrides it from /etc/bash.bashrc, but a shell that never
# reads those files -- sh/dash, or bash started without its rc files -- shows the
# student a container implementation detail where a prompt should be. Both apps
# also fall back to a bare `sh` when SHELL is unset, and dash is precisely the
# shell that would show the inherited prompt.
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

STAGED="$FAKE_HOME/ondemand/data/sys/ood-terminal/output/term-uuid"
mkdir -p "$STAGED"
cp ../ood/jupyterlab-ai/template/jupyterlab.script.sh "$STAGED/"
cp ../ood/codeserver-ai/template/codeserver.script.sh "$STAGED/"
chmod 755 "$STAGED"/*.script.sh

# The stub image is a faithful vehicle for this: it leaks PS1 exactly as the real
# images do, and unlike them it has SHELL unset -- which is the state that makes
# a terminal fall through to dash.
it "the stub image really does leak Apptainer's PS1 (otherwise these tests prove nothing)"
lc_write_env_file "$FIXTURE_ROOT/probe.env" "PATH=/usr/local/bin:/usr/bin:/bin" || true
lc_build_binds "$FAKE_COURSE_ROOT" "$FAKE_SCRATCH" "$FAKE_JOB_STATE" "$FAKE_JOB_TMP" "$FAKE_SSH_MASK"
probe=$(lc_run "$APB" "$IMAGE" "$FIXTURE_ROOT/probe.env" env 2>/dev/null)
assert_contains "$probe" "Apptainer>"

it "the leak is via PROMPT_COMMAND, which defeats even a normal interactive bash"
# PS1 alone would be overridden by /etc/bash.bashrc. PROMPT_COMMAND runs AFTER
# the rc files, before the first prompt, and re-sets PS1 -- then unsets itself,
# so it leaves no trace for anyone debugging it later.
assert_contains "$probe" "PROMPT_COMMAND=PS1="

launch() {  # <launcher> <extra KEY=VALUE>...
    local script="$1"; shift
    rm -f "$FAKE_JOB_STATE/argv.log" "$FAKE_JOB_STATE/env.log"
    local envf="$FIXTURE_ROOT/env.list"
    lc_write_env_file "$envf" \
        "COURSE_ENV=$FAKE_ENV_ROOT/default" \
        "COURSE_ENV_STATUS=ok" \
        "ENVIRONMENT_ROOT=$FAKE_ENV_ROOT" \
        "STUB_PORT=7311" \
        "STATE_DIR=/state" \
        "PATH=/usr/local/bin:/usr/bin:/bin" \
        "$@" || return 1
    lc_build_binds "$FAKE_COURSE_ROOT" "$FAKE_SCRATCH" "$FAKE_JOB_STATE" "$FAKE_JOB_TMP" "$FAKE_SSH_MASK"
    lc_run "$APB" "$IMAGE" "$envf" "$STAGED/$script" >/dev/null 2>&1 &
    local pid=$! waited=0
    while [ ! -s "$FAKE_JOB_STATE/env.log" ] && [ "$waited" -lt 100 ]; do
        sleep 0.1; waited=$((waited + 1))
    done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    [ -s "$FAKE_JOB_STATE/env.log" ]
}

# --- JupyterLab -----------------------------------------------------------
launch jupyterlab.script.sh \
    "COURSE_ENV_STAGING=" \
    "MY_JUP_PORT=7311" "MY_JUP_PASSWD=sha1:a:b" "MY_JUP_BASEURL=/node/n/7311/" \
    "JUPYTER_CONFIG_DIR=/state/jupyter/config" "JUPYTER_DATA_DIR=/state/jupyter/data"
JL_ENV=$(cat "$FAKE_JOB_STATE/env.log" 2>/dev/null || echo "")

it "jupyterlab: the server's environment carries neither PS1 nor PROMPT_COMMAND"
# The consequence: nothing the server spawns can inherit "Apptainer> ".
assert_not_contains "$JL_ENV" "Apptainer>"

it "jupyterlab: SHELL is pinned to bash rather than left unset"
assert_contains "$JL_ENV" "SHELL=/bin/bash"

JL_CFG=$(cat "$FAKE_JOB_STATE/jupyter/config/jupyter_server_config.py" 2>/dev/null || echo "")

it "jupyterlab: the terminal shell is pinned in the generated config"
assert_contains "$JL_CFG" 'terminado_settings'

it "jupyterlab: the pinned terminal shell is bash"
assert_contains "$JL_CFG" '"shell_command": ["/bin/bash"]'

it "jupyterlab: the terminal shell is NOT a login shell"
# `bash -l` re-reads /etc/profile, which resets PATH and would discard the
# course-environment prepend the launcher just made.
assert_not_contains "$JL_CFG" '"-l"'

# --- code-server ----------------------------------------------------------
launch codeserver.script.sh "CODE_SERVER_PORT=7311" "PASSWORD=irrelevant-here"
CS_ENV=$(cat "$FAKE_JOB_STATE/env.log" 2>/dev/null || echo "")

it "codeserver: the server's environment carries neither PS1 nor PROMPT_COMMAND"
assert_not_contains "$CS_ENV" "Apptainer>"

it "codeserver: SHELL is pinned to bash rather than left unset"
assert_contains "$CS_ENV" "SHELL=/bin/bash"

CS_SETTINGS=$(cat "$FAKE_JOB_STATE/code-server/User/settings.json" 2>/dev/null || echo "")

it "codeserver: the integrated terminal profile is pinned to bash"
assert_contains "$CS_SETTINGS" '"terminal.integrated.defaultProfile.linux": "bash"'

it "codeserver: the settings file is still valid JSON after that addition"
assert_success node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' \
    "$FAKE_JOB_STATE/code-server/User/settings.json"

finish
