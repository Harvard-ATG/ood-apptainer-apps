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

# shellcheck source=scripts/lib/app-dirs.sh
. ../scripts/lib/app-dirs.sh
apps=$(ood_app_dirs) || { it "app discovery"; _fail "ood_app_dirs failed"; finish; exit 1; }

# Most of the loop body below is true of any app that launches a container
# through the shared library. A block of it is not: an app whose image bakes
# Claude Code and Codex must point them at config locations and pre-create
# their credential directories, and an app without agents must not be held to
# any of that.
#
# So each app declares which it is. This is not an app registry: discovery
# finds every app, and this says nothing about which apps exist. It records one
# fact per app that cannot be derived from the filesystem, and an app named in
# neither arm fails loudly. The alternative, inferring it from the `-ai`
# directory suffix, would make a typo in a new directory name silently skip
# every agent assertion.
app_agent_class() {  # -> "ai" | "none" | "" for an undeclared app
    case "$1" in
        jupyterlab-ai|codeserver-ai) printf 'ai' ;;
        *) printf '' ;;
    esac
}

for app in $apps; do
    rendered="$TMP/$app-script.sh"
    FAKE_GROUPS='canvas170681-999' FAKE_STAGED_ROOT="$TMP/staged" \
      ruby render.rb --template "../ood/$app/template/script.sh.erb" --form "$SUB" \
      > "$rendered" 2>"$rendered.err" || {
        it "$app: script.sh.erb renders"; _fail "$(cat "$rendered.err")"; continue; }
    body=$(cat "$rendered")

    it "$app: script.sh.erb renders"
    _pass

    agents=$(app_agent_class "$app")

    it "$app: declares whether its image bundles the AI coding agents"
    if [ -n "$agents" ]; then
        _pass
    else
        _fail "undeclared app '$app'. Add it to app_agent_class() above: 'ai' if its image bakes Claude Code and Codex, 'none' if it does not."
    fi

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

    it "$app: guards that validation against a course that configures no environment"
    # environment_root is optional. lc_validate_under "" resolves the empty
    # string against the current directory, so an unguarded call rejects an
    # ordinary opt-out as an escaping path and exits 1 -- a course that wanted
    # no course environment would get no session at all.
    assert_contains "$body" 'if [ -n "${ENVIRONMENT_ROOT_RAW}" ]; then'

    it "$app: still classifies unconditionally, so every session reports a status"
    # The guard belongs around the path validation, NOT around the
    # classification: COURSE_ENV_STATUS is written into the environment file
    # either way, and an unset one would leave the in-container launcher
    # falling back to "missing" and warning about the very thing the course
    # opted out of.
    assert_contains "$body" 'lc_classify_course_env "${ENVIRONMENT_ROOT}" "${COURSE_FOLDER}" bin/python'

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

    it "$app: writes COURSE_ENV_STATUS into the container environment file"
    # Nothing currently proves this key survives rendering; both the
    # in-container launcher's degraded-session logic and the merge in
    # codeserver.script.sh depend on it arriving at all.
    assert_contains "$body" '"COURSE_ENV_STATUS=${COURSE_ENV_STATUS}"'

    if [ "$agents" = ai ]; then
        it "$app: sets DISABLE_AUTOUPDATER in the environment file"
        assert_contains "$body" "DISABLE_AUTOUPDATER=1"

        it "$app: points Claude at its DEFAULT config location in the real home"
        # The default location, not a bespoke one: any tool, extension,
        # plugin or skill that discovers configuration by convention then
        # works with no special-casing, and there is no host/container
        # discrepancy.
        assert_contains "$body" 'CLAUDE_CONFIG_DIR=${HOME}/.claude'

        it "$app: points Codex at its DEFAULT config location in the real home"
        assert_contains "$body" 'CODEX_HOME=${HOME}/.codex'

        it "$app: no longer uses the bespoke ood-huit config root"
        assert_not_contains "$body" "ood-huit"

        it "$app: creates both credential directories so the CLIs never race to mkdir"
        assert_contains "$body" '"${HOME}/.claude"'
        assert_contains "$body" '"${HOME}/.codex"'
    fi

    if [ "$app" = jupyterlab-ai ]; then
        # Narrower than the agent class: this is about one package in one
        # image. notebook-intelligence resolves a tiktoken encoding at import,
        # and without this the encoding is re-downloaded on every session
        # start. Code Server bakes the agents but not that package.
        it "$app: points tiktoken at the cache baked into the image"
        assert_contains "$body" "TIKTOKEN_CACHE_DIR=/opt/tiktoken"
    fi
done

it "jupyterlab: runs the JupyterLab in-container launcher"
assert_contains "$(cat "$TMP/jupyterlab-ai-script.sh")" "jupyterlab.script.sh"

