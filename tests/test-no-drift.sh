#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

CANON=ood/lib/launch-common.sh

# shellcheck source=scripts/lib/app-dirs.sh
. scripts/lib/app-dirs.sh
apps=$(ood_app_dirs) || { it "app discovery"; _fail "ood_app_dirs failed"; finish; exit 1; }

it "canonical shared library exists"
assert_success test -f "$CANON"

for app in $apps; do
    vendored="ood/$app/template/lib/launch-common.sh"

    it "$app: vendored copy exists"
    assert_success test -f "$vendored"

    it "$app: vendored copy is byte-identical to the canonical source"
    if diff -q "$CANON" "$vendored" >/dev/null 2>&1; then
        _pass
    else
        _fail "drift detected. Run scripts/sync-launch-lib.sh$(printf '\n')$(diff "$CANON" "$vendored" | head -20)"
    fi
done

# Deliberately NOT generalised to every app, and deliberately not vendored.
# submit.yml.erb carries the script.native array, where an app declares things
# like --gres=gpu:1, so apps are meant to be free to differ. This names the two
# AI apps because those two are intended to match each other -- it catches
# someone editing one and forgetting the other -- and it is not a claim about
# the repository. A new app requires no edit here.
it "the two AI apps still share the submit template they are meant to share"
if diff -q ood/jupyterlab-ai/submit.yml.erb ood/codeserver-ai/submit.yml.erb >/dev/null 2>&1; then
    _pass
else
    _fail "drift between the two AI apps' submit.yml.erb$(printf '\n')$(diff ood/jupyterlab-ai/submit.yml.erb ood/codeserver-ai/submit.yml.erb | head -20)"
fi

it "sync script is executable"
assert_success test -x scripts/sync-launch-lib.sh

it "sync script is idempotent"
bash scripts/sync-launch-lib.sh >/dev/null 2>&1
vendored_dirs=()
for app in $apps; do vendored_dirs+=("ood/$app/template/lib"); done
if git diff --quiet -- "${vendored_dirs[@]}" 2>/dev/null; then
    _pass
else
    _fail "running the sync script changed the tree; the vendored copies were stale"
fi

finish
