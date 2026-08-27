#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/assert.sh
. lib/assert.sh
# shellcheck source=lib/fixture.sh
. lib/fixture.sh
# shellcheck source=../ood/lib/launch-common.sh
. ../ood/lib/launch-common.sh

fixture_create
trap fixture_destroy EXIT

export OOD_AI_IMAGE_ROOT_FAST="$FAKE_IMAGE_ROOT_FAST"
export OOD_AI_IMAGE_ROOT_CANONICAL="$FAKE_IMAGE_ROOT_CANONICAL"
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

finish
