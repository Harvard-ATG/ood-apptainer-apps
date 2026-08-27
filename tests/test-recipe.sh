#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

COMMON=../images/jupyter-codeserver-ai/common

it "versions.env exists"
assert_success test -f "$COMMON/versions.env"

it "versions.env is sourceable and defines every pin"
# shellcheck disable=SC1090,SC1091  # COMMON is a path variable; not resolvable statically
( . "$COMMON/versions.env" ) >/dev/null 2>&1
assert_success bash -c ". $COMMON/versions.env"

for v in JUPYTER_BASE_TAG UBUNTU_TAG NODE_VERSION CLAUDE_CODE_VERSION \
         CODEX_VERSION CODE_SERVER_VERSION UV_VERSION MICROMAMBA_VERSION; do
    it "versions.env defines $v"
    val=$(bash -c ". $COMMON/versions.env && printf '%s' \"\${$v:-}\"")
    assert_not_contains "|$val|" "||"
done

it "the Codex pin is at or above the floor where permission profiles are honoured"
# Below 0.138.0, allowed_permission_profiles and managed default_permissions are
# ignored outright -- the restriction is removed, not degraded.
cv=$(bash -c ". $COMMON/versions.env && printf '%s' \"\$CODEX_VERSION\"")
lowest=$(printf '0.138.0\n%s\n' "$cv" | sort -V | head -1)
assert_eq "$lowest" "0.138.0"

it "the Claude Code pin is at or above the floor for per-variable env merging"
cc=$(bash -c ". $COMMON/versions.env && printf '%s' \"\$CLAUDE_CODE_VERSION\"")
lowest=$(printf '2.1.223\n%s\n' "$cc" | sort -V | head -1)
assert_eq "$lowest" "2.1.223"

it "the Jupyter base tag pins a JupyterLab at or above 4.4"
jt=$(bash -c ". $COMMON/versions.env && printf '%s' \"\$JUPYTER_BASE_TAG\"")
assert_contains "$jt" "lab-"
labver=${jt#*lab-}
lowest=$(printf '4.4.0\n%s\n' "$labver" | sort -V | head -1)
assert_eq "$lowest" "4.4.0"

it "no base image is pinned to a floating tag"
assert_not_contains "$(cat "$COMMON/versions.env")" ":latest"
assert_not_contains "$(cat "$COMMON/versions.env")" "=latest"

CC="$COMMON/claude-code"

it "managed-settings.json exists"
assert_success test -f "$CC/managed-settings.json"

it "managed-settings.json is valid JSON"
assert_success python3 -c "import json;json.load(open('$CC/managed-settings.json'))"

it "managed-mcp.json exists and is valid JSON"
assert_success python3 -c "import json;json.load(open('$CC/managed-mcp.json'))"

it "the autoupdater is disabled through env, which merges per variable"
assert_eq "$(python3 -c "import json;print(json.load(open('$CC/managed-settings.json'))['env']['DISABLE_AUTOUPDATER'])")" "1"

it "sandbox helper binaries are pinned to absolute paths"
sb=$(python3 -c "import json;s=json.load(open('$CC/managed-settings.json'))['sandbox'];print(s['bwrapPath'],s['socatPath'])")
assert_contains "$sb" "/usr/bin/bwrap"
assert_contains "$sb" "/usr/bin/socat"

it "intent is recorded for the keys that are not cross-source"
s=$(cat "$CC/managed-settings.json")
assert_contains "$s" "failIfUnavailable"
assert_contains "$s" "disableBypassPermissionsMode"

it "no credential or token appears in the policy files"
for f in "$CC"/*.json; do
    assert_not_contains "$(tr '[:upper:]' '[:lower:]' < "$f")" "sk-"
done

it "filesystem denyRead mirrors Codex's asymmetry: denies the OTHER agent's credentials"
dr=$(python3 -c "import json;print(' '.join(json.load(open('$CC/managed-settings.json'))['sandbox']['filesystem']['denyRead']))")
assert_contains "$dr" "ood-huit/codex"
assert_not_contains "$dr" "ood-huit/claude"

finish
