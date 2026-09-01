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

it "a provisioned environment classifies as ok"
LC_COURSE_ENV="" LC_COURSE_ENV_STATUS=""
assert_success lc_classify_course_env "$FAKE_ENV_ROOT" "$FAKE_COURSE_ROOT" bin/python
lc_classify_course_env "$FAKE_ENV_ROOT" "$FAKE_COURSE_ROOT" bin/python >/dev/null 2>&1

it "ok classification reports the resolved prefix"
assert_eq "$LC_COURSE_ENV" "$(realpath -m "$FAKE_ENV_ROOT/default")"

it "ok classification reports status ok"
assert_eq "$LC_COURSE_ENV_STATUS" "ok"

it "an unprovisioned environment does NOT fail the launch"
fixture_remove_course_env
assert_success lc_classify_course_env "$FAKE_ENV_ROOT" "$FAKE_COURSE_ROOT" bin/python

it "an unprovisioned environment classifies as missing"
lc_classify_course_env "$FAKE_ENV_ROOT" "$FAKE_COURSE_ROOT" bin/python >/dev/null 2>&1
assert_eq "$LC_COURSE_ENV_STATUS" "missing"

it "a missing environment still reports the prefix it looked for"
# The diagnostic is the whole point of the degraded path: the log must name the
# path that was absent, or the staff member fixing it has nothing to go on.
assert_eq "$LC_COURSE_ENV" "$(realpath -m "$FAKE_ENV_ROOT/default")"

it "the warning names the path and says the session continues"
out=$(lc_classify_course_env "$FAKE_ENV_ROOT" "$FAKE_COURSE_ROOT" bin/python 2>&1)
assert_contains "$out" "$FAKE_ENV_ROOT/default/bin/python"

it "a non-executable interpreter classifies as missing"
mkdir -p "$FAKE_ENV_ROOT/default/bin"
: > "$FAKE_ENV_ROOT/default/bin/python"
chmod 644 "$FAKE_ENV_ROOT/default/bin/python"
lc_classify_course_env "$FAKE_ENV_ROOT" "$FAKE_COURSE_ROOT" bin/python >/dev/null 2>&1
assert_eq "$LC_COURSE_ENV_STATUS" "missing"

# --- the interpreter is the caller's to name -------------------------------
# The prefix a course environment holds is not always a Python one: an R app
# would look for bin/R. Which interpreter proves a prefix usable is a fact the
# app knows and this library does not, so it is an argument rather than a
# constant here.

it "a prefix classifies ok on the interpreter the caller names"
R_ROOT="$FAKE_COURSE_ROOT/r-envs"
mkdir -p "$R_ROOT/default/bin"
printf '#!/bin/sh\n' > "$R_ROOT/default/bin/R"
chmod 755 "$R_ROOT/default/bin/R"
LC_COURSE_ENV_STATUS=""
lc_classify_course_env "$R_ROOT" "$FAKE_COURSE_ROOT" bin/R >/dev/null 2>&1
assert_eq "$LC_COURSE_ENV_STATUS" "ok"

it "another interpreter being present does not make the named one found"
# bin/python exists here; bin/R is what was asked for. Without this, a library
# that still tested bin/python would pass the test above by accident.
rm -f "$R_ROOT/default/bin/R"
printf '#!/bin/sh\n' > "$R_ROOT/default/bin/python"
chmod 755 "$R_ROOT/default/bin/python"
LC_COURSE_ENV_STATUS=""
lc_classify_course_env "$R_ROOT" "$FAKE_COURSE_ROOT" bin/R >/dev/null 2>&1
assert_eq "$LC_COURSE_ENV_STATUS" "missing"

it "the warning names the interpreter that was actually looked for"
out=$(lc_classify_course_env "$R_ROOT" "$FAKE_COURSE_ROOT" bin/R 2>&1)
assert_contains "$out" "$R_ROOT/default/bin/R"

it "omitting the interpreter fails rather than assuming Python"
# A default would keep the Python assumption alive under a new name, which is
# the thing this argument exists to remove.
assert_failure lc_classify_course_env "$FAKE_ENV_ROOT" "$FAKE_COURSE_ROOT"

it "an escaping environment root is FATAL, not degraded"
# Containment failures must never soften into a warning. This is the one case
# that still stops the launch.
ESCAPE="$FIXTURE_ROOT/outside-envs"
mkdir -p "$ESCAPE/default/bin"
ln -sfn "$ESCAPE" "$FAKE_COURSE_ROOT/escaping-envs"
assert_failure lc_classify_course_env "$FAKE_COURSE_ROOT/escaping-envs" "$FAKE_COURSE_ROOT" bin/python

it "staging resolves to its real path"
assert_eq "$(lc_resolve_staging "$FAKE_ENV_ROOT" "$FAKE_COURSE_ROOT" 2>/dev/null)" \
          "$(realpath -m "$FAKE_ENV_ROOT/staging")"

it "an escaping staging target yields nothing and does not fail the launch"
# ln -sfn cannot replace an existing non-empty real directory (it silently
# no-ops rather than erroring), so the directory must be removed first for the
# symlink swap below to actually take effect.
rm -rf "$FAKE_ENV_ROOT/staging"
ln -sfn "$ESCAPE" "$FAKE_ENV_ROOT/staging"
out=$(lc_resolve_staging "$FAKE_ENV_ROOT" "$FAKE_COURSE_ROOT" 2>/dev/null)
assert_eq "$out" ""

it "resolving an escaping staging target still returns success"
assert_success lc_resolve_staging "$FAKE_ENV_ROOT" "$FAKE_COURSE_ROOT"

finish