it "jupyterlab: the container PATH deliberately excludes the image's conda bin"
# Students get a terminal inside JupyterLab. With /opt/conda/bin on PATH,
# `python` there would resolve to the image interpreter rather than the course
# environment -- the same "silently lacks every course package" failure the
# deleted base kernelspec guards against. The cost of that exclusion is that
# jupyter itself is unreachable by name, which is why jupyterlab.script.sh
# execs the absolute /opt/conda/bin/jupyter (asserted in test-launchers.sh).
jl_path=$(grep -E '^ *"PATH=' "$TMP/jupyterlab-ai-script.sh" | head -1)
assert_contains "$jl_path" "PATH=/usr/local/bin:/usr/bin:/bin"
assert_not_contains "$jl_path" "/opt/conda/bin"

it "codeserver: runs the code-server in-container launcher"
assert_contains "$(cat "$TMP/codeserver-ai-script.sh")" "codeserver.script.sh"

it "jupyterlab: writes COURSE_ENV_STAGING into the container environment file"
# The staff staging affordance exists only if this key arrives. With it
# renamed by one letter, no staff member sees `Course Python (STAGING)` in any
# session, and nothing anywhere errors -- the in-container launcher simply
# takes its `[ -n "${COURSE_ENV_STAGING:-}" ]` false branch and says nothing.
# The negative codeserver assertion below cannot substitute: it passes when
# the key is missing from BOTH apps.
assert_contains "$(cat "$TMP/jupyterlab-ai-script.sh")" '"COURSE_ENV_STAGING=${COURSE_ENV_STAGING}"'

it "codeserver: does NOT write COURSE_ENV_STAGING -- staging is Jupyter-only"
assert_not_contains "$(cat "$TMP/codeserver-ai-script.sh")" "COURSE_ENV_STAGING"

it "jupyterlab: the sub-app's own system_default_label is what renders"
# The name of the image kernel is a per-course decision, so it has to travel
# the same route course_label does. Asserted on the sub-app's own value rather
# than on the key alone: a template that rendered the key with a hardcoded
# string would satisfy a key-only check while making the attribute inert. The
# fixture's value is deliberately not the production wording, so the two
# cannot match by accident.
assert_contains "$(cat "$TMP/jupyterlab-ai-script.sh")" \
    'SYSTEM_DEFAULT_LABEL="Python 3 (Fixture System Default)"'

it "jupyterlab: that label reaches the container environment file"
assert_contains "$(cat "$TMP/jupyterlab-ai-script.sh")" \
    '"SYSTEM_DEFAULT_LABEL=${SYSTEM_DEFAULT_LABEL}"'

# --- the administrator sandboxes, whose values are SELECTS ------------------
#
# Every other sub-app declares plain strings, so nothing above proves what a
# template does with a widget. OOD hands the template the value a user
# submitted; a harness that passed the widget declaration instead would render
# the Ruby Hash itself into the launch script -- COURSE_FOLDER="{"widget"=>...}"
# -- and neither ERB nor the release gate would say a word, because a Hash has
# a perfectly good to_s.
for app in $apps; do
    sandbox="../ood/$app/local/admin.yml.erb"
    [ -f "$sandbox" ] || continue
    admin_body=$(FAKE_GROUPS='ondemand-admins-1025174' FAKE_STAGED_ROOT="$TMP/staged" \
        ruby render.rb --template "../ood/$app/template/script.sh.erb" --form "$sandbox" 2>&1)

    it "$app: the sandbox's selected course folder renders as a path, not a widget"
    assert_contains "$admin_body" 'COURSE_FOLDER="/shared/courseSharedFolders/172566outer/172566"'

    it "$app: no widget declaration leaks into the launch script"
    assert_not_contains "$admin_body" "widget"

    it "$app: the sandbox's selected image renders as a path, not a widget"
    assert_contains "$admin_body" "IMAGE_FILE=\"jupyter-codeserver-ai/"

    it "$app: the sandbox defaults to NO course environment"
    # The first option of the environment_root select is the empty one, and
    # the first option is what the form pre-selects. This is the assertion
    # that a fresh image is driven with no course environment and no warning.
    assert_contains "$admin_body" 'ENVIRONMENT_ROOT_RAW=""'
done

it "codeserver: does NOT write SYSTEM_DEFAULT_LABEL -- it has no kernel to name"
# code-server shows no kernel list, so there is nothing for the label to name.
# Threading it anyway would invite a course to set it there and see nothing
# happen.
assert_not_contains "$(cat "$TMP/codeserver-ai-script.sh")" "SYSTEM_DEFAULT_LABEL"

finish
