#!/usr/bin/env bash
# The behavioural half of validating the four live course sub-apps under
# ood/*/local/. (The structural half -- no CHANGE ME/000000 placeholders,
# consistent facts across the two apps for a course -- belongs to
# scripts/render-forms.sh, added in a later task.)
#
# Access control is the highest-stakes thing these files encode. This app
# family has shipped, TWICE, the defect of comparing enabledGroups (bare
# Canvas IDs) against the raw group-NAME list instead of against the IDs
# extracted by scan(/^canvas(\d+)-\d+/). That defect fails closed and
# silently: the sub-app disappears for every enrolled student while
# continuing to work for administrators, who match on a separate list. Every
# assertion below is built so that mutation reintroduces visibly.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

ADMIN_GROUP="ondemand-admins-1025174"

# Reads one value out of a rendered sub-app. The encoding is forced because
# Ruby reads STDIN as US-ASCII under this locale, and the live JupyterLab
# sub-apps carry an em dash in system_default_label: without it JSON.parse
# dies on those two files, and a check that iterates every sub-app silently
# covers only the ones that happen to be pure ASCII.
json_eval() {  # <rendered json> <ruby expression over `d`>
    printf '%s' "$1" | ruby -rjson -e \
        "d = JSON.parse(STDIN.read.force_encoding(Encoding::UTF_8)); print($2)"
}

render_form() {
    # $1 = FAKE_GROUPS, $2 = sub-app path
    FAKE_GROUPS="$1" ruby render.rb --form "$2"
}

# Table of the four live sub-apps: path | title | own Canvas ID | the OTHER
# in-scope course's Canvas ID | expected course_folder.
SUBAPPS=(
    "../ood/jupyterlab-ai/local/am115.yml.erb|Jupyter Lab - APMTH 115|172566|170681|/shared/courseSharedFolders/172566outer/172566"
    "../ood/jupyterlab-ai/local/cs1090a.yml.erb|Jupyter Lab - COMPSCI 1090A|170681|172566|/shared/courseSharedFolders/170681outer/170681"
    "../ood/codeserver-ai/local/am115.yml.erb|Code Server - APMTH 115|172566|170681|/shared/courseSharedFolders/172566outer/172566"
    "../ood/codeserver-ai/local/cs1090a.yml.erb|Code Server - COMPSCI 1090A|170681|172566|/shared/courseSharedFolders/170681outer/170681"
)

it "discovers exactly six live sub-apps under ood/*/local"
# Four course sub-apps plus the two administrator sandboxes, which are checked
# separately at the bottom of this file: they are gated the other way round,
# and their values are dropdowns rather than fixed strings.
mapfile -t FOUND < <(find ../ood -mindepth 3 -maxdepth 3 -path '*/local/*.yml.erb' | sort)
assert_eq "${#FOUND[@]}" "6"

for row in "${SUBAPPS[@]}"; do
    IFS='|' read -r path title own_id other_id course_folder <<<"$row"
    label="$(basename "$(dirname "$(dirname "$path")")")/$(basename "$path")"

    it "$label: a student enrolled in this course gets cluster '*'"
    out=$(render_form "canvas${own_id}-1" "$path")
    assert_contains "$out" '"cluster":"*"'

    it "$label: a student enrolled ONLY in the other in-scope course is denied"
    out=$(render_form "canvas${other_id}-1" "$path")
    assert_contains "$out" '"cluster":"disable_this_app"'

    it "$label: an administrator gets cluster '*'"
    out=$(render_form "$ADMIN_GROUP" "$path")
    assert_contains "$out" '"cluster":"*"'

    it "$label: a user with no groups is denied"
    out=$(render_form "" "$path")
    assert_contains "$out" '"cluster":"disable_this_app"'

    # A group whose name CONTAINS this course's Canvas ID as a substring, but
    # is not equal to it once extracted, must not match. This is what proves
    # the comparison is against the anchored, exactly-extracted ID rather
    # than a loose substring search over group names -- a plausible cousin
    # of the historical raw-name-comparison defect.
    it "$label: a group merely containing the Canvas ID as a substring is denied"
    out=$(render_form "canvas${own_id}0-1" "$path")
    assert_contains "$out" '"cluster":"disable_this_app"'

    it "$label: title reads exactly '$title'"
    out=$(render_form "canvas${own_id}-1" "$path")
    assert_contains "$out" "\"title\":\"$title\""

    it "$label: cacheable is false"
    assert_contains "$out" '"cacheable":false'

    it "$label: course matches the canonical filesystem Canvas ID"
    assert_contains "$out" "\"course\":\"$own_id\""

    it "$label: course_folder matches the course value"
    assert_contains "$out" "\"course_folder\":\"$course_folder\""

    it "$label: environment_root is course_folder/envs"
    assert_contains "$out" "\"environment_root\":\"$course_folder/envs\""
done

