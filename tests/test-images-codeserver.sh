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

finish
