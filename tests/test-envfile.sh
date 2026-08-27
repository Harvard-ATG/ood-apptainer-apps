#!/usr/bin/env bash
# SC2016: the probe helpers pass shell snippets to the container as strings, so
# $HOME and friends MUST stay unexpanded here and expand in the container's shell.
# Every occurrence in this file is deliberate. This directive must precede every
# command in the file, so it sits immediately after the shebang.
# shellcheck disable=SC2016
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
ENVF="$FIXTURE_ROOT/env.list"

it "writes the file and returns success"
assert_success lc_write_env_file "$ENVF" "COURSE_ENV=$FAKE_ENV_ROOT/default" "PYTHONNOUSERSITE=1"

it "environment file is mode 0600"
assert_file_mode "$ENVF" 600

it "values are present verbatim"
assert_contains "$(cat "$ENVF")" "COURSE_ENV=$FAKE_ENV_ROOT/default"

it "file contains no unexpanded shell variable"
assert_not_contains "$(cat "$ENVF")" '$'

it "rejects an unexpanded value, because Apptainer does not expand env files"
assert_failure lc_write_env_file "$ENVF" 'CLAUDE_CONFIG_DIR=$HOME/.config/ood-huit/claude'

it "rejects a value containing a newline"
assert_failure lc_write_env_file "$ENVF" "$(printf 'A=one\nB=two')"

it "rewriting truncates rather than appending"
lc_write_env_file "$ENVF" "ONLY=one"
assert_eq "$(wc -l < "$ENVF" | tr -d ' ')" "1"

it "resolves apptainer from the test override"
OOD_AI_APPTAINER_BIN=$(command -v apptainer) \
  assert_eq "$(OOD_AI_APPTAINER_BIN=$(command -v apptainer) lc_apptainer_bin)" "$(command -v apptainer)"

it "sterile prefix starts with env -i"
lc_sterile_prefix
assert_eq "${LC_STERILE[0]} ${LC_STERILE[1]}" "env -i"

it "sterile prefix carries PATH only by default"
lc_sterile_prefix
assert_eq "${#LC_STERILE[@]}" "3"

it "sterile prefix adds LD_LIBRARY_PATH when the cluster requires it"
LC_LD_LIBRARY_PATH=/opt/view/lib lc_sterile_prefix
assert_contains "${LC_STERILE[*]}" "LD_LIBRARY_PATH=/opt/view/lib"

finish
