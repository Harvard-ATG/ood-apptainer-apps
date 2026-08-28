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

# ---------------------------------------------------------------------------
# Terminal environment.
#
# Apptainer injects TWO variables that put "Apptainer> " in a student's
# terminal, and the second is the one that actually does it:
#
#   PS1="Apptainer> "
#   PROMPT_COMMAND='PS1="Apptainer> "; unset PROMPT_COMMAND'
#
# Every child process inherits both. Bash reads /etc/bash.bashrc and sets a
# normal Debian prompt -- and then runs PROMPT_COMMAND before displaying the
# first prompt, which overwrites PS1 and deletes itself. So the rc files do NOT
# save us: a completely ordinary interactive bash still shows the container
# prompt. PS1 alone matters for shells that read no rc files at all (sh/dash).
# Both are removed here, so the worst case is a shell falling back to its own
# default prompt rather than showing a container implementation detail.
unset PS1 PROMPT_COMMAND

# Make the terminal shell explicit rather than inherited. Both apps fall back to
# a bare `sh` when SHELL is unset -- and dash is exactly the shell that would
# have shown the inherited prompt. Deliberately NOT a login shell: /etc/profile
# resets PATH, which would discard the course-environment prepend below.
export SHELL=/bin/bash

USER_DATA_DIR=/state/code-server
SEED_SETTINGS=/etc/code-server/settings.json
mkdir -p "${USER_DATA_DIR}/User" || { log "ERROR: cannot create ${USER_DATA_DIR}/User"; exit 1; }

# usable <prefix> -- does this prefix's interpreter actually RUN?
#
# Run here, in the container, rather than on the host: the compute node and the
# image do not share a libc, so a prefix that runs on one can fail on the other.
# That is why lc_classify_course_env deliberately stops at `[ -x ]` and leaves
# this question to the launcher.
#
# `[ -x ]` alone is not the question. A default/bin/python that exists and is
# executable but dies on invocation is the shape of a course environment broken
# by a failed staff update, and pointing python.defaultInterpreterPath at it is
# worse than leaving VS Code to its own discovery: the setting LOOKS configured,
# so nothing looks wrong. Unlike the JupyterLab side this asks nothing about
# ipykernel -- code-server's Python extension has no such requirement -- so
# `-c 'import sys'` is the whole question.
usable() {
    [ -n "$1" ] && [ -x "$1/bin/python" ] && "$1/bin/python" -c 'import sys' >/dev/null 2>&1
}

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
if [ "${COURSE_ENV_STATUS:-missing}" = ok ] && usable "${COURSE_ENV}"; then
    COURSE_PYTHON="${COURSE_ENV}/bin/python"
    # Prepend the course environment so the integrated terminal resolves
    # `python` and the course's own entry points. Note what this means: the
    # FIRST element of PATH is now a staff-writable directory on a shared
    # filesystem. That is why the exec below names the server by its absolute
    # image-owned path -- see the comment there. Skipped when degraded:
    # prepending a directory that does not work helps nobody.
    export PATH="${COURSE_ENV}/bin:${PATH}"
else
    log "WARNING: no usable course environment (status=${COURSE_ENV_STATUS:-missing}, prefix=${COURSE_ENV:-unset})."
    log "WARNING: the session will START, but python.defaultInterpreterPath is NOT set, the"
    log "WARNING: terminal PATH does not include the course environment, and course packages"
    log "WARNING: are unavailable until the environment is provisioned or repaired by teaching"
    log "WARNING: staff or ATG."
fi

node -e '
const fs = require("fs");
const [seedPath, outPath, coursePython] = process.argv.slice(1);
let seed = {};
if (fs.existsSync(seedPath)) {
  seed = JSON.parse(fs.readFileSync(seedPath, "utf8"));
}
const generated = {
  "security.workspace.trust.enabled": false,
  // Pin the integrated terminal to bash. VS Code otherwise auto-detects a
  // profile, and a bare sh inherits the PS1 that Apptainer exports.
  // NOTE: no apostrophes in this block -- it sits inside a single-quoted shell
  // string, so one would terminate the string and break the launcher.
  "terminal.integrated.defaultProfile.linux": "bash",
};
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
#
# The ABSOLUTE image-owned path is deliberate and load-bearing. Above, this
# script prepends ${COURSE_ENV}/bin to PATH, making a staff-writable directory
# on a shared filesystem the FIRST place a bare command name resolves. A file
# named `code-server` placed there -- by a mistaken staff install, or
# otherwise -- would then be started in place of the image's server, with the
# session's own credential in its environment. /usr/local/bin/code-server is
# the image's symlink into /usr/local/lib/code-server, and it is not reachable
# from the course environment. jupyterlab.script.sh execs /opt/conda/bin/jupyter
# for exactly the same reason.
exec /usr/local/bin/code-server \
    --auth=password \
    --bind-addr="0.0.0.0:${CODE_SERVER_PORT}" \
    --extensions-dir=/opt/code-server/extensions \
    --user-data-dir="${USER_DATA_DIR}" \
    --disable-update-check \
    --disable-telemetry \
    --ignore-last-opened \
    "${HOME}"
