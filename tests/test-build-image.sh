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

it "it discards no stderr, so a build-scratch failure keeps its real diagnostic"
# mkdir's own message says whether the path is read-only, absent, over quota or
# permission-denied. Swallowing it leaves only "cannot create build scratch",
# which is expensive to act on from a cluster node. The same pattern is banned
# in the recipe by test-recipe.sh.
assert_not_contains "$body" "2>/dev/null"

it "it warns about an architecture mismatch BEFORE spending the build"
# The authoritative check is on the artifact, after the build -- but it then
# deletes what it rejects. Unwarned, every artifact on an arm build host is
# destroyed after ~20 minutes unless OOD_AI_TARGET_ARCH is set.
assert_contains "$body" "WARNING: build host is"

it "the early warning compares through normalize_arch, not a hardcoded arch"
assert_contains "$body" 'normalize_arch "$HOST_ARCH"'

it "the early warning names the override that keeps the artifact"
assert_contains "$body" "OOD_AI_TARGET_ARCH="

it "the early warning precedes the build, or it saves nothing"
warn_pos=$(printf '%s' "$body" | grep -n "WARNING: build host is" | head -1 | cut -d: -f1)
build_pos=$(printf '%s' "$body" | grep -n "apptainer build --fakeroot \"\$SIF\"" | head -1 | cut -d: -f1)
assert_eq "$([ "$warn_pos" -lt "$build_pos" ] && echo before || echo after)" "before"

it "it still warns rather than refuses -- cross-arch validation builds are legitimate"
# The early check must not exit; only the post-build artifact check rejects.
early=$(printf '%s' "$body" | sed -n "${warn_pos},${build_pos}p")
assert_not_contains "$early" "exit 1"

finish
