#!/usr/bin/env bash
# Release gate for every course sub-app under ood/*/local/.
#
# Renders each sub-app, and every ERB template of its parent app, through
# tests/render.rb -- the SAME harness OOD uses to bind form:-listed
# attributes into templates -- and cross-checks the values that must agree
# within a sub-app and across a course's two apps. Run this before deploying;
# a nonzero exit means do not deploy.
#
# Usage: scripts/render-forms.sh
#
# Depends only on ood/, scripts/ and tests/ (specifically tests/render.rb),
# so it works unmodified from a deploy clone that carries the whole repo.
#
# REQUIRES `ruby` AND `jq`. Both are hard dependencies -- ruby renders every
# sub-app and template, jq reads the rendered result -- and both are checked
# for below, before any work starts, so a node that is missing one is told
# which one rather than shown forty unrelated check failures.
set -uo pipefail

this_script="scripts/render-forms.sh"

log() {
    printf '[%s] %s\n' "$this_script" "$1"
}

FAILED=0

fail() {  # <path> <reason>
    FAILED=$((FAILED + 1))
    printf '[%s] FAIL %s: %s\n' "$this_script" "$1" "$2"
}

# Dependency preflight. Deliberately BEFORE anything that shells out, so it
# still reports the real problem on a node whose PATH is missing more than jq.
for tool in ruby jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '[%s] FATAL: %s is required but was not found on PATH\n' "$this_script" "$tool" >&2
        exit 1
    fi
done

# ...and that each one actually RUNS. `command -v` only proves a file is there:
# a shim, a broken symlink, or a wrapper missing its own runtime all satisfy it.
# Without this, a present-but-non-functional jq yields empty values everywhere
# and the gate reports sixteen access-control and title failures -- a wall of
# findings naming the wrong problem, which is worse than not running at all.
if ! ruby -e '' >/dev/null 2>&1; then
    printf '[%s] FATAL: ruby is on PATH but does not run\n' "$this_script" >&2
    exit 1
fi
if ! printf '{}' | jq -e . >/dev/null 2>&1; then
    printf '[%s] FATAL: jq is on PATH but does not run\n' "$this_script" >&2
    exit 1
fi

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
RENDER_RB="$REPO_ROOT/tests/render.rb"
IMAGE_ROOT="/shared/apptainerImages"
# A Canvas ID no live course under ood/*/local uses. Standing in for "a
# student enrolled in some course this app was never meant to serve."
UNRELATED_GROUP="canvas999999-1"

if [ ! -f "$RENDER_RB" ]; then
    printf '[%s] FATAL: %s not found\n' "$this_script" "$RENDER_RB" >&2
    exit 1
fi

# course id -> space-separated list of app dirs whose local/ defines it.
#
# Both are initialised, not merely declared: `declare -a X` on its own leaves X
# UNBOUND, so `${#X[@]}` and `${!X[@]}` are fatal under `set -u` until something
# assigns to them. That is reachable whenever no sub-app records a course id --
# an empty local/, or a jq that runs but returns nothing -- and it turned the
# gate's own coverage check into an "unbound variable" abort instead of a
# finding.
declare -A COURSE_APPS=()
# Every app dir that contributed at least one sub-app with a course id.
declare -a APP_DIRS=()

