#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

it "render-forms.sh exists and is executable"
assert_success test -x scripts/render-forms.sh

it "the committed sub-apps pass"
out=$(scripts/render-forms.sh 2>&1)
status=$?
# shellcheck disable=SC2015  # not if/then/else, but _pass and _fail can't fail
[ "$status" -eq 0 ] && _pass || _fail "$out"

it "it checked all six sub-apps"
assert_contains "$out" "6 sub-app"

# Each negative case is a real regression this family has shipped.
broken_file() {  # <path under the repo copy> <sed expression>
    rm -rf "$TMP/repo"; mkdir -p "$TMP/repo"
    cp -a ood scripts tests "$TMP/repo/"
    sed -i "$2" "$TMP/repo/$1"
    ( cd "$TMP/repo" && ./scripts/render-forms.sh 2>&1 )
}

broken() {  # <name> <sed expression>, applied to cs1090a under jupyterlab-ai
    broken_file ood/jupyterlab-ai/local/cs1090a.yml.erb "$2"
}

it "the gate's access-control checks reach EVERY sub-app, not just the one every other case mutates"
# Replaces a vacuous `assert_contains "$out" "am115"` that ran under this
# name: the literal am115 appears in render-forms.sh's own "checking ..."
# progress line, printed before any check runs, so it passed even with am115
# denying every enrolled student. Line 20's "6 sub-app" already covers
# discovery; what was actually uncovered is whether the checks APPLY to a
# sub-app no other negative case touches. This mutates a different course
# AND a different app directory, and swaps only the enabledGroups entry --
# `course` stays 172566, so the folder-agreement checks are unaffected and
# only access control can fire.
am115_locked=$(broken_file ood/codeserver-ai/local/am115.yml.erb 's/"172566" # APMTH 115/"111111" # APMTH 115/')
am115_locked_status=$?
assert_contains "$am115_locked" "access control"

it "...and names the sub-app it rejected"
assert_contains "$am115_locked" "codeserver-ai/local/am115.yml.erb"

it "...and blocks the release by exiting nonzero"
# The gate is a release gate: a diagnostic it prints while still exiting zero
# is not a gate. None of the other negative cases in this file check status.
assert_eq "$([ "$am115_locked_status" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

it "a missing access-control header is release-blocking"
assert_contains "$(broken nocluster 's/^cluster: .*/cluster: "*"/')" "access control"

it "a leftover placeholder Canvas ID fails"
assert_contains "$(broken placeholder 's/"170681"/"000000"/')" "placeholder"

it "cacheable: true fails"
assert_contains "$(broken cacheable 's/^cacheable: false/cacheable: true/')" "cacheable"

it "an attribute consumed by a template but missing from form: fails"
assert_contains "$(broken unlisted '/^  - environment_root$/d')" "environment_root"

it "an absolute imagefile fails"
assert_contains "$(broken abspath 's#imagefile: "#imagefile: "/shared/apptainerImages/#')" "relative"

it "an environment root outside the course folder fails"
assert_contains "$(broken escape 's#environment_root: ".*"#environment_root: "/shared/courseSharedFolders/999999outer/999999/envs"#')" "course folder"

# environment_root is OPTIONAL: a course whose image already carries every
# package it needs declares none, and its sessions then start with no course
# kernel and no warning. The gate has to let that ship, while still catching
# the copy-pasted-another-course's-path defect the case above covers.
optout=$(broken optout 's#^  environment_root: ".*"$#  environment_root: ""#')
optout_status=$?

it "a sub-app that configures NO course environment is not a finding"
assert_not_contains "$optout" "FAIL"

it "...and does not block the release"
assert_eq "$([ "$optout_status" -eq 0 ] && echo zero || echo nonzero)" "zero"

it "...and the gate still checked every sub-app"
# Not vacuous: a gate that crashed before checking anything would also
# produce no findings.
assert_contains "$optout" "6 sub-app"

it "trailing whitespace after a YAML scalar fails"
assert_contains "$(broken trailing 's/^  course: "170681"/  course: "170681"  /')" "trailing whitespace"

it "a title that does not follow <App> - <COURSE> fails"
assert_contains "$(broken title 's/^title: .*/title: "jupyterlab cs1090a"/')" "title"

# --- Checks required by the task-8 brief's numbered list, not exercised above.
# Each mutation is chosen to isolate exactly one check: everything else about
# the sub-app stays correct, so a pass here cannot be attributed to a
# different, unrelated failure.

