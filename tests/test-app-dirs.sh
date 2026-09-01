#!/usr/bin/env bash
# scripts/lib/app-dirs.sh is what lets a new OOD app be covered by five suites
# the moment it has a manifest, with no per-app edit. That convenience is also
# its risk: `for app in $(ood_app_dirs)` can iterate zero times where the
# hardcoded list it replaces could not, so a discovery bug would make those
# suites pass while asserting nothing. The guard against that is the helper
# failing loudly on an empty result, which is the second test here.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

HELPER=../scripts/lib/app-dirs.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The helper must resolve the repo root from its own location rather than cwd,
# because the suites disagree about cwd. Copying it into a synthetic tree tests
# that: if it consulted cwd it would find the real ood/ instead of this one.
fake_repo() {  # <name> -- prints the repo root of a synthetic tree
    local root="$TMP/$1"
    mkdir -p "$root/scripts/lib" "$root/ood"
    cp "$HELPER" "$root/scripts/lib/app-dirs.sh"
    printf '%s\n' "$root"
}

it "the helper exists and is syntactically valid bash"
assert_success bash -n "$HELPER"

# --- the predicate: a manifest is what makes a directory an app -------------

populated=$(fake_repo populated)
mkdir -p "$populated/ood/withmanifest" "$populated/ood/nomanifest" "$populated/ood/lib"
touch "$populated/ood/withmanifest/manifest.yml"
touch "$populated/ood/nomanifest/some-other-file.txt"
touch "$populated/ood/lib/launch-common.sh"

found=$(bash -c ". '$populated/scripts/lib/app-dirs.sh' && ood_app_dirs" 2>/dev/null)

it "a directory holding a manifest.yml is discovered"
assert_contains "$found" "withmanifest"

it "a directory without a manifest.yml is not an app"
assert_not_contains "$found" "nomanifest"

it "ood/lib is excluded naturally, having no manifest of its own"
assert_not_contains "$found" "lib"

it "each app is printed on its own line, as the callers' for-loops assume"
assert_eq "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" "1"

it "app directory names are printed bare, not as paths"
assert_eq "$found" "withmanifest"

# --- the guard: empty discovery must fail, never return an empty success ----

empty=$(fake_repo empty)
mkdir -p "$empty/ood/notanapp"

it "a tree with no manifest at all fails nonzero rather than succeeding empty"
assert_failure bash -c ". '$empty/scripts/lib/app-dirs.sh' && ood_app_dirs"

it "the empty case explains itself on stderr"
assert_contains \
    "$(bash -c ". '$empty/scripts/lib/app-dirs.sh' && ood_app_dirs" 2>&1 >/dev/null)" \
    "ood/*/manifest.yml"

it "a caller that captures the list before looping propagates the failure"
# This is the shape every converted suite must use. `for a in $(ood_app_dirs)`
# does NOT work: bash discards a command substitution's exit status in a for
# list, and no suite here runs under `set -e`, so the naive form would iterate
# zero times and still report success -- exactly the vacuous pass the guard
# exists to prevent. Capturing first makes the status observable.
assert_failure bash -c \
    ". '$empty/scripts/lib/app-dirs.sh' && apps=\$(ood_app_dirs) && for a in \$apps; do :; done"

it "no caller in this repository uses the unsafe bare-substitution form"
# The guard above is only as good as the callers' discipline, so this asserts
# the discipline directly rather than trusting it.
# Comment lines are filtered rather than whole files, so that the two places
# that write the bad form down on purpose -- the comment above and the helper's
# own docstring -- do not have to be exempted as files, which would blind this
# check to a real call sneaking into either one.
# SC2016: the single quotes are the point -- this is a grep pattern matching
# the literal text `$(ood_app_dirs)` in other files, not an expansion.
# shellcheck disable=SC2016
unsafe=$(grep -rn 'in \$(ood_app_dirs)' ../scripts ../tests ../ood 2>/dev/null \
    | grep -v ':[[:space:]]*#' | cut -d: -f1 | sort -u | tr '\n' ' ')
assert_eq "$unsafe" ""

# --- the real repository ----------------------------------------------------

it "discovery finds at least one app in this repository"
# Deliberately not an assertion about WHICH apps: pinning the list here would
# reintroduce the per-app edit the helper exists to remove.
real=$(bash -c ". '$HELPER' && ood_app_dirs")
assert_success test -n "$real"

it "every discovered app names a real directory with a real manifest"
missing=""
for app in $real; do
    [ -f "../ood/$app/manifest.yml" ] || missing="$missing $app"
done
assert_eq "$missing" ""

finish
