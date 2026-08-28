#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh
# shellcheck source=lib/image.sh
. lib/image.sh

image_skip_unless_built jupyterlab
COMMON=../images/jupyter-codeserver-ai/common
want() { bash -c ". $COMMON/versions.env && printf '%s' \"\$$1\""; }

it "Claude Code is installed at the pinned version"
assert_contains "$(image_exec jupyterlab claude --version 2>/dev/null)" "$(want CLAUDE_CODE_VERSION)"

it "Codex is installed at the pinned version"
assert_contains "$(image_exec jupyterlab codex --version 2>/dev/null)" "$(want CODEX_VERSION)"

it "both sandbox helper binaries exist at the paths the policy pins"
assert_success image_exec jupyterlab test -x /usr/bin/bwrap
assert_success image_exec jupyterlab test -x /usr/bin/socat

it "both environment managers are present"
assert_success image_exec jupyterlab uv --version
assert_success image_exec jupyterlab micromamba --version

it "git is present, which the supported gh workflow requires"
assert_success image_exec jupyterlab git --version

it "the Claude Code policy files are installed and world-readable"
assert_eq "$(image_exec jupyterlab stat -c '%a' /etc/claude-code/managed-settings.json 2>/dev/null)" "644"
assert_eq "$(image_exec jupyterlab stat -c '%a' /etc/claude-code/managed-mcp.json 2>/dev/null)" "644"

it "the Codex policy files are installed and world-readable"
assert_eq "$(image_exec jupyterlab stat -c '%a' /etc/codex/requirements.toml 2>/dev/null)" "644"
assert_eq "$(image_exec jupyterlab stat -c '%a' /etc/codex/managed_config.toml 2>/dev/null)" "644"

it "the installed policy matches the source, byte for byte"
src=$(sha256sum "$COMMON/codex/requirements.toml" | cut -d' ' -f1)
img=$(image_exec jupyterlab sha256sum /etc/codex/requirements.toml 2>/dev/null | cut -d' ' -f1)
assert_eq "$img" "$src"

it "the base's own kernelspec is gone"
# The stack registers a python3 kernelspec pointing at the image's conda
# interpreter. Left in place, students would see a kernel that silently lacks
# every course package.
assert_eq "$(image_exec jupyterlab sh -c 'ls /opt/conda/share/jupyter/kernels 2>/dev/null | wc -l')" "0"

it "no ipykernel kernelspec is registered anywhere in the image"
assert_not_contains "$(image_exec jupyterlab jupyter kernelspec list 2>&1)" "python3"

it "JupyterLab is present and runnable"
assert_contains "$(image_exec jupyterlab jupyter lab --version 2>/dev/null)" "4."

it "the build staging directory was removed"
assert_failure image_exec jupyterlab test -e /opt/build

it "the AI surface manifest was recorded"
assert_success image_exec jupyterlab test -f /etc/ood-ai/manifest.txt

finish