it "invalid YAML in the sub-app is release-blocking"
# Doubles the colon on a line the ERB header never touches, so this is a pure
# syntax break -- every other check on this file would otherwise pass.
assert_contains "$(broken badyaml 's/^cacheable: false/cacheable: : false/')" "YAML"

it "renaming enabledGroups keeps access control behaviorally correct"
# Verified independently of render-forms.sh, against the SAME mutated file,
# so the next assertion's failure can only be attributed to the static
# substring check -- not to a coincidental access regression this rename
# might have introduced.
rm -rf "$TMP/repo"; mkdir -p "$TMP/repo"
cp -a ood scripts tests "$TMP/repo/"
sed -i 's/enabledGroups/allowedGroups/g' "$TMP/repo/ood/jupyterlab-ai/local/cs1090a.yml.erb"
renamed_cluster() { FAKE_GROUPS="$1" ruby "$TMP/repo/tests/render.rb" --form "$TMP/repo/ood/jupyterlab-ai/local/cs1090a.yml.erb" | jq -r .cluster; }
own=$(renamed_cluster 'canvas170681-1')
none=$(renamed_cluster '')
unrelated=$(renamed_cluster 'canvas999999-1')
if [ "$own" = '*' ] && [ "$none" = 'disable_this_app' ] && [ "$unrelated" = 'disable_this_app' ]; then
    _pass
else
    _fail "own=$own none=$none unrelated=$unrelated"
fi

it "renaming enabledGroups breaks the static access-control check even though behavior is unchanged"
out_renamed=$(cd "$TMP/repo" && ./scripts/render-forms.sh 2>&1)
assert_contains "$out_renamed" "access control"

it "a sub-app that denies the course's own enrolled students fails with access control"
# Swaps the enabledGroups entry for an unrelated Canvas ID: an empty-groups
# user and the sentinel unrelated student both still correctly resolve to
# disable_this_app, so only the own-group behavioral check can be what
# fires here -- a defect that only locks out the enrolled course itself
# would otherwise slip past every other access-control check in this file.
assert_contains "$(broken lockout 's/"170681" # COMPSCI 1090A/"111111" # COMPSCI 1090A/')" "access control"

it "a sub-app that fails open with no groups at all fails with access control"
# Appends a fail-open override for the no-groups case only: an enrolled
# student and an unrelated student both still resolve exactly as before, so
# only the no-groups behavioral check can be what fires here. This is
# distinct from the "unrelated student" case below -- a defect that only
# mishandles missing group data would slip past that check entirely.
assert_contains "$(broken failopen 's/^-%>$/cluster = "*" if userGroups.empty?\n-%>/')" "access control"

it "a sub-app that grants an unrelated student cluster '*' fails with access control"
# Adds a second, bogus Canvas ID to enabledGroups -- the header still
# contains every required literal, and the course's own students and an
# empty-groups user still resolve correctly, so only the unrelated-student
# check can be what fires here.
assert_contains "$(broken leaked 's/"170681" # COMPSCI 1090A/"170681", "999999" # COMPSCI 1090A/')" "access control"

it "a title whose app half does not match its own app directory fails"
# jupyterlab-ai/local/cs1090a.yml.erb given a Code Server title: the format
# regex alone is satisfied, so only the directory cross-check can catch this.
assert_contains "$(broken wrongapp 's/^title: "Jupyter Lab - COMPSCI 1090A"$/title: "Code Server - COMPSCI 1090A"/')" "title"

it "a leftover CHANGE ME placeholder fails"
# Distinct from the numeric-placeholder case above: this is the textual
# marker examples/course.yml.erb tells authors to search-and-replace.
assert_contains "$(broken changeme 's/COMPSCI 1090A: Introduction/COMPSCI 1090A: CHANGE ME Introduction/')" "placeholder"

it "course_folder/environment_root pointing at a different course's folder fails"
# Simulates copy-pasting another course's file and forgetting to update the
# folder paths: course_folder and environment_root stay consistent with each
# other, but neither matches this file's own `course` value.
assert_contains "$(broken swappedfolder 's#170681outer/170681#172566outer/172566#g')" "course folder"

broken_submit() {  # <sed expression>, applied to the shared submit.yml.erb
    rm -rf "$TMP/repo"; mkdir -p "$TMP/repo"
    cp -a ood scripts tests "$TMP/repo/"
    sed -i "$1" "$TMP/repo/ood/jupyterlab-ai/submit.yml.erb"
    ( cd "$TMP/repo" && ./scripts/render-forms.sh 2>&1 )
}

