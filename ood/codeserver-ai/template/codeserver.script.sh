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
mkdir -p "${USER_DATA_DIR}/User"

# Seed the machine settings from the image, then point the Python extension at
# the course interpreter. Generated at launch so the course path is not baked
# into the shared image. Workspace trust is restored on every launch, so a user
# change lasts only for the session.
if [ -r /etc/code-server/settings.json ]; then
    cp /etc/code-server/settings.json "${USER_DATA_DIR}/User/settings.json"
fi
cat > "${USER_DATA_DIR}/User/settings.json" <<SETTINGS
{
  "python.defaultInterpreterPath": "${COURSE_ENV}/bin/python",
  "security.workspace.trust.enabled": false
}
SETTINGS

# Prepend the course environment to the terminal PATH. The server itself comes
# from its image-owned location, so this cannot start code-server from the
# external environment.
export PATH="${COURSE_ENV}/bin:${PATH}"

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
