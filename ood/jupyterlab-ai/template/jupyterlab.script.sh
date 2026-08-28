#!/usr/bin/env bash
# Runs INSIDE the container. Staged by OOD from template/, so it is a plain
# script rather than an ERB template and must stay mode 0755.
#
# Every value below arrives through the mode-0600 environment file. Nothing is
# read from the host environment, because --cleanenv discards it.

set -u

this_script="template/jupyterlab.script.sh"

log() {
    echo -e "[$(date -Iseconds)][${this_script}] $1"
}

log "container HOME=${HOME}"
log "course environment=${COURSE_ENV}"

KERNEL_DIR="${JUPYTER_DATA_DIR:-/state/jupyter/data}/kernels"
CONFIG_DIR="${JUPYTER_CONFIG_DIR:-/state/jupyter/config}"
IMAGE_PYTHON=/opt/conda/bin/python

# JUPYTER_PATH makes these kernelspecs discoverable; the image installs no
# ipykernel kernelspec of its own.
mkdir -p "${KERNEL_DIR}" "${CONFIG_DIR}" || {
    log "ERROR: cannot create the job-local Jupyter directories"
    exit 1
}

# write_kernel <id> <display name> <interpreter>
write_kernel() {
    mkdir -p "${KERNEL_DIR}/$1" || return 1
    cat > "${KERNEL_DIR}/$1/kernel.json" <<JSON
{
  "argv": ["$3", "-m", "ipykernel_launcher", "-f", "{connection_file}"],
  "display_name": "$2",
  "language": "python",
  "metadata": {"debugger": true}
}
JSON
}

# usable <prefix> -- can this prefix actually back a kernel?
#
# Run here, in the container, rather than on the host: the compute node and the
# image do not share a libc, so a prefix that runs on one can fail on the other.
# The import is the real question -- a kernel whose interpreter cannot import
# ipykernel registers fine and then dies at every start, which reads to a
# student as "JupyterLab is broken" rather than "the environment is broken".
usable() {
    [ -n "$1" ] && [ -x "$1/bin/python" ] && "$1/bin/python" -c 'import ipykernel' >/dev/null 2>&1
}

# The image kernel is generated unconditionally and is never the default while a
# course kernel exists. It exists so that an unprovisioned or broken course
# environment leaves a usable session instead of an empty one.
write_kernel image-python "Python 3 (image - no course packages)" "${IMAGE_PYTHON}" || {
    log "ERROR: cannot write the image kernelspec"
    exit 1
}
ALLOWED='"image-python"'
DEFAULT_KERNEL=image-python

if [ "${COURSE_ENV_STATUS:-missing}" = ok ] && usable "${COURSE_ENV}"; then
    write_kernel course-python "Course Python" "${COURSE_ENV}/bin/python" || {
        log "ERROR: cannot write the course kernelspec"
        exit 1
    }
    ALLOWED="${ALLOWED}, \"course-python\""
    DEFAULT_KERNEL=course-python
    # Prepend the course environment to the terminal PATH. The server itself is
    # started from its image-owned absolute path below, so this cannot cause
    # JupyterLab to be launched from the external environment. In a degraded
    # session this is deliberately skipped: prepending a directory that does not
    # work helps nobody.
    export PATH="${COURSE_ENV}/bin:${PATH}"
    log "course kernel ready: ${COURSE_ENV}"
else
    log "WARNING: no course kernel (status=${COURSE_ENV_STATUS:-missing}, prefix=${COURSE_ENV:-unset})."
    log "WARNING: this session offers only 'Python 3 (image - no course packages)'."
    log "WARNING: the course environment must be provisioned or repaired by teaching staff or ATG."
fi

# Staging is a staff affordance and Jupyter-only. Eligibility is a writability
# test against the environment root, never a group-name test: the staff group is
# unnameable inside the container.
if [ -n "${COURSE_ENV_STAGING:-}" ] && [ -w "${ENVIRONMENT_ROOT:-/nonexistent}" ] \
   && usable "${COURSE_ENV_STAGING}"; then
    write_kernel course-python-staging "Course Python (STAGING)" \
        "${COURSE_ENV_STAGING}/bin/python" || {
        log "ERROR: cannot write the staging kernelspec"
        exit 1
    }
    ALLOWED="${ALLOWED}, \"course-python-staging\""
    log "staging kernel ready: ${COURSE_ENV_STAGING}"
fi

# allowed_kernelspecs is built from what was actually generated, so it can never
# name a kernel that is not on disk. default_kernel_name is what makes the
# course kernel *preferred* rather than merely present: a notebook created
# without an explicit kernel gets it. The trait is declared on
# MultiKernelManager and reaches the server's MappingKernelManager subclass
# through the ordinary traitlets class-hierarchy lookup.
cat > "${CONFIG_DIR}/jupyter_server_config.py" <<CFG || { log "ERROR: cannot write the Jupyter config"; exit 1; }
c = get_config()  # noqa: F821
c.KernelSpecManager.allowed_kernelspecs = {${ALLOWED}}
c.MultiKernelManager.default_kernel_name = "${DEFAULT_KERNEL}"
CFG

log "kernels: ${ALLOWED}; default=${DEFAULT_KERNEL}"

log "starting JupyterLab"

# exec so JupyterLab becomes the container's first process: scancel and
# walltime expiry then reach it directly and the job releases its allocation
# promptly. The credential passed here is the SHA1 hash, never the plaintext.
#
# The ABSOLUTE image-owned path is deliberate, and load-bearing twice over. The
# environment file's PATH is /usr/local/bin:/usr/bin:/bin, which does NOT
# include /opt/conda/bin -- so a bare `jupyter` would either not resolve at all
# or, worse, resolve to ${COURSE_ENV}/bin/jupyter after the export above, which
# is exactly the external-environment launch the comment at the top of this
# block rules out. /opt/conda/bin is kept off PATH on purpose: students get a
# terminal in JupyterLab, and the image's conda bin on their PATH would make
# `python` resolve to the image interpreter instead of the course environment.
exec /opt/conda/bin/jupyter lab \
    --ip=0.0.0.0 \
    --port="${MY_JUP_PORT}" \
    --port-retries=0 \
    --no-browser \
    --ServerApp.base_url="${MY_JUP_BASEURL}" \
    --ServerApp.PasswordIdentityProvider.hashed_password="${MY_JUP_PASSWD}" \
    --ServerApp.allow_origin='*' \
    --ServerApp.disable_check_xsrf=True \
    --ServerApp.root_dir="${HOME}"
