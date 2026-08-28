#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh
# shellcheck source=lib/image.sh
. lib/image.sh

image_skip_unless_built jupyterlab
image_skip_unless_built codeserver

it "both images report the same Claude Code version"
a=$(image_exec jupyterlab claude --version 2>/dev/null)
b=$(image_exec codeserver claude --version 2>/dev/null)
# A command that fails in BOTH images yields two empty strings, which would
# compare equal and pass while testing nothing. Require real output first.
assert_success test -n "$a"
assert_eq "$b" "$a"

it "both images report the same Codex version"
a=$(image_exec jupyterlab codex --version 2>/dev/null)
b=$(image_exec codeserver codex --version 2>/dev/null)
# A command that fails in BOTH images yields two empty strings, which would
# compare equal and pass while testing nothing. Require real output first.
assert_success test -n "$a"
assert_eq "$b" "$a"

it "both images report the same Node version"
a=$(image_exec jupyterlab node --version 2>/dev/null)
b=$(image_exec codeserver node --version 2>/dev/null)
# A command that fails in BOTH images yields two empty strings, which would
# compare equal and pass while testing nothing. Require real output first.
assert_success test -n "$a"
assert_eq "$b" "$a"

for f in /etc/claude-code/managed-settings.json /etc/claude-code/managed-mcp.json \
         /etc/codex/requirements.toml /etc/codex/managed_config.toml; do
    it "both images carry an identical $f"
    a=$(image_exec jupyterlab sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
    b=$(image_exec codeserver sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
    # A path missing (or unreadable) in BOTH images yields two empty
    # checksums, which would compare equal and pass while testing nothing.
    # Require a real checksum first.
    assert_success test -n "$a"
    assert_eq "$b" "$a"
done

it "neither image is missing a governance file the other has"
la=$(image_exec jupyterlab sh -c 'ls /etc/claude-code /etc/codex' 2>/dev/null | sort)
lb=$(image_exec codeserver sh -c 'ls /etc/claude-code /etc/codex' 2>/dev/null | sort)
# If both directories were empty or unreadable in BOTH images, this would
# still compare equal and pass while testing nothing. Require a real listing
# first.
assert_success test -n "$la"
assert_eq "$lb" "$la"

it "the recorded AI surface manifests agree on everything except arch and extensions"
strip() { grep -vE '^(arch=|extension_)' ; }
a=$(image_exec jupyterlab cat /etc/ood-ai/manifest.txt 2>/dev/null | strip)
b=$(image_exec codeserver cat /etc/ood-ai/manifest.txt 2>/dev/null | strip)
# A missing or unreadable manifest in BOTH images would still compare equal
# and pass while testing nothing. Require real manifest content first.
assert_success test -n "$a"
assert_eq "$b" "$a"

finish
