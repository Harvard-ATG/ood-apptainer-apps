#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

CANON=ood/lib/launch-common.sh

it "canonical shared library exists"
assert_success test -f "$CANON"

for app in jupyterlab-ai codeserver-ai; do
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

it "sync script is executable"
assert_success test -x scripts/sync-launch-lib.sh

it "sync script is idempotent"
bash scripts/sync-launch-lib.sh >/dev/null 2>&1
if git diff --quiet -- ood/jupyterlab-ai/template/lib ood/codeserver-ai/template/lib 2>/dev/null; then
    _pass
else
    _fail "running the sync script changed the tree; the vendored copies were stale"
fi

finish
