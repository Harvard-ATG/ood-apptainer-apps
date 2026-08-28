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

it "jupyter exists and is executable at the absolute path the launcher execs"
# The container environment file sets PATH=/usr/local/bin:/usr/bin:/bin, which
# deliberately omits /opt/conda/bin (see jupyterlab.script.sh). The launcher
# therefore execs /opt/conda/bin/jupyter by absolute path; if the base ever
# moved it, the app would fail to start and every other check here -- which
# runs under the IMAGE's own PATH, not the launch PATH -- would still pass.
assert_success image_exec jupyterlab test -x /opt/conda/bin/jupyter

it "the launcher's exec target resolves under the launch PATH, not just the image PATH"
# Runs `command -v` with exactly the env-file PATH, which is the condition the
# real session runs under.
assert_eq "$(image_exec jupyterlab env PATH=/usr/local/bin:/usr/bin:/bin \
    sh -c 'command -v /opt/conda/bin/jupyter' 2>/dev/null)" "/opt/conda/bin/jupyter"

it "the build staging directory was removed"
assert_failure image_exec jupyterlab test -e /opt/build

it "the AI surface manifest was recorded"
assert_success image_exec jupyterlab test -f /etc/ood-ai/manifest.txt

it "the image's own interpreter exists, is executable, and can import ipykernel"
# This is the interpreter that backs the fallback "image-python" kernel
# jupyterlab.script.sh generates unconditionally (see write_kernel /
# IMAGE_PYTHON). Nothing else in this suite checks that the shipped image
# actually has a working interpreter at that path.
assert_success image_exec jupyterlab test -x /opt/conda/bin/python
assert_success image_exec jupyterlab /opt/conda/bin/python -c 'import ipykernel'

finish
