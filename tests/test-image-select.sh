#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh
# shellcheck source=lib/fixture.sh
. lib/fixture.sh
# shellcheck source=../ood/lib/launch-common.sh
. ../ood/lib/launch-common.sh

fixture_create
trap fixture_destroy EXIT

export OOD_APPTAINER_IMAGE_ROOT_FAST="$FAKE_IMAGE_ROOT_FAST"
export OOD_APPTAINER_IMAGE_ROOT_CANONICAL="$FAKE_IMAGE_ROOT_CANONICAL"
REL="jupyter-codeserver-ai/jupyterlab-test.sif"

mkdir -p "$FAKE_IMAGE_ROOT_CANONICAL/jupyter-codeserver-ai" \
         "$FAKE_IMAGE_ROOT_FAST/jupyter-codeserver-ai"
printf 'IMAGE-CONTENT-1234567890' > "$FAKE_IMAGE_ROOT_CANONICAL/$REL"

it "falls back to canonical when no fast copy exists"
out=$(lc_select_image "$REL" 2>/dev/null)
assert_eq "$out" "$FAKE_IMAGE_ROOT_CANONICAL/$REL"

it "logs a warning when falling back"
err=$(lc_select_image "$REL" 2>&1 >/dev/null)
assert_contains "$err" "no fast copy"

it "prefers the fast copy when sizes match"
cp "$FAKE_IMAGE_ROOT_CANONICAL/$REL" "$FAKE_IMAGE_ROOT_FAST/$REL"
out=$(lc_select_image "$REL" 2>/dev/null)
assert_eq "$out" "$FAKE_IMAGE_ROOT_FAST/$REL"

it "rejects a truncated fast copy and falls back"
printf 'TRUNC' > "$FAKE_IMAGE_ROOT_FAST/$REL"
out=$(lc_select_image "$REL" 2>/dev/null)
assert_eq "$out" "$FAKE_IMAGE_ROOT_CANONICAL/$REL"

it "logs a size mismatch explicitly"
err=$(lc_select_image "$REL" 2>&1 >/dev/null)
assert_contains "$err" "size mismatch"

it "fails when the canonical copy is missing"
assert_failure lc_select_image "jupyter-codeserver-ai/nonexistent.sif"

it "never writes to the fast root"
cp "$FAKE_IMAGE_ROOT_CANONICAL/$REL" "$FAKE_IMAGE_ROOT_FAST/$REL"
before=$(find "$FAKE_IMAGE_ROOT_FAST" -type f | sort | md5sum)
lc_select_image "$REL" >/dev/null 2>&1
after=$(find "$FAKE_IMAGE_ROOT_FAST" -type f | sort | md5sum)
assert_eq "$after" "$before"

it "never creates a missing fast copy"
rm -f "$FAKE_IMAGE_ROOT_FAST/$REL"
lc_select_image "$REL" >/dev/null 2>&1
assert_failure test -e "$FAKE_IMAGE_ROOT_FAST/$REL"

# --- a symlink in the image root --------------------------------------------
# Nothing this repo ships puts one there: deploy-image.sh copies regular files,
# and the sandbox sub-app lists real artifacts rather than an alias. An
# administrator can still make one by hand, and the launcher must not be fooled.
# stat does NOT follow symlinks by default: on a symlink it reports the length
# of the target PATH STRING, and artifact names are fixed-width, so two
# same-named symlinks pointing at completely different builds report the SAME
# number. Without -L in lc_file_size the size comparison agrees that a stale
# Lustre copy matches, and every session in the course runs the wrong image.
ALIAS="jupyter-codeserver-ai/jupyterlab-alias.sif"
printf 'CANONICAL-BUILD-AAAAAAAAAAAAAAAAAAAA' > "$FAKE_IMAGE_ROOT_CANONICAL/jupyter-codeserver-ai/jupyterlab-20260101T000000Z-aaaaaaa.sif"
printf 'FAST-BUILD-B' > "$FAKE_IMAGE_ROOT_FAST/jupyter-codeserver-ai/jupyterlab-20260202T000000Z-bbbbbbb.sif"
ln -sfn jupyterlab-20260101T000000Z-aaaaaaa.sif "$FAKE_IMAGE_ROOT_CANONICAL/$ALIAS"
ln -sfn jupyterlab-20260202T000000Z-bbbbbbb.sif "$FAKE_IMAGE_ROOT_FAST/$ALIAS"

it "compares what two symlinks POINT AT, not the symlinks themselves"
# Both link names are the same length, so a size check that stats the link
# rather than its target sees a match and takes the fast path.
out=$(lc_select_image "$ALIAS" 2>/dev/null)
assert_eq "$out" "$FAKE_IMAGE_ROOT_CANONICAL/$ALIAS"

it "...and says it was a size mismatch"
err=$(lc_select_image "$ALIAS" 2>&1 >/dev/null)
assert_contains "$err" "size mismatch"

it "takes the fast path when both symlinks resolve to identical bytes"
cp "$FAKE_IMAGE_ROOT_CANONICAL/jupyter-codeserver-ai/jupyterlab-20260101T000000Z-aaaaaaa.sif" \
   "$FAKE_IMAGE_ROOT_FAST/jupyter-codeserver-ai/jupyterlab-20260202T000000Z-bbbbbbb.sif"
out=$(lc_select_image "$ALIAS" 2>/dev/null)
assert_eq "$out" "$FAKE_IMAGE_ROOT_FAST/$ALIAS"

it "treats a dangling canonical symlink as a missing image, and fails the launch"
# An administrator linking by hand can leave a symlink with no target. That
# must stop the launch with the "not found at authoritative path" error, not
# hand Apptainer a path that cannot be opened.
ln -sfn jupyterlab-never-deployed.sif "$FAKE_IMAGE_ROOT_CANONICAL/$ALIAS"
assert_failure lc_select_image "$ALIAS"

it "falls back to canonical when only the FAST symlink is dangling"
ln -sfn jupyterlab-20260101T000000Z-aaaaaaa.sif "$FAKE_IMAGE_ROOT_CANONICAL/$ALIAS"
ln -sfn jupyterlab-never-deployed.sif "$FAKE_IMAGE_ROOT_FAST/$ALIAS"
out=$(lc_select_image "$ALIAS" 2>/dev/null)
assert_eq "$out" "$FAKE_IMAGE_ROOT_CANONICAL/$ALIAS"

finish
