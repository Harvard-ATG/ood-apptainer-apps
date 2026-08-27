#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/assert.sh
. lib/assert.sh
# shellcheck source=lib/fixture.sh
. lib/fixture.sh

fixture_create
trap fixture_destroy EXIT

it "fake home exists and is writable"
assert_success test -w "$FAKE_HOME"

it "course environment prefix has a python"
assert_success test -x "$FAKE_ENV_ROOT/default/bin/python"

it "per-job state and tmp exist"
assert_success test -d "$FAKE_JOB_STATE"

it "secret dir exists for leak tests"
assert_success test -f "$FAKE_SECRET_DIR/leaky.txt"

it "canonical image root holds the stub image"
img=$(fixture_image)
assert_success test -e "$img"

it "stub image runs and reports its marker"
out=$(apptainer exec "$img" /bin/sh -c 'cat /opt/marker' 2>/dev/null)
assert_eq "$out" "stub"

it "stub image has a jupyter shim"
out=$(apptainer exec "$img" /bin/sh -c 'command -v jupyter' 2>/dev/null)
assert_eq "$out" "/usr/local/bin/jupyter"

it "stub image has a code-server shim"
out=$(apptainer exec "$img" /bin/sh -c 'command -v code-server' 2>/dev/null)
assert_eq "$out" "/usr/local/bin/code-server"

finish
