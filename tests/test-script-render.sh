#!/usr/bin/env bash
# SC2016: assert_contains patterns below are deliberately single-quoted so
# shell metacharacters (${JOBROOT}) are compared literally against the
# rendered template's source text rather than expanded by this test script's
# shell. This directive must precede every command in the file, so it sits
# immediately after the shebang.
# shellcheck disable=SC2016
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

SUB=fixtures/sample-subapp.yml.erb
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for app in jupyterlab-ai codeserver-ai; do
    rendered="$TMP/$app-script.sh"
    FAKE_GROUPS='canvas170681-999' FAKE_STAGED_ROOT="$TMP/staged" \
      ruby render.rb --template "../ood/$app/template/script.sh.erb" --form "$SUB" \
      > "$rendered" 2>"$rendered.err" || {
        it "$app: script.sh.erb renders"; _fail "$(cat "$rendered.err")"; continue; }
    body=$(cat "$rendered")

    it "$app: script.sh.erb renders"
    _pass

    it "$app: sources the staged shared library"
    assert_contains "$body" '${JOBROOT}/lib/launch-common.sh'

    it "$app: the imagefile from the form is present"
    assert_contains "$body" "jupyter-codeserver-ai/jupyterlab-20260827T000000Z-abc1234.sif"

    it "$app: the fixed environment root from the form is present"
    assert_contains "$body" "/shared/courseSharedFolders/170681outer/170681/envs"

    it "$app: does NOT exec the apptainer call"
    assert_not_contains "$body" "exec \"\${APPTAINER_BIN}\""

    it "$app: does not suppress failures with '|| true'"
    assert_not_contains "$body" "|| true"

    it "$app: does not disable errexit to hide a failure"
    assert_not_contains "$body" "set +e"

    it "$app: writes no credential into an apptainer argument"
    assert_not_contains "$body" '--env PASSWORD'

    it "$app: validates the environment prefix before launch"
    assert_contains "$body" "lc_validate_under"

    it "$app: checks the course folder exists and is readable before building binds"
    # lc_validate_under uses realpath -m (tolerates missing components) and the
    # course folder is only ever the root of a validation, never the target, so
    # an absent course folder is otherwise caught nowhere -- surfacing 600
    # seconds later as an opaque Apptainer bind error instead of a clear
    # message at launch.
    assert_contains "$body" "course folder not found or not readable"

    it "$app: the course folder check precedes building the binds"
    check_pos=$(printf '%s' "$body" | grep -n "course folder not found or not readable" | head -1 | cut -d: -f1)
    binds_pos=$(printf '%s' "$body" | grep -n "^lc_build_binds" | head -1 | cut -d: -f1)
    assert_eq "$([ "$check_pos" -lt "$binds_pos" ] && echo before || echo after)" "before"

    it "$app: builds binds through the shared helper"
    assert_contains "$body" "lc_build_binds"

    it "$app: launches through the shared helper"
    assert_contains "$body" "lc_run"

    it "$app: creates state directories with the shared helper"
    assert_contains "$body" "lc_make_state_dirs"

    it "$app: sets PYTHONNOUSERSITE in the environment file"
    assert_contains "$body" "PYTHONNOUSERSITE=1"

    it "$app: sets DISABLE_AUTOUPDATER in the environment file"
    assert_contains "$body" "DISABLE_AUTOUPDATER=1"

    it "$app: isolates Claude credentials under the persistent config root"
    assert_contains "$body" ".config/ood-huit/claude"

    it "$app: isolates Codex credentials under the persistent config root"
    assert_contains "$body" ".config/ood-huit/codex"
done

it "jupyterlab: runs the JupyterLab in-container launcher"
assert_contains "$(cat "$TMP/jupyterlab-ai-script.sh")" "jupyterlab.script.sh"

it "codeserver: runs the code-server in-container launcher"
assert_contains "$(cat "$TMP/codeserver-ai-script.sh")" "codeserver.script.sh"

finish
