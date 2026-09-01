#!/usr/bin/env bash
# Publishes one built artifact to both cluster image roots.
#
#   scripts/deploy-image.sh [--dry-run] build/jupyterlab-20260828T030141Z-4e73009.sif
#
# Copies the artifact and both sidecars to the canonical root (EFS) and then the
# fast root (Lustre), verifying the checksum at each. Deliberately does NOT
# update any sub-app's imagefile: attribute -- that is a commit, reviewed and
# reverted like one, while this is an idempotent filesystem action. The line to
# paste is printed at the end.
#
# A file copy needs no Apptainer and no compute node, so this runs wherever you
# type it.
set -uo pipefail

this_script="scripts/deploy-image.sh"

log() {
    echo -e "[$(date -Iseconds)][${this_script}] $1"
}

fail() {
    log "ERROR: $1"
    exit 1
}

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# For OOD_APPTAINER_IMAGE_ROOT_CANONICAL and _FAST, so the roots are defined in
# one place and a deploy cannot disagree with the launcher about where images
# live.
# shellcheck source=ood/lib/launch-common.sh
. "${REPO_ROOT}/ood/lib/launch-common.sh"
CANONICAL="${OOD_APPTAINER_IMAGE_ROOT_CANONICAL}"
FAST="${OOD_APPTAINER_IMAGE_ROOT_FAST}"

usage() {
    echo "usage: $0 [--dry-run] <path to a built .sif>" >&2
    echo "  e.g. $0 build/jupyterlab-20260828T030141Z-4e73009.sif" >&2
    exit 64
}

DRY_RUN=0
SIF_PATH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -*)        usage ;;
        *)         [ -z "$SIF_PATH" ] || usage; SIF_PATH="$1"; shift ;;
    esac
done

[ -n "$SIF_PATH" ] || usage
[ -f "$SIF_PATH" ] || fail "no artifact at '${SIF_PATH}'"

SRC_DIR=$(cd "$(dirname "$SIF_PATH")" && pwd) || fail "cannot resolve '${SIF_PATH}'"
ARTIFACT=$(basename "$SIF_PATH")

# All three or nothing. The sidecars are what make the artifact traceable, and
# an artifact deployed without them cannot be checked against its build later.
# Requiring them also means only build-image.sh output is publishable.
[ -f "${SRC_DIR}/${ARTIFACT}.sha256" ] \
    || fail "no checksum sidecar at '${SRC_DIR}/${ARTIFACT}.sha256'"
[ -f "${SRC_DIR}/${ARTIFACT}.metadata" ] \
    || fail "no metadata sidecar at '${SRC_DIR}/${ARTIFACT}.metadata'"

# The destination subdirectory comes from the metadata, never from the artifact
# name -- the name carries a timestamp and a commit, not a family, so anything
# derived from it would be a guess.
FAMILY=$(sed -n 's/^family=//p' "${SRC_DIR}/${ARTIFACT}.metadata" | head -1)
[ -n "$FAMILY" ] || fail "'${SRC_DIR}/${ARTIFACT}.metadata' names no family"

FILES=("${ARTIFACT}" "${ARTIFACT}.sha256" "${ARTIFACT}.metadata")

# Immutable at the destination, exactly as build-image.sh is immutable in the
# build directory. A committed imagefile: string identifies one exact build for
# as long as a sub-app names it, which is only true if the name is never reused.
# Both roots are checked before either is written, so a half-refused deploy is
# not a state this can leave behind.
for root in "$CANONICAL" "$FAST"; do
    for f in "${FILES[@]}"; do
        [ -e "${root}/${FAMILY}/${f}" ] \
            && fail "'${root}/${FAMILY}/${f}' already exists; artifacts are immutable and never overwritten"
    done
done

if [ "$DRY_RUN" -eq 1 ]; then
    log "would deploy ${ARTIFACT} and both sidecars to:"
    log "  ${CANONICAL}/${FAMILY}"
    log "  ${FAST}/${FAMILY}"
    exit 0
fi

# Verified before the first copy, not after. The target name can never be
# reused, so publishing a corrupt artifact would burn that name permanently --
# and the canonical root is the one root the launcher does not integrity-check.
( cd "$SRC_DIR" && sha256sum -c "${ARTIFACT}.sha256" >/dev/null ) \
    || fail "'${SRC_DIR}/${ARTIFACT}' does not match its checksum sidecar"

# Mode is set explicitly rather than left to the deploying account's umask: an
# image no student can read fails every session in the course, silently, long
# after the deploy looked successful.
deploy_into() {  # <image root>
    local dest="$1/${FAMILY}"
    mkdir -p "$dest" || return 1
    local f
    for f in "${FILES[@]}"; do
        cp "${SRC_DIR}/${f}" "${dest}/${f}" || return 1
        chmod 0644 "${dest}/${f}" || return 1
    done
    ( cd "$dest" && sha256sum -c "${ARTIFACT}.sha256" >/dev/null )
}

# Canonical first. It is the copy the launcher requires -- a fast copy that
# arrives before it puts every session on the size-mismatch fallback path.
log "deploying ${ARTIFACT} to ${CANONICAL}/${FAMILY}"
deploy_into "$CANONICAL" || fail "could not deploy to the canonical root ${CANONICAL}"

log "deploying ${ARTIFACT} to ${FAST}/${FAMILY}"
if ! deploy_into "$FAST"; then
    log "ERROR: could not deploy to the fast root ${FAST}"
    log "  the canonical deploy is complete and launchable; sessions will take the slower path"
    exit 1
fi

log "deployed ${ARTIFACT} to both image roots"
log "to put it in front of students, set this in the sub-app and commit:"
log "  imagefile: \"${FAMILY}/${ARTIFACT}\""