# OOD hands a template the value a user SUBMITTED, never the widget
# declaration. An attribute written as a widget hash therefore reaches the
# launcher as a plain string: its value: entry, or -- for a select that
# declares no value: -- the first option, which is what the form pre-selects.
#
# Reading the attribute raw makes jq stringify the whole object, so every
# check below would compare against a literal {"widget":"select",...}. That
# is not hypothetical: it is what the administrator sandboxes render, and it
# only stayed invisible where the image root is unreadable and the check is
# skipped. tests/render.rb applies the same rule, in submitted_value().
JQ_SUBMITTED='
  def submitted:
    if type == "object" then
      if has("value") then .value
      elif ((.options? // []) | length) > 0 then
        (.options[0] | if type == "array" then .[1] else . end)
      else null end
    else . end;
'

attr() {  # <rendered json> <attribute name>
    jq -r --arg k "$2" "${JQ_SUBMITTED} (.attributes[\$k] | submitted) // empty" <<<"$1"
}

# Templates a course sub-app's context can break: any *.erb under the parent
# app (excluding local/ and examples/) that reads context.<attribute>.
# submit.yml.erb is deliberately excluded here -- it never uses `context.`,
# and is rendered separately below because it binds bare locals instead.
find_context_templates() {  # <app_dir>
    find "$1" -maxdepth 3 -name '*.erb' -not -path '*/local/*' -not -path '*/examples/*' -print0 |
        xargs -0 grep -lF 'context.' 2>/dev/null | sort
}

check_subapp() {  # <path to a local/*.yml.erb sub-app>
    local path="$1" app_dir app_name
    app_dir=$(dirname "$(dirname "$path")")
    app_name=$(basename "$app_dir")

    log "checking ${path#"$REPO_ROOT"/}"

    # 1. The form renders and parses as YAML.
    local base_json
    if ! base_json=$(FAKE_GROUPS='' ruby "$RENDER_RB" --form "$path" 2>&1); then
        fail "$path" "does not render or parse as YAML: ${base_json}"
        return
    fi

    local course course_folder environment_root imagefile title cacheable cluster_none
    local launch_imagefile=""
    course=$(attr "$base_json" course)
    course_folder=$(attr "$base_json" course_folder)
    environment_root=$(attr "$base_json" environment_root)
    imagefile=$(attr "$base_json" imagefile)
    title=$(jq -r '.title // empty' <<<"$base_json")
    # Not `// empty`: jq's alternative operator treats a JSON `false` as
    # falsy, which would turn the common-case value into an empty string.
    cacheable=$(jq -r '.cacheable' <<<"$base_json")
    cluster_none=$(jq -r '.cluster // empty' <<<"$base_json")

    # 2. cluster: is computed, not hardcoded, and behaves accordingly.
    local token
    for token in enabledGroups adminGroups 'scan(/^canvas(\d+)-\d+/)' disable_this_app; do
        if ! grep -qF -- "$token" "$path"; then
            fail "$path" "access control header is missing \"${token}\" -- cluster must be computed from enabledGroups/adminGroups via the scan(/^canvas(\\d+)-\\d+/) extraction, never hardcoded"
        fi
    done

    if [ "$cluster_none" != "disable_this_app" ]; then
        fail "$path" "access control failure: rendering with no groups yielded cluster=\"${cluster_none}\", expected \"disable_this_app\""
    fi

    if [ -n "$course" ]; then
        # Kept, not discarded: check 7 validates the image an enrolled student
        # actually launches, which is this rendering rather than the denied one
        # above.
        local cluster_own own_json
        own_json=$(FAKE_GROUPS="canvas${course}-1" ruby "$RENDER_RB" --form "$path" 2>/dev/null)
        cluster_own=$(jq -r '.cluster // empty' <<<"$own_json")
        launch_imagefile=$(attr "$own_json" imagefile)
        if [ "$cluster_own" != '*' ]; then
            fail "$path" "access control failure: rendering with the course's own group (canvas${course}-1) yielded cluster=\"${cluster_own}\", expected \"*\""
        fi
    fi

    local cluster_unrelated
    cluster_unrelated=$(FAKE_GROUPS="$UNRELATED_GROUP" ruby "$RENDER_RB" --form "$path" 2>/dev/null | jq -r '.cluster // empty')
    if [ "$cluster_unrelated" = '*' ]; then
        fail "$path" "access control failure: an unrelated student (${UNRELATED_GROUP}) was granted cluster=\"*\""
    fi

    # 3. cacheable is false.
    if [ "$cacheable" != "false" ]; then
        fail "$path" "cacheable must be false, got \"${cacheable}\""
    fi

    # 4. title matches "<App> - <course>", and the app half matches the
    # directory it lives in -- read from that app's own manifest.yml so this
    # generalizes to any app this family gains later.
    local manifest_name
    manifest_name=$(sed -n 's/^name: //p' "$app_dir/manifest.yml" | head -n1)
    if [ -z "$manifest_name" ]; then
        fail "$app_dir/manifest.yml" "has no name: to validate sub-app titles against"
    else
        case "$title" in
            "${manifest_name} - "?*) : ;;
            *) fail "$path" "title \"${title}\" does not match \"${manifest_name} - <COURSE>\" for ${app_name}" ;;
        esac
    fi

    # 4b. course_label exists, and the title agrees with it.
    #
    # The kernel names a student reads in JupyterLab are built from
    # course_label; the session card they clicked is title. If those disagree,
    # the card says one course and the kernel says another. Requiring the title
    # to END with "- <course_label>" ties them together without duplicating the
    # app name.
    local course_label
    course_label=$(printf '%s' "$base_json" | jq -r '.attributes.course_label // ""')
    if [ -z "$course_label" ]; then
        fail "$path" "course_label is missing; the Jupyter kernel names are built from it"
    else
        case "$title" in
            *"- ${course_label}") : ;;
            *) fail "$path" "title \"${title}\" does not end with \"- ${course_label}\", so the session card and the kernel names would name different courses" ;;
        esac
    fi

    # 5. No leftover placeholders, in the source or the rendered document.
    local combined
    combined=$(cat "$path"; printf '%s' "$base_json")
    if grep -qF '000000' <<<"$combined"; then
        fail "$path" "contains the placeholder Canvas ID 000000"
    fi
    if grep -qF 'CHANGE ME' <<<"$combined"; then
        fail "$path" "contains the placeholder marker CHANGE ME"
    fi

    # 6. course, course_folder and environment_root agree.
    #
    # environment_root is OPTIONAL: a course whose image already carries every
    # package it needs declares none, and its sessions then start with no
    # course kernel and no warning. Empty is therefore not a finding. A
    # non-empty one must still name this course's own folder, which is the
    # copy-pasted-another-course's-file defect this check exists to catch.
    if [ -n "$course" ]; then
        local expected_folder expected_env
        expected_folder="/shared/courseSharedFolders/${course}outer/${course}"
        expected_env="${expected_folder}/envs"
        if [ "$course_folder" != "$expected_folder" ]; then
            fail "$path" "course_folder does not match the course folder layout expected for course \"${course}\" (expected course_folder=\"${expected_folder}\", got course_folder=\"${course_folder}\")"
        fi
        if [ -n "$environment_root" ] && [ "$environment_root" != "$expected_env" ]; then
            fail "$path" "environment_root does not match the course folder layout expected for course \"${course}\" (expected environment_root=\"${expected_env}\" or an empty value, got environment_root=\"${environment_root}\")"
        fi
    fi

    # 7. imagefile is relative, and exists under the image root when readable.
    #
    # SHAPE is checked on the base rendering, which every sub-app must satisfy.
    # EXISTENCE is checked on a rendering by someone who can launch the sub-app,
    # because that is the only rendering whose image anyone ever runs. A sub-app
    # that builds its image list per user -- the administrator sandboxes --
    # shows the denied user this gate impersonates a placeholder, and holding a
    # placeholder to the image root would fail the release for a value nobody
    # launches.
    case "$imagefile" in
        /*) fail "$path" "imagefile \"${imagefile}\" must be relative to the image root, not absolute" ;;
        "") fail "$path" "imagefile is missing" ;;
        *)
            if [ -n "$launch_imagefile" ] && [ -d "$IMAGE_ROOT" ] && [ -r "$IMAGE_ROOT" ] \
               && [ ! -f "${IMAGE_ROOT}/${launch_imagefile}" ]; then
                fail "$path" "imagefile \"${launch_imagefile}\" does not exist under ${IMAGE_ROOT}"
            fi
            ;;
    esac

    # 8. Every attribute a template reads must be listed under form:,
    # enforced by rendering the template and letting render.rb fail.
    local tmpl tmpl_out
    while IFS= read -r tmpl; do
        [ -n "$tmpl" ] || continue
        if ! tmpl_out=$(ruby "$RENDER_RB" --template "$tmpl" --form "$path" 2>&1); then
            fail "$path" "template ${tmpl#"$REPO_ROOT"/} failed to render: ${tmpl_out}"
        fi
    done < <(find_context_templates "$app_dir")

    # 8 (submit.yml.erb half) & 9. submit.yml.erb renders, and yields a
    # --mem-per-cpu native argument with a unit.
    local submit_file submit_out
    submit_file="${app_dir}/submit.yml.erb"
    if [ -f "$submit_file" ]; then
        if ! submit_out=$(ruby "$RENDER_RB" --submit "$submit_file" --form "$path" 2>&1); then
            fail "$path" "submit.yml.erb failed to render: ${submit_out}"
        elif ! grep -qE -- '--mem-per-cpu=[0-9]+[A-Za-z]+' <<<"$submit_out"; then
            fail "$path" "submit.yml.erb did not yield a --mem-per-cpu native argument with a unit"
        fi
    fi

    # 10. No line matches [[:space:]]+$ after a YAML scalar -- scoped to the
    # YAML document itself (after the `---` separator), not the ERB header.
    local yaml_start
    yaml_start=$(grep -n '^---$' "$path" | head -n1 | cut -d: -f1)
    if [ -n "$yaml_start" ]; then
        local trailing_offset
        trailing_offset=$(tail -n "+$((yaml_start + 1))" "$path" | grep -nE '[[:space:]]+$' | head -n1 | cut -d: -f1)
        if [ -n "$trailing_offset" ]; then
            fail "$path" "trailing whitespace after a YAML scalar on line $((yaml_start + trailing_offset))"
        fi
    fi

    # 11. Record course coverage for the cross-app check run after the loop.
    if [ -n "$course" ]; then
        COURSE_APPS["$course"]="${COURSE_APPS[$course]:-} ${app_dir}"
        local seen=0 d
        for d in "${APP_DIRS[@]-}"; do
            [ "$d" = "$app_dir" ] && seen=1 && break
        done
        [ "$seen" -eq 1 ] || APP_DIRS+=("$app_dir")
    fi
}

# 11. Both apps' sub-app sets cover the same courses.
check_course_coverage() {
    local total=${#APP_DIRS[@]}
    [ "$total" -le 1 ] && return
    local course
    for course in "${!COURSE_APPS[@]}"; do
        local -a have
        read -ra have <<<"${COURSE_APPS[$course]}"
        if [ "${#have[@]}" -ne "$total" ]; then
            local -a missing=()
            local app
            for app in "${APP_DIRS[@]}"; do
                case " ${COURSE_APPS[$course]} " in
                    *" ${app} "*) ;;
                    *) missing+=("$app") ;;
                esac
            done
            fail "course ${course}" "is defined under ${have[*]} but missing from ${missing[*]} -- every course must be defined under both apps"
        fi
    done
}

mapfile -t SUBAPPS < <(find "$REPO_ROOT/ood" -mindepth 3 -maxdepth 3 -path '*/local/*.yml.erb' | sort)

if [ "${#SUBAPPS[@]}" -eq 0 ]; then
    fail "$REPO_ROOT/ood" "no sub-apps found under ood/*/local"
fi

for subapp in "${SUBAPPS[@]}"; do
    check_subapp "$subapp"
done

check_course_coverage

log "checked ${#SUBAPPS[@]} sub-app(s), ${FAILED} failure(s)"
[ "$FAILED" -eq 0 ]
