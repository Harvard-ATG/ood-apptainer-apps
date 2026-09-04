#!/usr/bin/env bash
# tests/test-promote-image.sh
# Behavioural: a promote is a download plus a call to deploy-image.sh, so a
# fake bucket directory and two temporary image roots exercise both real
# scripts end to end.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

S=../scripts/promote-image.sh

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ood-promote-test-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Same stub as tests/test-publish-image.sh. Fixed argument positions, because
# it only ever serves the two call shapes these two scripts actually use.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/aws" <<'STUB'
#!/bin/sh
case "$1 $2" in
    "s3api head-object")    # aws s3api head-object --bucket B --key K
        # AWS_STUB_HEAD_ERROR lets a test pick a non-404 failure. Unused by
        # promote-image.sh itself, but kept identical to the publish stub so
        # the two test files (and the e2e suite) share one stub behavior.
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

FAMILY="jupyter-codeserver-ai"
NAME="jupyterlab-20260828T030141Z-4e73009"
PUBLISHED="$FAKE_S3_ROOT/ood-software/apptainerImages/$FAMILY"

# Seed the fake bucket as if scripts/publish-image.sh had already run.
mkdir -p "$PUBLISHED"
printf 'not really a sif\n' > "$PUBLISHED/$NAME.sif"
( cd "$PUBLISHED" && sha256sum "$NAME.sif" > "$NAME.sif.sha256" )
{
    echo "artifact=$NAME.sif"
    echo "family=$FAMILY"
    echo "app=jupyterlab"
} > "$PUBLISHED/$NAME.sif.metadata"

CANONICAL="$WORK/shared/apptainerImages"
FAST="$WORK/scratch/apptainerImages"
SCRIPT_TMP="$WORK/tmp"
mkdir -p "$SCRIPT_TMP"

# TMPDIR is pointed at a directory this test owns, so the "cleans up after
# itself" assertion below is exact rather than a guess about /tmp.
promote() {  # <args...>
    TMPDIR="$SCRIPT_TMP" \
    OOD_APPTAINER_IMAGE_ROOT_CANONICAL="$CANONICAL" \
    OOD_APPTAINER_IMAGE_ROOT_FAST="$FAST" \
        bash "$S" "$@" 2>&1
}

it "promote-image.sh exists and is executable"
assert_success test -x "$S"

it "it rejects an argument with no family"
assert_contains "$(promote nofamilyhere.sif)" "not <family>/<artifact>"

it "it rejects an argument with more than one slash"
assert_contains "$(promote "extra/$FAMILY/$NAME.sif")" "not <family>/<artifact>"

it "it rejects an unknown flag"
assert_contains "$(promote --nope)" "usage"

it "it fails, naming the file, when the artifact was never published"
# The sidecar is downloaded first now, so a never-published artifact fails on
# the .sha256, not the .sif -- see the reorder comment in promote-image.sh.
assert_contains "$(promote "$FAMILY/nope.sif")" "download of 'nope.sif.sha256' failed; the artifact may be only partly published"

it "a clean promote succeeds"
out=$(promote "$FAMILY/$NAME.sif")
status=$?
if [ "$status" -eq 0 ]; then _pass; else _fail "$out"; fi

it "it lands the artifact and both sidecars in the canonical root"
assert_success test -f "$CANONICAL/$FAMILY/$NAME.sif"
assert_success test -f "$CANONICAL/$FAMILY/$NAME.sif.sha256"
assert_success test -f "$CANONICAL/$FAMILY/$NAME.sif.metadata"

it "it lands the artifact in the fast root too"
assert_success test -f "$FAST/$FAMILY/$NAME.sif"

it "it logs the digest it is deploying"
assert_contains "$out" "deploying digest:"

it "it reminds you to log out"
assert_contains "$out" "aws logout"

# Guards the one subtle thing about the hand-off: deploy-image.sh is called,
# not exec'd, so the EXIT trap still runs after it returns.
it "it removes its temporary download directory"
assert_eq "$(ls -A "$SCRIPT_TMP")" ""

it "re-promoting refuses, through deploy-image.sh's own immutability check"
out=$(promote "$FAMILY/$NAME.sif")
status=$?
assert_contains "$out" "already exists"

it "re-promoting exits nonzero"
if [ "$status" -ne 0 ]; then _pass; else _fail "expected a nonzero exit, got 0"; fi

finish
