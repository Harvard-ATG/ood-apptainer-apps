#!/usr/bin/env bash
# tests/test-image-promotion-e2e.sh
# Integration test: the real publish-image.sh and the real promote-image.sh,
# run back to back against one fake bucket. Neither script's destination path
# is defined in any shared library, so this is the one test that would catch
# the two scripts (or their two independent test seeds) drifting apart on the
# <prefix>/<family>/<artifact> layout.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

PUBLISH=../scripts/publish-image.sh
PROMOTE=../scripts/promote-image.sh

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ood-promotion-e2e-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Same stub as tests/test-publish-image.sh and tests/test-promote-image.sh.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/aws" <<'STUB'
#!/bin/sh
case "$1 $2" in
    "s3api head-object")    # aws s3api head-object --bucket B --key K
        if [ -n "${AWS_STUB_HEAD_ERROR:-}" ]; then
            echo "$AWS_STUB_HEAD_ERROR" >&2
            exit 1
        fi
        if test -f "${FAKE_S3_ROOT}/$4/$6"; then
            exit 0
        else
            echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2
            exit 1
        fi
        ;;
    "s3 cp")                # aws s3 cp --only-show-errors SRC DST
        case "$5" in
            s3://*)
                dst="${FAKE_S3_ROOT}/${5#s3://}"
                mkdir -p "$(dirname "$dst")"
                cp "$4" "$dst"
                ;;
            *)
                src="${FAKE_S3_ROOT}/${4#s3://}"
                [ -f "$src" ] || { echo "fatal error: object does not exist" >&2; exit 1; }
                cp "$src" "$5"
                ;;
        esac
        ;;
    *)
        echo "unstubbed aws invocation: $*" >&2
        exit 1
        ;;
esac
STUB
chmod 755 "$BIN/aws"
export PATH="$BIN:$PATH"
export FAKE_S3_ROOT="$WORK/fake-s3"
mkdir -p "$FAKE_S3_ROOT/ood-software"

# Step 1: build a fake artifact with its two sidecars, the same shape
# tests/test-deploy-image.sh uses.
BUILD="$WORK/build"
FAMILY="jupyter-codeserver-ai"
NAME="jupyterlab-20260828T030141Z-4e73009"
mkdir -p "$BUILD"
printf 'not really a sif\n' > "$BUILD/$NAME.sif"
( cd "$BUILD" && sha256sum "$NAME.sif" > "$NAME.sif.sha256" )
{
    echo "artifact=$NAME.sif"
    echo "family=$FAMILY"
    echo "app=jupyterlab"
} > "$BUILD/$NAME.sif.metadata"

CANONICAL="$WORK/shared/apptainerImages"
FAST="$WORK/scratch/apptainerImages"
SCRIPT_TMP="$WORK/tmp"
mkdir -p "$SCRIPT_TMP"

it "publish-image.sh and promote-image.sh both exist and are executable"
assert_success test -x "$PUBLISH"
assert_success test -x "$PROMOTE"

# Step 2: run the real publish-image.sh into the fake bucket. Nothing is
# seeded by hand -- the publish is what populates it.
it "publish succeeds"
publish_out=$(bash "$PUBLISH" "$BUILD/$NAME.sif" 2>&1)
publish_status=$?
if [ "$publish_status" -eq 0 ]; then _pass; else _fail "$publish_out"; fi

# Step 3: run the real promote-image.sh out of that same fake bucket.
it "promote succeeds"
promote_out=$(TMPDIR="$SCRIPT_TMP" \
    OOD_APPTAINER_IMAGE_ROOT_CANONICAL="$CANONICAL" \
    OOD_APPTAINER_IMAGE_ROOT_FAST="$FAST" \
    bash "$PROMOTE" "$FAMILY/$NAME.sif" 2>&1)
promote_status=$?
if [ "$promote_status" -eq 0 ]; then _pass; else _fail "$promote_out"; fi

# Step 4: the .sif that landed on the other side is byte-identical to the one
# that was built, and both sidecars made the trip too.
it "the promoted .sif is byte-identical to the source .sif"
assert_success cmp "$BUILD/$NAME.sif" "$CANONICAL/$FAMILY/$NAME.sif"

it "both sidecars arrived in the canonical root"
assert_success test -f "$CANONICAL/$FAMILY/$NAME.sif.sha256"
assert_success test -f "$CANONICAL/$FAMILY/$NAME.sif.metadata"

finish
