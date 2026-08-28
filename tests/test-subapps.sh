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

it "discovers exactly four live sub-apps under ood/*/local"
mapfile -t FOUND < <(find ../ood -mindepth 3 -maxdepth 3 -path '*/local/*.yml.erb' | sort)
assert_eq "${#FOUND[@]}" "4"

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

finish
