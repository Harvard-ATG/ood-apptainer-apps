#!/usr/bin/env bash
# tests/test-publish-image.sh
# Behavioural, not source-text: a publish is a file copy, so the fake bucket is
# a directory tree and the real script runs unchanged against a stubbed aws.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

S=../scripts/publish-image.sh

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ood-publish-test-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# A fake AWS CLI. The bucket is a directory tree under $FAKE_S3_ROOT. Argument
# positions are fixed rather than parsed, because this stub only ever serves
# the two call shapes publish-image.sh and promote-image.sh actually use.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/aws" <<'STUB'
#!/bin/sh
case "$1 $2" in
    "s3api head-object")    # aws s3api head-object --bucket B --key K
        # AWS_STUB_HEAD_ERROR lets a test pick a non-404 failure (e.g. an
        # AccessDenied), to exercise the "cannot check" path separately from
        # the ordinary "object absent" path.
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

# A stand-in for build-image.sh's output, the same shape tests/test-deploy-image.sh uses.
make_artifact() {  # <build dir> <family> <artifact name, no extension>
    mkdir -p "$1"
    printf 'not really a sif\n' > "$1/$3.sif"
    ( cd "$1" && sha256sum "$3.sif" > "$3.sif.sha256" )
    {
        echo "artifact=$3.sif"
        echo "family=$2"
        echo "app=jupyterlab"
    } > "$1/$3.sif.metadata"
}

BUILD="$WORK/build"
FAMILY="jupyter-codeserver-ai"
NAME="jupyterlab-20260828T030141Z-4e73009"
PUBLISHED="$FAKE_S3_ROOT/ood-software/apptainerImages/$FAMILY"
make_artifact "$BUILD" "$FAMILY" "$NAME"

it "publish-image.sh exists and is executable"
assert_success test -x "$S"

it "it rejects a missing artifact"
assert_contains "$(bash "$S" "$BUILD/nope.sif" 2>&1)" "no artifact"

it "it rejects an unknown flag"
assert_contains "$(bash "$S" --nope 2>&1)" "usage"

it "it rejects an artifact whose metadata names no family"
NOFAM="$WORK/build-nofamily"
make_artifact "$NOFAM" "$FAMILY" "$NAME"
: > "$NOFAM/$NAME.sif.metadata"
assert_contains "$(bash "$S" "$NOFAM/$NAME.sif" 2>&1)" "names no family"

# From here on, the blocks share one workspace and one fake bucket, and that
# is deliberate: bucket state IS what is under test. Order matters -- each
# block builds on the bucket state the previous one left, so reordering them
# silently changes what they prove (e.g. "--dry-run uploads nothing" would
# become vacuous run after the artifact is already published).

it "--dry-run uploads nothing"
bash "$S" --dry-run "$BUILD/$NAME.sif" >/dev/null 2>&1
assert_failure test -f "$PUBLISHED/$NAME.sif"

it "it fails, without uploading, when it cannot tell whether the artifact already exists"
out_denied=$(AWS_STUB_HEAD_ERROR="An error occurred (AccessDenied) when calling the HeadObject operation: Access Denied" bash "$S" "$BUILD/$NAME.sif" 2>&1)
assert_contains "$out_denied" "cannot check whether"
assert_failure test -f "$PUBLISHED/$NAME.sif"

it "a clean publish succeeds"
out=$(bash "$S" "$BUILD/$NAME.sif" 2>&1)
status=$?
if [ "$status" -eq 0 ]; then _pass; else _fail "$out"; fi

it "it uploads the artifact under <prefix>/<family>/"
assert_success test -f "$PUBLISHED/$NAME.sif"

it "it uploads both sidecars alongside it"
assert_success test -f "$PUBLISHED/$NAME.sif.sha256"
assert_success test -f "$PUBLISHED/$NAME.sif.metadata"

it "it logs the digest it verified"
assert_contains "$out" "verified digest:"

it "it names the promote command to run on the other environment"
assert_contains "$out" "scripts/promote-image.sh $FAMILY/$NAME.sif"

it "it reminds you to log out"
assert_contains "$out" "aws logout"

it "it refuses to republish a name already in the bucket"
assert_contains "$(bash "$S" "$BUILD/$NAME.sif" 2>&1)" "already exists"

it "it rejects a corrupt artifact before uploading anything"
BAD="$WORK/build-bad"
BADNAME="jupyterlab-20260902T000000Z-bad0000"
make_artifact "$BAD" "$FAMILY" "$BADNAME"
printf 'tampered\n' > "$BAD/$BADNAME.sif"
assert_contains "$(bash "$S" "$BAD/$BADNAME.sif" 2>&1)" "does not match its checksum"
assert_failure test -f "$PUBLISHED/$BADNAME.sif"

finish
