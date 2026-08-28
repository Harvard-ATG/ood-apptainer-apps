#!/usr/bin/env bash
# SC2016: many assertions below match the LITERAL ${...} text of the image
# definition and policy files, so those expressions must NOT expand here. Every
# occurrence in this file is deliberate. A file-level directive has to precede
# every command, so it sits immediately after the shebang.
# shellcheck disable=SC2016
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
         CODEX_VERSION CODE_SERVER_VERSION UV_VERSION MICROMAMBA_VERSION \
         CLAUDE_EXT_ID CLAUDE_EXT_VERSION CODEX_EXT_ID CODEX_EXT_VERSION; do
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

it "an unavailable sandbox degrades the session rather than failing it"
# The key's presence says nothing about its value. Flipped to true, a sandbox
# that cannot start turns into a failed student session instead of an
# unsandboxed one, so assert the value explicitly.
assert_eq "$(python3 -c "import json;print(json.load(open('$CC/managed-settings.json'))['sandbox']['failIfUnavailable'])")" "False"

it "no credential or token appears in the policy files"
for f in "$CC"/*.json; do
    assert_not_contains "$(tr '[:upper:]' '[:lower:]' < "$f")" "sk-"
done

it "filesystem denyRead mirrors Codex's asymmetry: denies the OTHER agent's credentials"
dr=$(python3 -c "import json;print(' '.join(json.load(open('$CC/managed-settings.json'))['sandbox']['filesystem']['denyRead']))")
assert_contains "$dr" "/.codex"
assert_not_contains "$dr" "/.claude"

CX="$COMMON/codex"

it "requirements.toml exists and parses"
assert_success python3 -c "import tomllib;tomllib.load(open('$CX/requirements.toml','rb'))"

it "managed_config.toml exists and parses"
assert_success python3 -c "import tomllib;tomllib.load(open('$CX/managed_config.toml','rb'))"

it "update checks are disabled in the ENFORCED file, not merely the defaults"
assert_eq "$(python3 -c "import tomllib;print(tomllib.load(open('$CX/requirements.toml','rb'))['check_for_update_on_startup'])")" "False"

it "allowed_permission_profiles is a table, not an array"
assert_eq "$(python3 -c "import tomllib;print(type(tomllib.load(open('$CX/requirements.toml','rb'))['allowed_permission_profiles']).__name__)")" "dict"

it "full access is denied by omission"
prof=$(python3 -c "import tomllib;print(sorted(tomllib.load(open('$CX/requirements.toml','rb'))['allowed_permission_profiles']))")
assert_not_contains "$prof" "danger-full-access"

it "managed hooks are required"
assert_eq "$(python3 -c "import tomllib;print(tomllib.load(open('$CX/requirements.toml','rb'))['allow_managed_hooks_only'])")" "True"

it "plugins are disabled"
assert_eq "$(python3 -c "import tomllib;print(tomllib.load(open('$CX/requirements.toml','rb'))['features']['plugins'])")" "False"

it "an explicit MCP allowlist is present and empty"
assert_eq "$(python3 -c "import tomllib;print(len(tomllib.load(open('$CX/requirements.toml','rb'))['mcp_servers']))")" "0"

it "deny_read covers ssh, the GitHub token and the other agent's credential path"
dr=$(python3 -c "import tomllib;print(' '.join(tomllib.load(open('$CX/requirements.toml','rb'))['permissions']['filesystem']['deny_read']))")
for p in ".ssh" "gh" "/.claude"; do
    assert_contains "$dr" "$p"
done

it "deny_read does NOT deny Codex its own credentials, which would break login"
# The mirror image of the Claude Code assertion above. Each agent denies only
# the OTHER agent's credential path; a regression that added Codex's own path
# here would break Codex login and, asserting presence only, pass silently.
assert_not_contains "$dr" "/.codex"

it "deny_read uses no ./-relative entries, which the schema rejects"
assert_not_contains "$dr" "./"

RECIPE="$COMMON/install-ai-agents.sh"

it "the recipe exists and is executable"
assert_success test -x "$RECIPE"

it "the recipe stages from /opt/build, never /tmp"
# Apptainer bind-mounts the host /tmp over the container's during %post, so
# anything staged there is invisible to the build.
body=$(cat "$RECIPE")
assert_contains "$body" "/opt/build"
assert_not_contains "$body" "/tmp/build"

it "the recipe fails on any error rather than shipping a partial image"
assert_contains "$body" "set -euo pipefail"

it "the recipe hardcodes no version"
for v in 2.1.248 0.150.1 4.135.0 24.20.0 0.12.7; do
    assert_not_contains "$body" "$v"
done

it "the recipe reads every version from versions.env"
assert_contains "$body" "versions.env"

it "the recipe detects architecture rather than assuming one"
assert_contains "$body" "uname -m"

it "the recipe verifies what it downloaded before trusting it"
assert_contains "$body" "sha256sum"

it "the recipe removes its staging directory"
assert_contains "$body" "rm -rf /opt/build"

it "npm installs onto /usr/local, not the unreachable node-resolved prefix"
# npm's default global prefix resolves from the running node binary's real path,
# which is under NODE_HOME and never on PATH. Without forcing the prefix, the
# claude and codex executables npm writes would be unreachable by name.
assert_contains "$body" "NPM_CONFIG_PREFIX=/usr/local"

it "the manifest never suppresses a CLI's stderr"
# Suppressing stderr on claude/codex/uv/micromamba --version would discard the
# diagnostic that a broken install needs to be caught at build time.
assert_not_contains "$body" "2>/dev/null"

it "the manifest captures each version through a plain assignment, so a broken install trips set -e"
for var in claude_version codex_version node_version uv_version micromamba_version; do
    assert_contains "$body" "${var}="
done

# ---------------------------------------------------------------------------
# Definition files. Nothing else in the suite reads them: test-lint.sh matches
# only *.sh and *.env, and a .def is not a shell script -- shellcheck fails on
# the Apptainer header -- so adding them there is not an option. These static
# checks need no built image.
#
# The base-tag assertion is the load-bearing one. It is the ONLY thing tying
# the literal tag the build actually consumes to the pin in versions.env, and
# the expected value is derived from versions.env rather than written out
# here, so bumping the pin without bumping the definition fails.
# ---------------------------------------------------------------------------
IMAGES=../images/jupyter-codeserver-ai

def_base_tag() {
    # Apptainer keeps any registry in its own `Registry:` header, so the tag is
    # simply everything after the last colon of the `From:` reference.
    local ref
    ref=$(grep -m1 '^From:' "$1" | awk '{print $2}')
    printf '%s' "${ref##*:}"
}

for spec in "jupyterlab/jupyterlab.def:JUPYTER_BASE_TAG" \
            "codeserver/codeserver.def:UBUNTU_TAG"; do
    def="$IMAGES/${spec%%:*}"
    pin="${spec##*:}"
    def_name=$(basename "$def")
    def_body=$(cat "$def")

    it "$def_name: the literal base tag matches the $pin pin in versions.env"
    want=$(bash -c ". $COMMON/versions.env && printf '%s' \"\$$pin\"")
    # Guard the comparison itself: an unset pin would otherwise make an empty
    # tag match an empty expectation.
    assert_not_contains "|$want|" "||"
    assert_eq "$(def_base_tag "$def")" "$want"

    it "$def_name: %post runs under bash, which the recipe's syntax requires"
    assert_contains "$def_body" "%post -c /bin/bash"

    it "$def_name: does not suppress failures with '|| true'"
    assert_not_contains "$def_body" "|| true"

    it "$def_name: does not disable errexit to hide a failure"
    assert_not_contains "$def_body" "set +e"

    it "$def_name: stages from /opt/build, never /tmp"
    # Apptainer bind-mounts the host /tmp over the container's during %post, so
    # anything staged there is invisible to the build.
    assert_contains "$def_body" "/opt/build"
    assert_not_contains "$def_body" "/tmp/build"
done

# --- the course-requested editor and JupyterLab extensions -------------------

V="$COMMON/versions.env"
CSDEF="$IMAGES/codeserver/codeserver.def"
JLDEF="$IMAGES/jupyterlab/jupyterlab.def"

it "the three course editor extensions are pinned to exact versions"
# Exact, not floors: editor extensions are pinned together with code-server
# because compatibility depends on the pair.
for var in PYTHON_EXT_VERSION JUPYTER_EXT_VERSION RENDERERS_EXT_VERSION; do
    assert_success grep -qE "^${var}=\"[0-9]+(\.[0-9]+)+\"$" "$V"
done

it "ms-python.python is pinned, because it is what reads defaultInterpreterPath"
assert_contains "$(cat "$V")" 'PYTHON_EXT_ID="ms-python.python"'

it "codeserver.def installs all five extensions from versions.env"
body=$(cat "$CSDEF")
for var in CLAUDE_EXT_ID CODEX_EXT_ID PYTHON_EXT_ID JUPYTER_EXT_ID RENDERERS_EXT_ID; do
    assert_contains "$body" "\${${var}}"
done

it "codeserver.def distinguishes per-platform extensions from universal ones"
# The two AI extensions MUST name a platform -- unqualified resolves to an
# alpine/musl build. The three course extensions publish only a universal
# build, for which the qualified URL 404s. Getting either wrong fails the build,
# but in opposite directions.
assert_contains "$body" ':platform"'
assert_contains "$body" ':universal"'

it "the universal download URL omits the platform segment and the @platform suffix"
assert_contains "$body" '${ns}/${nm}/${ext_ver}/file/${ext_id}-${ext_ver}"'

it "jupyterlab.def sources versions.env before the recipe deletes it"
jl=$(cat "$JLDEF")
src_pos=$(printf '%s' "$jl" | grep -n '^\s*\. /opt/build/versions.env' | head -1 | cut -d: -f1)
# Anchor on the INVOCATION, not any mention: the %files section stages the
# recipe several lines earlier, and matching that made this compare against the
# wrong line entirely.
recipe_pos=$(printf '%s' "$jl" | grep -n '^\s*bash /opt/build/install-ai-agents.sh' | head -1 | cut -d: -f1)
assert_eq "$([ "$src_pos" -lt "$recipe_pos" ] && echo before || echo after)" "before"

it "jupyterlab.def writes its manifest fragment before the recipe absorbs it"
# The redirect that WRITES it, not the comment that describes it.
frag_pos=$(printf '%s' "$jl" | grep -n '^\s*} > /opt/build/extension-manifest.txt' | head -1 | cut -d: -f1)
assert_eq "$([ "$frag_pos" -lt "$recipe_pos" ] && echo before || echo after)" "before"

it "jupyterlab.def pins JupyterLab to the base image tag during the install"
# Otherwise the solver may move JupyterLab to satisfy an extension, silently
# changing the one thing the base tag exists to fix.
assert_contains "$jl" 'JUPYTERLAB_VERSION="${JUPYTER_BASE_TAG#lab-}"'
assert_contains "$jl" '"jupyterlab=${JUPYTERLAB_VERSION}"'

it "jupyterlab.def FAILS the build if JupyterLab moved anyway"
assert_contains "$jl" "JupyterLab moved from"

it "jupyterlab.def installs the front-end half of ipywidgets"
# Both course environments list ipywidgets for the kernel side; without this
# package its widget output renders as nothing.
assert_contains "$jl" "jupyterlab_widgets"

it "notebook-intelligence is floored, not pinned, per both course requests"
assert_success grep -qE '^NOTEBOOK_INTELLIGENCE_FLOOR="[0-9]+(\.[0-9]+)+"$' "$V"
assert_contains "$jl" 'notebook-intelligence>=${NOTEBOOK_INTELLIGENCE_FLOOR}'

it "JupyterLab itself is NOT pinned back to silence a compatibility warning"
# Both requesters tested notebook-intelligence against JupyterLab 4.6, confirmed
# it works, and asked explicitly that JupyterLab not be moved back.
assert_contains "$(cat "$V")" 'JUPYTER_BASE_TAG="lab-4.6.3"'

finish
