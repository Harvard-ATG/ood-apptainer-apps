#!/usr/bin/env bash
# Runs INSIDE the container. Staged by OOD from template/, so it is a plain
# script rather than an ERB template and must stay mode 0755.
#
# Every value below arrives through the mode-0600 environment file. Nothing is
# read from the host environment, because --cleanenv discards it.

set -u

this_script="template/codeserver.script.sh"

log() {
    echo -e "[$(date -Iseconds)][${this_script}] $1"
}

log "container HOME=${HOME}"
log "course environment=${COURSE_ENV}"

USER_DATA_DIR=/state/code-server
SEED_SETTINGS=/etc/code-server/settings.json
mkdir -p "${USER_DATA_DIR}/User" || { log "ERROR: cannot create ${USER_DATA_DIR}/User"; exit 1; }

# The course interpreter cannot be baked into a shared image, so it is generated
# here -- but the image's own settings must survive. The two are MERGED, with
# the generated keys winning. Copying the seed and then rewriting the same path
# with a heredoc would discard every image key while appearing to honour it, and
# the failure is silent: workspace trust is among the generated keys, so the
# session looks right while any image-level setting quietly vanishes.
#
# node rather than python3 or jq: the code-server image is Ubuntu-based and has
# neither, while node is guaranteed -- it is what both AI CLIs run on.
COURSE_PYTHON=""
if [ "${COURSE_ENV_STATUS:-missing}" = ok ] && [ -x "${COURSE_ENV}/bin/python" ]; then
    COURSE_PYTHON="${COURSE_ENV}/bin/python"
    # The server itself comes from its image-owned location, so this cannot
    # start code-server from the external environment. Skipped when degraded.
    export PATH="${COURSE_ENV}/bin:${PATH}"
else
    log "WARNING: no course environment (status=${COURSE_ENV_STATUS:-missing}, prefix=${COURSE_ENV:-unset})."
    log "WARNING: the session will START, but python.defaultInterpreterPath is not set and"
    log "WARNING: course packages are unavailable until the environment is provisioned."
fi

node -e '
const fs = require("fs");
const [seedPath, outPath, coursePython] = process.argv.slice(1);
let seed = {};
if (fs.existsSync(seedPath)) {
  seed = JSON.parse(fs.readFileSync(seedPath, "utf8"));
}
const generated = { "security.workspace.trust.enabled": false };
if (coursePython) { generated["python.defaultInterpreterPath"] = coursePython; }
fs.writeFileSync(outPath, JSON.stringify({ ...seed, ...generated }, null, 2) + "\n");
' "${SEED_SETTINGS}" "${USER_DATA_DIR}/User/settings.json" "${COURSE_PYTHON}" || {
    log "ERROR: could not generate ${USER_DATA_DIR}/User/settings.json"
    exit 1
}

log "starting code-server"

# PASSWORD is read from the environment by code-server itself, so the
# credential never appears in argv where /proc would expose it to other users.
#
# --extensions-dir and --user-data-dir must stay distinct: pointing
# --extensions-dir at /state would hide the image-owned extensions.
#
# exec so code-server becomes the container's first process and receives
# scancel directly.
exec code-server \
    --auth=password \
    --bind-addr="0.0.0.0:${CODE_SERVER_PORT}" \
    --extensions-dir=/opt/code-server/extensions \
    --user-data-dir="${USER_DATA_DIR}" \
    --disable-update-check \
    --disable-telemetry \
    --ignore-last-opened \
    "${HOME}"
