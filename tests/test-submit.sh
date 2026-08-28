#!/usr/bin/env bash
# Server-side resource validation. Widget min/max are user-interface guidance
# only -- a hand-posted form reaches submit.yml.erb with any value at all, so
# the bounds are enforced here or nowhere.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

SUB=fixtures/sample-subapp.yml.erb
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

render_submit() {
    FAKE_GROUPS='canvas170681-999' ruby render.rb --submit "$1" --form "${2:-$SUB}" 2>&1
}

# A sub-app with one value edited, standing in for a hand-posted form. Takes one
# sed expression, so each caller reads as the single change it makes.
edited_subapp() {
    sed "$1" "$SUB" > "$TMP/edited.yml.erb"
    printf '%s\n' "$TMP/edited.yml.erb"
}

# Discover the submit templates that actually exist rather than hardcoding the
# app list. The count assertion below keeps this honest: discovery with nothing
# counting the finds would silently cover zero apps.
mapfile -t SUBMIT_TEMPLATES < <(find ../ood -mindepth 2 -maxdepth 2 -name 'submit.yml.erb' | sort)

it "discovers exactly two submit templates (jupyterlab, codeserver)"
assert_eq "${#SUBMIT_TEMPLATES[@]}" "2"

for S in "${SUBMIT_TEMPLATES[@]}"; do
    app=$(basename "$(dirname "$S")")

    it "${app}: renders to valid YAML"
    out=$(render_submit "$S")
    assert_success ruby -ryaml -e 'YAML.safe_load(STDIN.read)' <<<"$out"

    it "${app}: uses the basic Batch Connect template"
    assert_contains "$out" 'template: "basic"'

    it "${app}: requests a single node"
    assert_contains "$out" '"--nodes=1"'

    it "${app}: passes the validated CPU count"
    assert_contains "$out" '"--cpus-per-task=1"'

    it "${app}: passes mem-per-cpu WITH its unit"
    # --mem-per-cpu=4 means 4 MB. The unit is the difference between 4 GB and a
    # session that dies on import.
    assert_contains "$out" '"--mem-per-cpu=4G"'

    it "${app}: does not multiply memory by the CPU count"
    assert_not_contains "$out" '"--mem-per-cpu=8G"'

    # The above is a dead assertion on its own: the fixture's CPU count is 1,
    # so a bug that multiplies memory by the CPU count renders 4 * 1 = 4G,
    # indistinguishable from correct output. It only catches a hardcoded
    # doubling to 8G. The multiplication bug is visible ONLY when the CPU
    # count is not 1, so exercise that directly. cpu_max is "2", so 2 is
    # in-bounds without editing the max.
    out_multi_cpu=$(render_submit "$S" "$(edited_subapp 's/^    value: 1$/    value: 2/')")

    it "${app}: with a CPU count of 2, still passes the validated CPU count"
    assert_contains "$out_multi_cpu" '"--cpus-per-task=2"'

    it "${app}: with a CPU count of 2, mem-per-cpu is still 4G, not multiplied"
    assert_contains "$out_multi_cpu" '"--mem-per-cpu=4G"'

    it "${app}: with a CPU count of 2, mem-per-cpu is not doubled to 8G"
    assert_not_contains "$out_multi_cpu" '"--mem-per-cpu=8G"'

    # The unit-present assertion above only checks that a pre-supplied "4G"
    # survives rendering -- it never posts a value missing its unit, so a
    # regex change that makes the unit optional (e.g. dropping the trailing
    # ? in [KMGT]?) passes unnoticed. Post both a bare number and a
    # lowercase unit and confirm each is rejected.
    it "${app}: rejects mem_per_cpu with no unit at all"
    out=$(render_submit "$S" "$(edited_subapp 's/^  mem_per_cpu: "4G"$/  mem_per_cpu: "4"/')")
    assert_contains "$out" "must carry a unit"

    it "${app}: rejects mem_per_cpu with a lowercase unit"
    out=$(render_submit "$S" "$(edited_subapp 's/^  mem_per_cpu: "4G"$/  mem_per_cpu: "4g"/')")
    assert_contains "$out" "must carry a unit"

    it "${app}: rejects a CPU count above the sub-app maximum"
    out=$(render_submit "$S" "$(edited_subapp 's/^    value: 1$/    value: 99/')")
    assert_contains "$out" "Number of CPUs"

    it "${app}: rejects a non-numeric CPU count"
    out=$(render_submit "$S" "$(edited_subapp 's/^    value: 1$/    value: "1; rm -rf \/"/')")
    assert_contains "$out" "whole number"

    it "${app}: a rejected submission produces no native argument list"
    assert_not_contains "$out" '--cpus-per-task'
done

finish
