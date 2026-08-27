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

# Job-local Jupyter directories. JUPYTER_PATH makes the generated kernelspec
# discoverable; the image installs no ipykernel kernelspec of its own.
mkdir -p "${JUPYTER_CONFIG_DIR:-/state/jupyter/config}" \
         "${JUPYTER_DATA_DIR:-/state/jupyter/data}/kernels"

# Prepend the course environment to the terminal PATH. The server itself is
# started from its image-owned absolute path below, so this cannot cause
# JupyterLab to be launched from the external environment.
export PATH="${COURSE_ENV}/bin:${PATH}"

log "starting JupyterLab"

# exec so JupyterLab becomes the container's first process: scancel and
# walltime expiry then reach it directly and the job releases its allocation
# promptly. The credential passed here is the SHA1 hash, never the plaintext.
exec jupyter lab \
    --ip=0.0.0.0 \
    --port="${MY_JUP_PORT}" \
    --port-retries=0 \
    --no-browser \
    --ServerApp.base_url="${MY_JUP_BASEURL}" \
    --ServerApp.PasswordIdentityProvider.hashed_password="${MY_JUP_PASSWD}" \
    --ServerApp.allow_origin='*' \
    --ServerApp.disable_check_xsrf=True \
    --ServerApp.root_dir="${HOME}"