it "submit.yml.erb losing its --mem-per-cpu native argument fails"
assert_contains "$(broken_submit '/--mem-per-cpu/d')" "mem-per-cpu"

broken_missing_course() {
    rm -rf "$TMP/repo"; mkdir -p "$TMP/repo"
    cp -a ood scripts tests "$TMP/repo/"
    rm -f "$TMP/repo/ood/codeserver-ai/local/am115.yml.erb"
    ( cd "$TMP/repo" && ./scripts/render-forms.sh 2>&1 )
}

it "a course present under one app but missing from the other fails"
assert_contains "$(broken_missing_course)" "both apps"

# --- The gate's own dependencies. jq was an undeclared hard dependency: the
# README claimed the suite and gate needed nothing beyond the OS, ruby and
# optionally shellcheck, while render-forms.sh cannot read a rendered sub-app
# without jq. Without the preflight, a cluster node missing it produces a wall
# of access-control failures naming the wrong problem.
BASH_BIN=$(command -v bash)
mkdir -p "$TMP/nobin"
NODEPS_OUT=$(PATH="$TMP/nobin" "$BASH_BIN" scripts/render-forms.sh 2>&1)
NODEPS_STATUS=$?

it "the gate names its missing dependency instead of failing every check"
assert_contains "$NODEPS_OUT" "is required but was not found on PATH"

it "the gate exits nonzero when a dependency is missing"
assert_eq "$([ "$NODEPS_STATUS" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

it "the gate does not claim to have checked any sub-app without its dependencies"
# The consequence that matters: a gate that reported "4 sub-app(s), 0
# failure(s)" from a node with no jq would be worse than one that crashed.
assert_not_contains "$NODEPS_OUT" "sub-app(s)"

# A tool that is PRESENT but does not run is the harder case, and the one the
# preflight originally missed: `command -v` is satisfied by a shim, a broken
# symlink, or a wrapper missing its own runtime. A jq that exits nonzero makes
# every jq-extracted value empty, so the gate reported sixteen access-control
# and title failures -- a wall of findings naming the wrong problem.
BROKEN_BIN="$TMP/broken"
mkdir -p "$BROKEN_BIN"
printf '#!/bin/sh\necho "jq: fatal" >&2\nexit 127\n' > "$BROKEN_BIN/jq"
chmod 755 "$BROKEN_BIN/jq"
BROKEN_OUT=$(PATH="$BROKEN_BIN:$PATH" ./scripts/render-forms.sh 2>&1)

it "a present-but-broken jq is rejected by the preflight"
assert_contains "$BROKEN_OUT" "jq is on PATH but does not run"

it "a present-but-broken jq does not produce a wall of unrelated findings"
# The consequence, not the message: no per-sub-app finding of ANY kind. Note the
# pattern is bare "FAIL" and not "FAIL ood/" -- fail() prints the ABSOLUTE path,
# so the latter matches nothing and the assertion could never fail. Found by
# mutating the probe away and watching this pass while sixteen access-control
# findings scrolled past.
assert_not_contains "$BROKEN_OUT" "FAIL"

it "a present-but-broken jq does not report access-control findings"
# The specific wrong-problem wall: empty jq output made every sub-app look as
# though it had no access control at all.
assert_not_contains "$BROKEN_OUT" "access control failure"

it "a present-but-broken jq does not abort with an unbound variable"
# `declare -a X` leaves X unbound under set -u, so the coverage check aborted
# here instead of reporting anything.
assert_not_contains "$BROKEN_OUT" "unbound variable"

it "the gate reports nothing checked when a dependency is unusable"
assert_not_contains "$BROKEN_OUT" "sub-app(s)"

it "the coverage check survives a run where no sub-app records a course"
# Reachable with an empty local/, not just via a broken jq. The arrays must be
# initialised, not merely declared.
rm -rf "$TMP/nocourse"; mkdir -p "$TMP/nocourse"
cp -a ood scripts tests "$TMP/nocourse/"
rm -f "$TMP/nocourse"/ood/*/local/*.yml.erb
NOCOURSE_OUT=$( cd "$TMP/nocourse" && ./scripts/render-forms.sh 2>&1 )
assert_not_contains "$NOCOURSE_OUT" "unbound variable"

finish
