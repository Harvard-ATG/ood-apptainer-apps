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
export HOME="$FAKE_HOME"

it "accepts a path beneath the root and echoes it resolved"
out=$(lc_validate_under "$FAKE_ENV_ROOT/default" "$FAKE_COURSE_ROOT")
assert_eq "$out" "$FAKE_ENV_ROOT/default"

it "accepts the root itself"
assert_success lc_validate_under "$FAKE_COURSE_ROOT" "$FAKE_COURSE_ROOT"

it "rejects a traversal escape"
assert_failure lc_validate_under "$FAKE_ENV_ROOT/../../../etc" "$FAKE_COURSE_ROOT"

it "rejects a sibling directory with a shared name prefix"
mkdir -p "${FAKE_COURSE_ROOT}-evil"
assert_failure lc_validate_under "${FAKE_COURSE_ROOT}-evil" "$FAKE_COURSE_ROOT"

it "follows a symlink and accepts an in-bounds target"
ln -sfn "$FAKE_ENV_ROOT/staging" "$FAKE_ENV_ROOT/link-ok"
out=$(lc_validate_under "$FAKE_ENV_ROOT/link-ok" "$FAKE_COURSE_ROOT")
assert_eq "$out" "$FAKE_ENV_ROOT/staging"

it "rejects a symlink pointing outside the root"
ln -sfn /etc "$FAKE_ENV_ROOT/link-escape"
assert_failure lc_validate_under "$FAKE_ENV_ROOT/link-escape" "$FAKE_COURSE_ROOT"

it "logs the resolved path when rejecting"
err=$(lc_validate_under "$FAKE_ENV_ROOT/link-escape" "$FAKE_COURSE_ROOT" 2>&1 >/dev/null)
assert_contains "$err" "escapes"

it "state directories are created mode 0700"
lc_make_state_dirs "$FIXTURE_ROOT/newstate/a"
assert_file_mode "$FIXTURE_ROOT/newstate/a" 700

it "bind array has one -B per mount and is an array"
lc_build_binds "$FAKE_COURSE_ROOT" "$FAKE_SCRATCH" "$FAKE_JOB_STATE" "$FAKE_JOB_TMP" "$FAKE_SSH_MASK"
count=0
for e in "${LC_BINDS[@]}"; do [ "$e" = "-B" ] && count=$((count + 1)); done
assert_eq "$count" "6"

it "course folder is bound at the same absolute path"
assert_contains "${LC_BINDS[*]}" "$FAKE_COURSE_ROOT:$FAKE_COURSE_ROOT"

it "per-job state is bound at /state"
assert_contains "${LC_BINDS[*]}" "$FAKE_JOB_STATE:/state"

it "per-job tmp is bound at /tmp"
assert_contains "${LC_BINDS[*]}" "$FAKE_JOB_TMP:/tmp"

it "ssh mask covers \$HOME/.ssh"
assert_contains "${LC_BINDS[*]}" "$FAKE_SSH_MASK:$FAKE_HOME/.ssh"

it "home IS bound explicitly, because --no-mount home suppresses --home's mount"
assert_contains "${LC_BINDS[*]}" "$FAKE_HOME:$FAKE_HOME"

it "the home bind comes FIRST, before the .ssh mask that targets a path under it"
assert_eq "${LC_BINDS[1]}" "$FAKE_HOME:$FAKE_HOME"

finish
