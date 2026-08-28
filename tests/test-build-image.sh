#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted shell snippets asserted as literal text
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

S=../scripts/build-image.sh

it "build-image.sh exists and is executable"
assert_success test -x "$S"

it "it refuses an unknown target rather than guessing"
assert_failure bash "$S" not-a-family/not-an-app

it "it refuses to build from a dirty worktree"
body=$(cat "$S")
assert_contains "$body" "git status --porcelain"

it "it checks the ARTIFACT's architecture, not the build host's"
# A cross-build must not slip through by inspecting uname alone.
assert_contains "$body" "TARGET_ARCH"
assert_not_contains "$body" 'if [ "$(uname -m)" = "x86_64" ]; then'

it "it names artifacts with a UTC timestamp and short commit"
assert_contains "$body" "date -u"
assert_contains "$body" "rev-parse --short"

it "it writes a checksum sidecar"
assert_contains "$body" "sha256sum"

it "it records the definition checksums in metadata"
assert_contains "$body" "definition_sha256"

it "it never overwrites an existing artifact"
assert_contains "$body" "already exists"

it "it sets APPTAINER_TMPDIR off the default"
# The build default is /tmp, which on a compute node is a 16GB nodev tmpfs.
assert_contains "$body" "APPTAINER_TMPDIR"

it "it does not hide failures"
assert_not_contains "$body" "|| true"
assert_not_contains "$body" "set +e"

finish