# --- the administrator sandboxes -------------------------------------------
#
# These are gated the opposite way round from a course sub-app: enabledGroups
# is EMPTY, so the only people who reach the form are administrators. That is
# the whole security argument for letting the form choose which course folder
# to bind, so it is asserted here rather than trusted to a comment in the file.

NO_IMAGE="jupyter-codeserver-ai/NO-DEPLOYED-IMAGE-FOUND.sif"

DEV_SUBAPPS=(
    "../ood/jupyterlab-ai/local/dev.yml.erb|Jupyter Lab - AI DEV|jupyterlab"
    "../ood/codeserver-ai/local/dev.yml.erb|Code Server - AI DEV|codeserver"
)

for row in "${DEV_SUBAPPS[@]}"; do
    IFS='|' read -r path title app <<<"$row"
    label="$(basename "$(dirname "$(dirname "$path")")")/$(basename "$path")"

    it "$label: an administrator gets cluster '*'"
    assert_contains "$(render_form "$ADMIN_GROUP" "$path")" '"cluster":"*"'

    it "$label: a student enrolled in APMTH 115 is denied"
    # The sandbox can MOUNT this course's folder, which is exactly why a
    # student of that course must not be able to launch it.
    assert_contains "$(render_form "canvas172566-1" "$path")" '"cluster":"disable_this_app"'

    it "$label: a student enrolled in COMPSCI 1090A is denied"
    assert_contains "$(render_form "canvas170681-1" "$path")" '"cluster":"disable_this_app"'

    it "$label: a user with no groups is denied"
    assert_contains "$(render_form "" "$path")" '"cluster":"disable_this_app"'

    out=$(render_form "$ADMIN_GROUP" "$path")

    it "$label: enabledGroups is empty, which is what keeps every student out"
    # The behavioral assertions above pass for any two Canvas IDs that happen
    # not to be listed. This pins the reason: nothing is listed at all.
    assert_contains "$(tr -d ' \n' < "$path")" 'enabledGroups=[]'

    it "$label: title reads exactly '$title'"
    assert_contains "$out" "\"title\":\"$title\""

    it "$label: cacheable is false"
    assert_contains "$out" '"cacheable":false'

    it "$label: course is empty, so no single Canvas ID owns the sandbox"
    # render-forms.sh derives the expected course_folder from this value. A
    # sandbox whose folder is chosen per launch cannot have one.
    assert_contains "$out" '"course":""'

    it "$label: with no deployed image the form still names a placeholder"
    # The fixture has no image root, so the glob finds nothing. An empty
    # options: block would be invalid YAML and would take the dashboard tile
    # down; a placeholder that names a real artifact would launch it.
    assert_contains "$out" "\"$NO_IMAGE\""

    it "$label: the image is offered as a select, not fixed at commit time"
    assert_contains "$out" '"imagefile":{"widget":"select"'

    it "$label: the course folder is offered as a select"
    assert_contains "$out" '"course_folder":{"widget":"select"'

    it "$label: both live courses' folders are offered"
    assert_contains "$out" '"/shared/courseSharedFolders/172566outer/172566"'
    assert_contains "$out" '"/shared/courseSharedFolders/170681outer/170681"'

    it "$label: the course environment is optional, and defaults to none"
    # The first option is what the form pre-selects, so a fresh image is
    # driven with no course environment and no warning about one.
    assert_contains "$out" '"environment_root":{"widget":"select"'
    env_first=$(json_eval "$out" 'd["attributes"]["environment_root"]["options"][0][1].inspect')
    assert_eq "$env_first" '""'
done

# --- the image list must cost a NON-administrator nothing ------------------
#
# The dashboard renders every sub-app's ERB header for every user on every
# page load -- that is what cacheable: false means, and it is what makes the
# per-user access decision correct. So a Dir.glob in this header is a readdir
# on the canonical image root, the slower of the two filesystems, in the
# dashboard path of every student in every course. For a dropdown only an
# administrator can reach.
#
# The header therefore gates the listing on the access decision. This proves
# the gate by planting builds in a fake image root and showing they reach an
# administrator's form and not a student's.
IMG_ROOT=$(mktemp -d)
trap 'rm -rf "$IMG_ROOT"' EXIT
mkdir -p "$IMG_ROOT/jupyter-codeserver-ai"
: > "$IMG_ROOT/jupyter-codeserver-ai/jupyterlab-20260101T000000Z-aaaaaaa.sif"
: > "$IMG_ROOT/jupyter-codeserver-ai/codeserver-20260101T000000Z-aaaaaaa.sif"

image_values() {  # <FAKE_GROUPS> <sub-app path>
    local rendered
    rendered=$(FAKE_GROUPS="$1" OOD_APPTAINER_IMAGE_ROOT_CANONICAL="$IMG_ROOT" \
        ruby render.rb --form "$2")
    json_eval "$rendered" 'd["attributes"]["imagefile"]["options"].map { |o| o[1] }.join(",")'
}

