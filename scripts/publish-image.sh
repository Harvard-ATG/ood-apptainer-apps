#!/usr/bin/env bash
# scripts/publish-image.sh
# Publishes one already-built artifact to the cross-account S3 bucket, so a
# second AWS account (a different cluster, a separate set of resources) can
# promote the exact same bytes with scripts/promote-image.sh, instead of
# rebuilding the same commit and getting a differently-timestamped artifact.
#
#   scripts/publish-image.sh [--dry-run] build/jupyterlab-20260828T030141Z-4e73009.sif
#
# Takes the same argument shape as deploy-image.sh, any path to a built .sif
# with its two sidecars beside it, so the artifact you just handed to
# deploy-image.sh is the same one you hand to this script.
#
# Requires an active AWS identity with s3:PutObject AND s3:GetObject on the
# bucket. GetObject is not optional: without it the immutability check below
# cannot read whether a name is already taken, and a publish that cannot check
# is refused rather than allowed to overwrite. Run `aws login --remote` first,
# and `aws logout` when you are done.
set -uo pipefail

this_script="scripts/publish-image.sh"

log() {
    echo -e "[$(date -Iseconds)][${this_script}] $1"
}

fail() {
    log "ERROR: $1"
    exit 1
}

# The bucket already holds other teams' images at its top level, for example
# apptainerImages/datascience-notebook.sif. Everything this repo publishes goes
# under its own family directory, mirroring the local canonical image root's
# <family>/<artifact> layout.
: "${OOD_APPTAINER_S3_BUCKET:=ood-software}"
: "${OOD_APPTAINER_S3_PREFIX:=apptainerImages}"

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

# All three or nothing, exactly as in deploy-image.sh. An artifact published
# without its sidecars cannot be promoted: the far side reads the family out of
# the metadata and the checksum out of the .sha256.
[ -f "${SRC_DIR}/${ARTIFACT}.sha256" ] \
    || fail "no checksum sidecar at '${SRC_DIR}/${ARTIFACT}.sha256'"
[ -f "${SRC_DIR}/${ARTIFACT}.metadata" ] \
    || fail "no metadata sidecar at '${SRC_DIR}/${ARTIFACT}.metadata'"

# The destination directory comes from the metadata, never from the artifact
# name. The name carries a timestamp and a commit, not a family.
FAMILY=$(sed -n 's/^family=//p' "${SRC_DIR}/${ARTIFACT}.metadata" | head -1)
[ -n "$FAMILY" ] || fail "'${SRC_DIR}/${ARTIFACT}.metadata' names no family"

KEY_DIR="${OOD_APPTAINER_S3_PREFIX}/${FAMILY}"
DEST="s3://${OOD_APPTAINER_S3_BUCKET}/${KEY_DIR}"

# One check, on the artifact only, so an accidental re-run says so plainly
# instead of silently overwriting. A "not found" is the only failure that means
# it is safe to proceed: anything else (no GetObject permission, no region, a
# transient error) would otherwise disable this guard silently, and a silent
# overwrite is the one failure this whole design cannot survive.
if HEAD_ERROR=$(aws s3api head-object \
    --bucket "$OOD_APPTAINER_S3_BUCKET" \
    --key "${KEY_DIR}/${ARTIFACT}" 2>&1); then
    fail "${DEST}/${ARTIFACT} already exists; artifacts are immutable and never overwritten"
elif ! printf '%s' "$HEAD_ERROR" | grep -qi '404\|Not Found'; then
    fail "cannot check whether ${DEST}/${ARTIFACT} already exists: ${HEAD_ERROR}"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    log "would publish ${ARTIFACT} and both sidecars to ${DEST}/"
    exit 0
fi

# Verified before the first upload, not after. The destination name can never
# be reused, so publishing a corrupt artifact would burn that name for good.
( cd "$SRC_DIR" && sha256sum -c "${ARTIFACT}.sha256" >/dev/null ) \
    || fail "'${SRC_DIR}/${ARTIFACT}' does not match its checksum sidecar"

DIGEST=$(cut -d' ' -f1 "${SRC_DIR}/${ARTIFACT}.sha256")
log "verified digest: ${DIGEST}"

# Sidecars first, artifact last. Any failure part-way through then leaves the
# .sif itself absent, so the immutability guard above still permits a retry,
# and re-uploading the two tiny sidecars a second time is a harmless no-op.
# The artifact object's presence in the bucket becomes a truthful marker that
# the publish completed -- reversing this order would let a half-published
# artifact sit there looking exactly like a finished one.
for f in "${ARTIFACT}.sha256" "${ARTIFACT}.metadata" "${ARTIFACT}"; do
    log "publishing ${f} to ${DEST}/${f}"
    aws s3 cp --only-show-errors "${SRC_DIR}/${f}" "${DEST}/${f}" \
        || fail "upload of '${f}' failed; if this is a credentials error, run 'aws login --remote' first"
done

log "published ${ARTIFACT} to ${DEST}/${ARTIFACT}"
log "on the other environment, after 'aws login --remote':"
log "  scripts/promote-image.sh ${FAMILY}/${ARTIFACT}"
log "run 'aws logout' when you are done here"
