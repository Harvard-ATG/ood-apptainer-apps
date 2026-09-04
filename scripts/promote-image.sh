#!/usr/bin/env bash
# scripts/promote-image.sh
# Pulls one artifact scripts/publish-image.sh already put in the shared S3
# bucket, then hands it to deploy-image.sh unmodified. A second AWS account
# gets byte-identical images, and every check deploy-image.sh already makes
# (checksum, immutability, both image roots) applies here too, with nothing
# duplicated.
#
#   scripts/promote-image.sh jupyter-codeserver-ai/jupyterlab-20260828T030141Z-4e73009.sif
#
# The argument is <family>/<artifact>, the same relative form lc_select_image
# and --image already use. Unlike deploy-image.sh's argument, there is no local
# file yet to read a family out of.
#
# Requires an active AWS identity with s3:GetObject on the bucket. Run
# `aws login --remote` first, and `aws logout` when you are done. That identity
# does not need to belong to the AWS account this cluster's other resources
# live in: S3 access follows the authenticated identity, not the network the
# request comes from.
#
# Downloads into $TMPDIR (or /tmp if unset) before handing off to
# deploy-image.sh. On a login node, /tmp is shared with everyone logged in, so
# if it is small, point TMPDIR at a directory you own before running this.
set -uo pipefail

this_script="scripts/promote-image.sh"

log() {
    echo -e "[$(date -Iseconds)][${this_script}] $1"
}

fail() {
    log "ERROR: $1"
    exit 1
}

: "${OOD_APPTAINER_S3_BUCKET:=ood-software}"
: "${OOD_APPTAINER_S3_PREFIX:=apptainerImages}"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

usage() {
    echo "usage: $0 <family>/<artifact>" >&2
    echo "  e.g. $0 jupyter-codeserver-ai/jupyterlab-20260828T030141Z-4e73009.sif" >&2
    exit 64
}

[ $# -eq 1 ] || usage
case "$1" in -*) usage ;; esac

FAMILY="${1%%/*}"
ARTIFACT="${1##*/}"

# Exactly one slash, with something on each side. Rebuilding the argument is
# the whole test: "a/b/c.sif" gives back "a/c.sif", and "a/" or "/b" leaves one
# side empty. A typo here would otherwise surface as an S3 404 further down.
if [ -z "$FAMILY" ] || [ -z "$ARTIFACT" ] || [ "${FAMILY}/${ARTIFACT}" != "$1" ]; then
    fail "'$1' is not <family>/<artifact>"
fi

SRC="s3://${OOD_APPTAINER_S3_BUCKET}/${OOD_APPTAINER_S3_PREFIX}/${FAMILY}"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/ood-promote-XXXXXX") \
    || fail "cannot create a temporary working directory"
trap 'rm -rf "$WORKDIR"' EXIT

# A missing object, an expired login and a failed transfer all come back from
# aws with a clear message, so there is no pre-flight check here. The failure
# message adds two hints, because those are the causes an operator misreads.
#
# Sidecars first, artifact last -- the same order publish-image.sh uploads in.
# A publish that died part-way through leaves the sidecars in the bucket with
# no .sif, so this order fails on a tiny download instead of after pulling a
# multi-gigabyte artifact that deploy-image.sh would refuse anyway.
for f in "${ARTIFACT}.sha256" "${ARTIFACT}.metadata" "${ARTIFACT}"; do
    log "downloading ${SRC}/${f}"
    aws s3 cp --only-show-errors "${SRC}/${f}" "${WORKDIR}/${f}" \
        || fail "download of '${f}' failed; the artifact may be only partly published, or run 'aws login --remote' if this is a credentials error"
done

DIGEST=$(cut -d' ' -f1 "${WORKDIR}/${ARTIFACT}.sha256")
log "deploying digest: ${DIGEST}"

# deploy-image.sh re-verifies the checksum before it copies anywhere, so
# nothing here repeats that check. A corrupt download fails there, with that
# script's own message, before either image root is touched.
log "when this finishes, run 'aws logout'"

# Called rather than exec'd, on purpose: its exit status becomes this script's,
# and the EXIT trap above still removes WORKDIR afterwards.
log "deploying ${ARTIFACT} with scripts/deploy-image.sh"
"${REPO_ROOT}/scripts/deploy-image.sh" "${WORKDIR}/${ARTIFACT}"
