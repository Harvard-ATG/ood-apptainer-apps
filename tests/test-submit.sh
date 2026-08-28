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

# Renders a submit template, capturing BOTH halves of the result: RENDER_OUT is
# stdout+stderr, RENDER_STATUS is the render's real exit status.
#
# Both are needed. A rejection here is only proved by its CONSEQUENCE -- a
# failed render that emitted no native argument -- never by its diagnostic:
# downgrading a `raise` to a `warn` keeps every message this file used to assert
# on while removing the enforcement entirely, and the template then renders
# --mem-per-cpu=4 (four MEGABYTES per CPU) and --cpus-per-task=99 with the whole
# suite green.
#
# Called directly, never through $(...): a command substitution runs this in a
# subshell, and the assignments below would be discarded when it exits.
render_submit() {
    RENDER_OUT=$(FAKE_GROUPS='canvas170681-999' ruby render.rb --submit "$1" --form "${2:-$SUB}" 2>&1)
    RENDER_STATUS=$?
}

# assert_rejected -- the render FAILED and produced no Slurm native argument.
#
# The native-argument half matters independently of the status: a template that
# rescued its own error, logged it, and then went on to render the job would
# exit zero, and one that raised only after emitting the argument list would
# leave the bad value in the output.
assert_rejected() {
    if [ "$RENDER_STATUS" -eq 0 ]; then
        _fail "expected a nonzero render status; got 0 with output: $RENDER_OUT"
        return
    fi
    case "$RENDER_OUT" in
        *--cpus-per-task*|*--mem-per-cpu*|*--nodes=*)
            _fail "a rejected render still emitted a native argument: $RENDER_OUT" ;;
        *) _pass ;;
    esac
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

    it "${app}: renders successfully"
    # The positive control for assert_rejected below: without proof that an
    # in-bounds submission exits zero, a template that failed unconditionally
    # would satisfy every rejection assertion in this file.
    render_submit "$S"
    out="$RENDER_OUT"
    assert_eq "$RENDER_STATUS" "0"

    it "${app}: renders to valid YAML"
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
    render_submit "$S" "$(edited_subapp 's/^    value: 1$/    value: 2/')"
    out_multi_cpu="$RENDER_OUT"

    it "${app}: a CPU count of 2 is in bounds and renders successfully"
    assert_eq "$RENDER_STATUS" "0"

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
    # --- Rejections. Each case asserts the CONSEQUENCE first (the render
    # failed and emitted no native argument) and the diagnostic second. The
    # message assertions are kept because a rejection nobody can read is a
    # support ticket, but they are not what makes these tests bite: every one
    # of them passes while the template prints the message and submits the job
    # anyway.
    it "${app}: rejects mem_per_cpu with no unit at all"
    render_submit "$S" "$(edited_subapp 's/^  mem_per_cpu: "4G"$/  mem_per_cpu: "4"/')"
    assert_rejected

    it "${app}: the no-unit rejection says the unit is missing"
    assert_contains "$RENDER_OUT" "must carry a unit"

    it "${app}: rejects mem_per_cpu with a lowercase unit"
    render_submit "$S" "$(edited_subapp 's/^  mem_per_cpu: "4G"$/  mem_per_cpu: "4g"/')"
    assert_rejected

    it "${app}: the lowercase-unit rejection says the unit is missing"
    assert_contains "$RENDER_OUT" "must carry a unit"

    it "${app}: rejects a CPU count above the sub-app maximum"
    render_submit "$S" "$(edited_subapp 's/^    value: 1$/    value: 99/')"
    assert_rejected

    it "${app}: the out-of-bounds rejection never leaks 99 CPUs into a native argument"
    # 99 is the count a template with its `raise` downgraded to `warn` happily
    # submitted. Pin the specific number too, not only the absence of the flag.
    assert_not_contains "$RENDER_OUT" "=99"

    it "${app}: the out-of-bounds rejection names the CPU bound"
    assert_contains "$RENDER_OUT" "Number of CPUs"

    it "${app}: rejects a CPU count below the sub-app minimum"
    # The bounds check is `between?`; only the upper half was ever exercised,
    # so a mutation to `cores <= max_cores` passed unnoticed.
    render_submit "$S" "$(edited_subapp 's/^    value: 1$/    value: 0/')"
    assert_rejected

    it "${app}: the below-minimum rejection names the CPU bound"
    assert_contains "$RENDER_OUT" "Number of CPUs"

    it "${app}: rejects a walltime above the sub-app maximum"
    # hours_max is "4" in the fixture, and bc_num_hours is the only `value: 2`
    # in it. Nothing exercised the hours bound at all, so the whole hours
    # check could be deleted with the suite green. The hours value never
    # reaches a native argument, so this case is provable ONLY by the render
    # failing and emitting no argument list at all.
    render_submit "$S" "$(edited_subapp 's/^    value: 2$/    value: 99/')"
    assert_rejected

    it "${app}: the out-of-bounds walltime rejection names the hours bound"
    assert_contains "$RENDER_OUT" "Number of hours"

    it "${app}: rejects a non-numeric CPU count"
    render_submit "$S" "$(edited_subapp 's/^    value: 1$/    value: "1; rm -rf \/"/')"
    assert_rejected

    it "${app}: the non-numeric rejection says a whole number is required"
    assert_contains "$RENDER_OUT" "whole number"

    # Nothing asserts the absence of the posted text here on purpose: the
    # diagnostic deliberately quotes the rejected value, so a check for it
    # would fail on correct behaviour. `"1; rm -rf /".to_i` is 1, a perfectly
    # plausible CPU count, so a downgraded whole_number renders an
    # ordinary-looking job from a value that was never a number -- which is
    # exactly what assert_rejected above catches and no message check can.
done

finish
