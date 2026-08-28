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

it "the installed extension builds are glibc, not musl"
# The install directory name carries no platform token, so assert on the
# platform-specific native binaries the vsix ships. An alpine (musl) build
# ships bin/alpine-*; a glibc build ships bin/linux-*.
bins=$(image_exec codeserver sh -c 'ls -d /opt/code-server/extensions/*/bin/*/ 2>/dev/null')
assert_contains "$bins" "linux-"
assert_not_contains "$bins" "alpine"

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
