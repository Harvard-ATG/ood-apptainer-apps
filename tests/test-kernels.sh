#!/usr/bin/env bash
# The kernel set a session offers, in each of the three states a course
# environment can be in. The launcher is executed with `exec` neutralised, so
# only the generation half runs.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh
# shellcheck source=lib/fixture.sh
. lib/fixture.sh

fixture_create
trap fixture_destroy EXIT

LAUNCHER=../ood/jupyterlab-ai/template/jupyterlab.script.sh

# Runs the launcher with a no-op `exec`, so generation happens and the server
# never starts. Echoes nothing; the caller inspects the generated tree.
run_generator() {
    local status="$1" staging="$2"
    rm -rf "$FAKE_JOB_STATE/jupyter"
    mkdir -p "$FAKE_JOB_STATE/jupyter/config" "$FAKE_JOB_STATE/jupyter/data"
    HOME="$FAKE_HOME" \
    COURSE_ENV="$FAKE_ENV_ROOT/default" \
    COURSE_ENV_STATUS="$status" \
    COURSE_ENV_STAGING="$staging" \
    COURSE_LABEL="${COURSE_LABEL_OVERRIDE-APMTH 115}" \
    ENVIRONMENT_ROOT="$FAKE_ENV_ROOT" \
    JUPYTER_CONFIG_DIR="$FAKE_JOB_STATE/jupyter/config" \
    JUPYTER_DATA_DIR="$FAKE_JOB_STATE/jupyter/data" \
    MY_JUP_PORT=7123 MY_JUP_PASSWD=sha1:a:b MY_JUP_BASEURL=/node/n/7123/ \
    bash -c 'exec() { :; }; . "$1"' _ "$LAUNCHER" >/dev/null 2>&1
}

KERNELS="$FAKE_JOB_STATE/jupyter/data/kernels"
CONFIG="$FAKE_JOB_STATE/jupyter/config/jupyter_server_config.py"

# --- provisioned course environment, no staging ---------------------------
run_generator ok ""

it "the course kernel is generated"
assert_success test -f "$KERNELS/course-python/kernel.json"

it "the course kernel runs the course interpreter, not the image one"
assert_contains "$(cat "$KERNELS/course-python/kernel.json")" "$FAKE_ENV_ROOT/default/bin/python"

it "the course kernel is named for the COURSE, not for our implementation"
# A student reads this string in the launcher, so it has to mean something to
# them. The label comes from a fixed sub-app attribute.
assert_contains "$(cat "$KERNELS/course-python/kernel.json")" '"display_name": "Python 3 (APMTH 115)"'

it "the course kernel falls back to a generic label if none was threaded through"
COURSE_LABEL_OVERRIDE="" run_generator ok ""
assert_contains "$(cat "$KERNELS/course-python/kernel.json")" '"display_name": "Python 3 (Course Environment)"'
run_generator ok ""

it "the image kernel is always generated too"
assert_success test -f "$KERNELS/image-python/kernel.json"

it "the image kernel runs the image interpreter"
assert_contains "$(cat "$KERNELS/image-python/kernel.json")" '/opt/conda/bin/python'

it "the image kernel's name says it carries no course packages"
# The name is the entire control. A student who picks this kernel must be able
# to tell from the kernel list alone why `import pandas` then fails.
assert_contains "$(cat "$KERNELS/image-python/kernel.json")" 'no course packages'

it "the course kernel is the default when it exists"
assert_contains "$(cat "$CONFIG")" 'c.MultiKernelManager.default_kernel_name = "course-python"'

it "both kernels are allowed"
assert_contains "$(cat "$CONFIG")" 'allowed_kernelspecs'

it "the allowed set names the course kernel"
assert_contains "$(cat "$CONFIG")" '"course-python"'

it "the allowed set names the image kernel"
assert_contains "$(cat "$CONFIG")" '"image-python"'

it "no staging kernel is generated when no staging prefix was passed"
assert_failure test -e "$KERNELS/course-python-staging"

# --- unprovisioned course environment -------------------------------------
run_generator missing ""

it "an unprovisioned course generates no course kernel"
assert_failure test -e "$KERNELS/course-python"

it "an unprovisioned course still generates the image kernel"
assert_success test -f "$KERNELS/image-python/kernel.json"

it "the image kernel becomes the default when there is no course kernel"
assert_contains "$(cat "$CONFIG")" 'c.MultiKernelManager.default_kernel_name = "image-python"'

it "the allowed set does not name a kernel that was never generated"
# allowed_kernelspecs listing course-python with no course-python on disk is
# the failure that looks fine in the config and produces an empty launcher.
assert_not_contains "$(cat "$CONFIG")" '"course-python"'

# --- broken course environment --------------------------------------------
fixture_break_course_python
run_generator ok ""

it "an interpreter that does not run generates no course kernel"
# Status is 'ok' here: the host saw an executable file. Only running it reveals
# the breakage, which is why the probe lives in the container.
assert_failure test -e "$KERNELS/course-python"

it "a broken environment still leaves a working session with the image kernel"
assert_contains "$(cat "$CONFIG")" 'c.MultiKernelManager.default_kernel_name = "image-python"'

# --- staging, for eligible staff ------------------------------------------
# fixture_destroy/fixture_create build a fresh $FIXTURE_ROOT, which moves
# $FAKE_JOB_STATE -- so KERNELS and CONFIG (captured from the first fixture's
# path) must be recomputed or they point at a directory that no longer exists.
fixture_destroy
fixture_create
KERNELS="$FAKE_JOB_STATE/jupyter/data/kernels"
CONFIG="$FAKE_JOB_STATE/jupyter/config/jupyter_server_config.py"
run_generator ok "$FAKE_ENV_ROOT/staging"

it "a writable environment root yields a staging kernel"
assert_success test -f "$KERNELS/course-python-staging/kernel.json"

it "the staging kernel is labelled as staging"
assert_contains "$(cat "$KERNELS/course-python-staging/kernel.json")" 'STAGING'

it "the staging kernel is never the default"
assert_contains "$(cat "$CONFIG")" 'c.MultiKernelManager.default_kernel_name = "course-python"'

it "a read-only environment root yields no staging kernel"
# Eligibility is a writability test, never a group-name test: the staff group
# cannot be named inside the container.
chmod 555 "$FAKE_ENV_ROOT"
run_generator ok "$FAKE_ENV_ROOT/staging"
chmod 755 "$FAKE_ENV_ROOT"
assert_failure test -e "$KERNELS/course-python-staging"

finish