for row in "${DEV_SUBAPPS[@]}"; do
    IFS='|' read -r path title app <<<"$row"
    label="$(basename "$(dirname "$(dirname "$path")")")/$(basename "$path")"

    it "$label: an administrator sees the deployed builds"
    # The positive control. Without it, the assertion below would also pass
    # against a header that never listed anything for anybody.
    assert_contains "$(image_values "$ADMIN_GROUP" "$path")" "20260101T000000Z-aaaaaaa.sif"

    it "$label: a student's render does NOT read the image root"
    # The consequence, not the code: a deployed build the glob would have
    # found is absent from a denied user's form, which is only true if the
    # glob never ran.
    assert_not_contains "$(image_values "canvas172566-1" "$path")" "20260101T000000Z-aaaaaaa.sif"

    it "$label: a denied render still yields a well-formed one-option list"
    # Skipping the listing must not yield an empty options: block, which
    # would be invalid YAML and would take the whole dashboard tile down.
    assert_eq "$(image_values "canvas172566-1" "$path")" "$NO_IMAGE"

    it "$label: the administrator's default is the NEWEST build"
    # The artifact name carries a fixed-width UTC stamp, so a descending sort
    # of the names is newest-first. This is what replaced a hand-maintained
    # "latest" symlink:
    # no hand-maintained pointer, and the default cannot go stale.
    printf '' > "$IMG_ROOT/jupyter-codeserver-ai/${app}-20270606T000000Z-bbbbbbb.sif"
    assert_eq "$(image_values "$ADMIN_GROUP" "$path" | cut -d, -f1)" \
        "jupyter-codeserver-ai/${app}-20270606T000000Z-bbbbbbb.sif"
    rm -f "$IMG_ROOT/jupyter-codeserver-ai/${app}-20270606T000000Z-bbbbbbb.sif"
done

# The dashboard also lists Jupyter Lab and Code Server apps that are neither
# Apptainer-based nor from this repository. A course sub-app needs no marker
# because its course label is already unique, but "<App> - DEV" would collide
# with any sandbox of theirs, and two identically titled tiles is exactly the
# confusion an administrator sandbox must not create.
#
# Read from the RENDERED file, not from the table above: asserting the table's
# own value against itself would pass whatever the sub-app actually says.
for row in "${DEV_SUBAPPS[@]}"; do
    IFS='|' read -r path title app <<<"$row"
    label="$(basename "$(dirname "$(dirname "$path")")")/$(basename "$path")"

    it "$label: the rendered title carries the AI family marker"
    rendered_title=$(json_eval "$(render_form "$ADMIN_GROUP" "$path")" 'd["title"]')
    case "$rendered_title" in
        *" - AI DEV") _pass ;;
        *) _fail "title \"$rendered_title\" does not end with \"- AI DEV\"" ;;
    esac

    it "$label: course_label is what the title ends with, so render-forms.sh agrees"
    rendered_label=$(json_eval "$(render_form "$ADMIN_GROUP" "$path")" 'd["attributes"]["course_label"]')
    assert_eq "$rendered_title" "${title% - *} - ${rendered_label}"
done

it "no two sub-apps in this repo share a title"
# Copying a sub-app and forgetting to retitle it yields two identical tiles,
# and a student clicking either cannot tell which course they launched. This
# only sees this repository; it cannot know what else the dashboard lists.
mapfile -t ALL_TITLES < <(
    while IFS= read -r f; do
        json_eval "$(render_form "$ADMIN_GROUP" "$f")" 'd["title"] + "\n"'
    done < <(find ../ood -mindepth 3 -maxdepth 3 -path '*/local/*.yml.erb' | sort)
)
it "...and the check saw every one of them"
# Guards the reader itself: an extraction that died on some files would leave
# a short list whose survivors are trivially unique.
assert_eq "${#ALL_TITLES[@]}" "${#FOUND[@]}"
it "no two sub-apps in this repo share a title"
assert_eq "$(printf '%s\n' "${ALL_TITLES[@]}" | sort | uniq -d)" ""

it "the two sandboxes offer the same course folders as each other"
# They are separate files that do not inherit, exactly like the course
# sub-apps, so the two lists can silently drift apart.
jl_folders=$(render_form "$ADMIN_GROUP" ../ood/jupyterlab-ai/local/dev.yml.erb | ruby -rjson -e \
    'print JSON.parse(STDIN.read)["attributes"]["course_folder"]["options"].to_json')
cs_folders=$(render_form "$ADMIN_GROUP" ../ood/codeserver-ai/local/dev.yml.erb | ruby -rjson -e \
    'print JSON.parse(STDIN.read)["attributes"]["course_folder"]["options"].to_json')
assert_eq "$jl_folders" "$cs_folders"

finish
