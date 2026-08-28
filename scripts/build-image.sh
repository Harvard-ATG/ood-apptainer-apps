#!/usr/bin/env bash
# Builds one immutable image artifact with checksum and metadata sidecars.
#
#   scripts/build-image.sh jupyter-codeserver-ai/jupyterlab
#   scripts/build-image.sh jupyter-codeserver-ai/codeserver
#
# Produces <app>-<UTC timestamp>-<short commit>.sif alongside a .sha256 and a
# .metadata file. Deployment copies all three and verifies the checksum; the
# committed sub-app path identifies the artifact, and the sidecars establish its
# provenance.

set -euo pipefail

this_script="scripts/build-image.sh"

log() {
    echo -e "[$(date -Iseconds)][${this_script}] $1"
}

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGES_ROOT="${REPO_ROOT}/images"

# The architecture the cluster runs, in `uname -m` form -- the vocabulary ops
# staff and the rest of this repo use. An artifact that does not match is not
# publishable, however useful the build was for validating the definition.
TARGET_ARCH="${OOD_AI_TARGET_ARCH:-x86_64}"

# Apptainer's own build-arch label is written in Go/Docker arch names
# (amd64, arm64), not `uname -m` names (x86_64, aarch64). Normalize both sides
# to the same vocabulary before comparing, rather than requiring callers to
# know which spelling the label uses.
normalize_arch() {
    case "$1" in
        x86_64 | amd64) echo amd64 ;;
        aarch64 | arm64) echo arm64 ;;
        *) echo "$1" ;;
    esac
}

usage() {
    echo "usage: $0 <family>/<app>" >&2
    echo "  e.g. $0 jupyter-codeserver-ai/jupyterlab" >&2
    exit 64
}

[ $# -eq 1 ] || usage
TARGET="$1"
FAMILY="${TARGET%%/*}"
APP="${TARGET##*/}"
[ -n "$FAMILY" ] && [ -n "$APP" ] && [ "$FAMILY" != "$TARGET" ] || usage

DEF="${IMAGES_ROOT}/${FAMILY}/${APP}/${APP}.def"
if [ ! -f "$DEF" ]; then
    log "ERROR: no definition at ${DEF}"
    exit 1
fi

VERSIONS="${IMAGES_ROOT}/${FAMILY}/common/versions.env"
if [ ! -f "$VERSIONS" ]; then
    log "ERROR: no versions.env at ${VERSIONS}"
    exit 1
fi

# A release artifact must be traceable to an exact commit, so the worktree has
# to be clean. Validation builds can be done directly with apptainer build.
if [ -n "$(cd "$REPO_ROOT" && git status --porcelain)" ]; then
    log "ERROR: worktree is dirty; a release artifact must be traceable to a commit"
    (cd "$REPO_ROOT" && git status --short) >&2
    exit 1
fi

COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT_DIR="${OOD_AI_OUTPUT_DIR:-${REPO_ROOT}/build}"
SIF="${OUT_DIR}/${APP}-${STAMP}-${COMMIT}.sif"

mkdir -p "$OUT_DIR"
if [ -e "$SIF" ]; then
    log "ERROR: ${SIF} already exists; artifacts are immutable and never overwritten"
    exit 1
fi

# Apptainer's build scratch defaults to /tmp, which on a compute node is a small
# nodev tmpfs. Point it at real disk and fail early if that is not writable.
BUILD_SCRATCH="${OOD_AI_BUILD_SCRATCH:-/scratch/$(id -nu)/apptainer-build}"
# mkdir's own stderr is deliberately NOT discarded. It carries the one thing
# worth having here -- whether the path is read-only, absent, over quota or
# permission-denied -- and on a cluster node that is expensive to work out any
# other way. The messages below add the remedy, they do not replace it.
if ! mkdir -p "${BUILD_SCRATCH}/tmp" "${BUILD_SCRATCH}/cache"; then
    log "ERROR: cannot create build scratch at ${BUILD_SCRATCH}"
    log "  set OOD_AI_BUILD_SCRATCH to a writable path on real disk"
    exit 1
fi
export APPTAINER_TMPDIR="${BUILD_SCRATCH}/tmp"
export APPTAINER_CACHEDIR="${BUILD_SCRATCH}/cache"
log "build scratch ${BUILD_SCRATCH}"

# Warn about an architecture mismatch BEFORE the build, not after it. The
# authoritative check is on the artifact below -- a cross-build would sail past
# a host check -- but that one runs after a multi-gigabyte, ~20-minute build
# and then deletes what it rejects. On an arm build host that silently destroys
# every artifact unless OOD_AI_TARGET_ARCH is set, with no hint until the end.
#
# A warning, not a refusal: building on a different architecture is a
# legitimate way to validate a definition. Compared through normalize_arch, so
# this stays a comparison against TARGET_ARCH rather than a hardcoded arch.
HOST_ARCH=$(uname -m)
if [ "$(normalize_arch "$HOST_ARCH")" != "$(normalize_arch "$TARGET_ARCH")" ]; then
    log "WARNING: build host is ${HOST_ARCH} but the target is ${TARGET_ARCH}"
    log "  the artifact will be REFUSED and deleted once the build completes"
    log "  to keep it, set OOD_AI_TARGET_ARCH=${HOST_ARCH}; otherwise build on a ${TARGET_ARCH} host"
fi

log "building ${TARGET} -> ${SIF}"
( cd "${IMAGES_ROOT}/${FAMILY}" && apptainer build --fakeroot "$SIF" "$DEF" )

# Check the ARTIFACT's architecture, not the build host's. A cross-build would
# otherwise pass a host check and produce something the cluster cannot run.
# Read it from the SIF's own metadata: `apptainer exec` is not usable here,
# because running a foreign-architecture binary is exactly what fails.
ARTIFACT_ARCH=$(apptainer inspect --json "$SIF" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("data",{}).get("attributes",{}).get("labels",{}).get("org.label-schema.build-arch",""))')
if [ -z "$ARTIFACT_ARCH" ]; then
    log "ERROR: cannot determine the artifact architecture from ${SIF}"
    exit 1
fi
if [ "$(normalize_arch "$ARTIFACT_ARCH")" != "$(normalize_arch "$TARGET_ARCH")" ]; then
    log "ERROR: artifact architecture ${ARTIFACT_ARCH} does not match target ${TARGET_ARCH}"
    log "  the build is useful for validating the definition but must not be published"
    rm -f "$SIF"
    exit 1
fi

sha256sum "$SIF" > "${SIF}.sha256"

{
    echo "artifact=$(basename "$SIF")"
    echo "family=${FAMILY}"
    echo "app=${APP}"
    echo "git_commit=$(git -C "$REPO_ROOT" rev-parse HEAD)"
    echo "build_timestamp=${STAMP}"
    echo "build_arch=${ARTIFACT_ARCH}"
    echo "build_command=apptainer build --fakeroot $(basename "$SIF") ${APP}/${APP}.def"
    echo "definition_sha256=$(sha256sum "$DEF" | cut -d' ' -f1)"
    echo "recipe_sha256=$(sha256sum "${IMAGES_ROOT}/${FAMILY}/common/install-ai-agents.sh" | cut -d' ' -f1)"
    echo "versions_sha256=$(sha256sum "$VERSIONS" | cut -d' ' -f1)"
    grep -vE '^\s*#|^\s*$' "$VERSIONS" | sed 's/^/pin_/'
} > "${SIF}.metadata"

log "built ${SIF}"
log "  sha256   ${SIF}.sha256"
log "  metadata ${SIF}.metadata"
