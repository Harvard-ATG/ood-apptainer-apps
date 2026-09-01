#!/usr/bin/env bash
# Behavioural, not source-text: a deploy is a file copy, so both image roots can
# be temp directories and the real script can run against them. Nothing here
# needs Apptainer, a cluster filesystem, or a built image.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

S=../scripts/deploy-image.sh

# A stand-in for build-image.sh's output: the artifact and both sidecars, with
# the checksum recorded as a bare basename the way build-image.sh records it.
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

# A fresh workspace per test: a build directory holding one artifact, and the
# two image roots the script deploys into.
new_case() {
    # Templated rather than a bare `mktemp -d`: BSD mktemp ignores TMPDIR
    # without one, so the bare form puts the workspace somewhere a developer's
    # macOS sandbox may refuse to write. GNU mktemp accepts this form too.
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/ood-deploy-XXXXXX")
    BUILD="$WORK/build"
    CANONICAL="$WORK/shared/apptainerImages"
    FAST="$WORK/scratch/apptainerImages"
    NAME="jupyterlab-20260828T030141Z-4e73009"
    FAMILY="jupyter-codeserver-ai"
    make_artifact "$BUILD" "$FAMILY" "$NAME"
}

deploy() {  # <extra args...>
    OOD_APPTAINER_IMAGE_ROOT_CANONICAL="$CANONICAL" \
    OOD_APPTAINER_IMAGE_ROOT_FAST="$FAST" \
        bash "$S" "$@" 2>&1
}

it "deploy-image.sh exists and is executable"
assert_success test -x "$S"

it "it deploys the artifact and both sidecars into <family>/ under the canonical root"
new_case
out=$(deploy "$BUILD/$NAME.sif")
assert_success test -f "$CANONICAL/$FAMILY/$NAME.sif"

it "it deploys all three files, not just the artifact"
assert_success test -f "$CANONICAL/$FAMILY/$NAME.sif.sha256"
assert_success test -f "$CANONICAL/$FAMILY/$NAME.sif.metadata"

it "it deploys the same three files into the fast root"
assert_success test -f "$FAST/$FAMILY/$NAME.sif"
assert_success test -f "$FAST/$FAMILY/$NAME.sif.sha256"
assert_success test -f "$FAST/$FAMILY/$NAME.sif.metadata"

it "it prints the imagefile line to paste into a sub-app"
# The handoff to the half of the workflow this script deliberately does not do.
# Relative to an image root, quoted, exactly as a sub-app spells it.
assert_contains "$out" "imagefile: \"$FAMILY/$NAME.sif\""

it "the deployed artifact is world-readable"
# A stray umask on the deploying account would otherwise ship an image no
# student can read -- silent until every session in the course fails to start.
assert_file_mode "$CANONICAL/$FAMILY/$NAME.sif" 644

it "it takes the destination family from the metadata, never from the filename"
# The artifact name carries no family, so a script that guessed would have to
# invent one. Renaming the family in the sidecar must move the deploy.
new_case
sed 's/^family=.*/family=some-other-family/' "$BUILD/$NAME.sif.metadata" > "$BUILD/tmp" \
    && mv "$BUILD/tmp" "$BUILD/$NAME.sif.metadata"
deploy "$BUILD/$NAME.sif" >/dev/null
assert_success test -f "$CANONICAL/some-other-family/$NAME.sif"

it "it refuses an artifact with no metadata sidecar"
new_case
rm "$BUILD/$NAME.sif.metadata"
assert_failure deploy "$BUILD/$NAME.sif"

it "and writes nothing when it refuses one"
assert_failure test -e "$CANONICAL/$FAMILY/$NAME.sif"

it "it refuses an artifact with no checksum sidecar"
new_case
rm "$BUILD/$NAME.sif.sha256"
assert_failure deploy "$BUILD/$NAME.sif"

it "it refuses metadata that names no family"
new_case
grep -v '^family=' "$BUILD/$NAME.sif.metadata" > "$BUILD/tmp" \
    && mv "$BUILD/tmp" "$BUILD/$NAME.sif.metadata"
assert_failure deploy "$BUILD/$NAME.sif"

it "it refuses a corrupted artifact rather than publishing it"
new_case
printf 'tampered\n' >> "$BUILD/$NAME.sif"
assert_failure deploy "$BUILD/$NAME.sif"

it "and a corrupted artifact never reaches either root"
# Verified BEFORE the first copy, not after: the target name is immutable, so a
# bad file written to the canonical root burns that name permanently.
assert_failure test -e "$CANONICAL/$FAMILY/$NAME.sif"
assert_failure test -e "$FAST/$FAMILY/$NAME.sif"

it "it refuses to overwrite an artifact already deployed to the canonical root"
# Artifacts are immutable. That is what lets a committed imagefile: string
# identify one exact build for as long as the sub-app names it.
new_case
deploy "$BUILD/$NAME.sif" >/dev/null
assert_failure deploy "$BUILD/$NAME.sif"

it "it refuses to overwrite one already deployed to the fast root alone"
new_case
mkdir -p "$FAST/$FAMILY"
cp "$BUILD/$NAME.sif" "$FAST/$FAMILY/"
assert_failure deploy "$BUILD/$NAME.sif"

it "it fills the canonical root before the fast root"
# The canonical copy is the one the launcher requires and the one it cannot
# integrity-check. An unreachable fast root must therefore leave a complete,
# launchable canonical deploy behind -- the sessions are merely slower.
new_case
printf 'a file, not a directory\n' > "$WORK/scratch"   # makes mkdir -p "$FAST" fail
out=$(deploy "$BUILD/$NAME.sif")
assert_failure test -e "$FAST/$FAMILY/$NAME.sif"

it "and reports that the canonical deploy is complete and usable"
assert_success test -f "$CANONICAL/$FAMILY/$NAME.sif"
assert_contains "$out" "slower"

it "it exits nonzero when the fast root fails, despite the canonical success"
new_case
printf 'a file, not a directory\n' > "$WORK/scratch"
assert_failure deploy "$BUILD/$NAME.sif"

it "--dry-run names both destinations"
new_case
out=$(deploy --dry-run "$BUILD/$NAME.sif")
assert_contains "$out" "$CANONICAL/$FAMILY"

it "and the fast one too"
assert_contains "$out" "$FAST/$FAMILY"

it "--dry-run copies nothing"
assert_failure test -e "$CANONICAL/$FAMILY/$NAME.sif"
assert_failure test -e "$FAST/$FAMILY/$NAME.sif"

it "it refuses an artifact that does not exist"
new_case
assert_failure deploy "$BUILD/no-such-artifact.sif"

it "it refuses to be called with no artifact at all"
new_case
assert_failure deploy

rm -rf "${WORK:?}"
finish
