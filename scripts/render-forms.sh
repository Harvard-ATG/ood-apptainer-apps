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
declare -A COURSE_APPS
# Every app dir that contributed at least one sub-app with a course id.
declare -a APP_DIRS

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
    course=$(jq -r '.attributes.course // empty' <<<"$base_json")
    course_folder=$(jq -r '.attributes.course_folder // empty' <<<"$base_json")
    environment_root=$(jq -r '.attributes.environment_root // empty' <<<"$base_json")
    imagefile=$(jq -r '.attributes.imagefile // empty' <<<"$base_json")
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
        local cluster_own
        cluster_own=$(FAKE_GROUPS="canvas${course}-1" ruby "$RENDER_RB" --form "$path" 2>/dev/null | jq -r '.cluster // empty')
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
    if [ -n "$course" ]; then
        local expected_folder expected_env
        expected_folder="/shared/courseSharedFolders/${course}outer/${course}"
        expected_env="${expected_folder}/envs"
        if [ "$course_folder" != "$expected_folder" ] || [ "$environment_root" != "$expected_env" ]; then
            fail "$path" "course_folder/environment_root do not match the course folder layout expected for course \"${course}\" (expected course_folder=\"${expected_folder}\" environment_root=\"${expected_env}\", got course_folder=\"${course_folder}\" environment_root=\"${environment_root}\")"
        fi
    fi

    # 7. imagefile is relative, and exists under the image root when readable.
    case "$imagefile" in
        /*) fail "$path" "imagefile \"${imagefile}\" must be relative to the image root, not absolute" ;;
        "") fail "$path" "imagefile is missing" ;;
        *)
            if [ -d "$IMAGE_ROOT" ] && [ -r "$IMAGE_ROOT" ] && [ ! -f "${IMAGE_ROOT}/${imagefile}" ]; then
                fail "$path" "imagefile \"${imagefile}\" does not exist under ${IMAGE_ROOT}"
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
