#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh
# shellcheck source=lib/image.sh
. lib/image.sh

image_skip_unless_built codeserver
COMMON=../images/jupyter-codeserver-ai/common
want() { bash -c ". $COMMON/versions.env && printf '%s' \"\$$1\""; }

it "code-server is installed at the pinned version"
assert_contains "$(image_exec codeserver code-server --version 2>/dev/null)" "$(want CODE_SERVER_VERSION)"

it "the same Claude Code version as the JupyterLab image"
assert_contains "$(image_exec codeserver claude --version 2>/dev/null)" "$(want CLAUDE_CODE_VERSION)"

it "the same Codex version"
assert_contains "$(image_exec codeserver codex --version 2>/dev/null)" "$(want CODEX_VERSION)"

it "the immutable extensions directory exists"
assert_success image_exec codeserver test -d /opt/code-server/extensions

it "the extensions directory is not writable by an ordinary user"
assert_eq "$(image_exec codeserver stat -c '%a' /opt/code-server/extensions 2>/dev/null)" "755"

it "the seed machine settings disable workspace trust"
assert_contains "$(image_exec codeserver cat /etc/code-server/settings.json 2>/dev/null)" '"security.workspace.trust.enabled": false'

it "the seed settings are valid JSON"
assert_success image_exec codeserver python3 -c "import json,sys;json.load(open('/etc/code-server/settings.json'))"

it "the seed settings carry no course-specific path"
# python.defaultInterpreterPath is generated at launch, so the shared image
# cannot contain a course path.
assert_not_contains "$(image_exec codeserver cat /etc/code-server/settings.json 2>/dev/null)" "courseSharedFolders"

it "the sandbox helper binaries exist here too"
assert_success image_exec codeserver test -x /usr/bin/bwrap
assert_success image_exec codeserver test -x /usr/bin/socat

it "git is present"
assert_success image_exec codeserver git --version

it "no Jupyter runtime was inherited"
# codeserver derives from Ubuntu, not the Jupyter base. A jupyter binary here
# means the wrong base was used.
assert_failure image_exec codeserver sh -c 'command -v jupyter'

it "the build staging directory was removed"
assert_failure image_exec codeserver test -e /opt/build

it "both AI extensions are installed into the immutable directory"
exts=$(image_exec codeserver sh -c 'ls /opt/code-server/extensions' 2>/dev/null | tr '[:upper:]' '[:lower:]')
assert_contains "$exts" "anthropic.claude-code"
assert_contains "$exts" "openai.chatgpt"

# The install directory name carries no platform token, so the evidence that a
# build is glibc rather than musl is the platform-specific payload the vsix
# ships. That payload lives in DIFFERENT places per extension: openai.chatgpt
# puts native binaries under bin/<platform>/, while Anthropic.claude-code puts
# them under resources/audio-capture/<platform>/ and resources/native-binary/.
# A glob over */bin/*/ therefore matches only openai.chatgpt -- the Anthropic
# extension contributes NOTHING to it, so an alpine build of that extension
# would satisfy an assert_not_contains "alpine" vacuously. Check each extension
# on its own and require non-empty evidence from each.
#
# Architecture-agnostic: the platform tokens here are linux-aarch64 and
# arm64-linux, and linux-x64 / x64-linux on the cluster's x86_64, so assert on
# the shared "linux" token and the absence of "alpine" rather than on an arch.
for ext in anthropic.claude-code openai.chatgpt; do
    it "$ext: ships a linux, non-alpine platform payload"
    plat=$(image_exec codeserver sh -c \
        "find /opt/code-server/extensions/${ext}-*/ -type d \
             \( -name '*linux*' -o -name '*alpine*' -o -name '*musl*' \) -printf '%f\n'")
    # Non-empty first: an empty result would otherwise satisfy the
    # assert_not_contains below without proving anything.
    assert_not_contains "|$plat|" "||"
    assert_contains "$plat" "linux"
    assert_not_contains "$plat" "alpine"
done

it "anthropic.claude-code: the embedded native binary links against glibc, not musl"
# resources/native-binary/ carries no platform token in its NAME, so the scan
# above cannot speak for it. Read the ELF interpreter recorded in the binary
# itself: a glibc build names ld-linux-*, a musl build names ld-musl-*. This
# holds on either architecture (ld-linux-aarch64.so.1, ld-linux-x86-64.so.2).
interp=$(image_exec codeserver sh -c \
    "head -c 65536 /opt/code-server/extensions/anthropic.claude-code-*/resources/native-binary/claude \
     | tr -c '[:print:]' '\n' | grep -E 'ld-(linux|musl)[^ ]*\.so' | head -1")
assert_contains "$interp" "ld-linux"
assert_not_contains "$interp" "ld-musl"


it "each extension's bundled version is recorded separately from the system CLI"
# A passing system-CLI policy check is not evidence about an extension's
# embedded binary; the spec requires both be inventoried.
man=$(image_exec codeserver cat /etc/ood-ai/manifest.txt 2>/dev/null)
assert_contains "$man" "extension_"

it "the extension engine requirements are satisfied by the bundled Code version"
# code-server 4.135.0 bundles Code 1.135.0; the extensions require ^1.94.0 and
# ^1.96.2. Assert the bundled version rather than trusting the pin.
assert_contains "$(image_exec codeserver code-server --version 2>/dev/null)" "1.135"

it "no extension leaked into code-server's default user-data location"
# If --extensions-dir were ignored, the install would land in code-server's
# default user data directory instead of the image-owned one. /state does not
# exist at build time (it is job-local, created at launch), so asserting
# against it there would be vacuous -- this path is where a leak would
# actually land, since the build runs as root under fakeroot.
assert_failure image_exec codeserver test -e /root/.local/share/code-server/extensions

finish
