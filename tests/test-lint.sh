#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'test-lint.sh: SKIP (shellcheck not installed)\n'
    exit 0
fi

RENDER_TMP=$(mktemp -d)
trap 'rm -rf "$RENDER_TMP"' EXIT
SUB=tests/fixtures/sample-subapp.yml.erb

# Plain shell files, including the shared library and the in-container launchers.
while IFS= read -r f; do
    it "shellcheck: $f"
    # --source-path=SCRIPTDIR resolves `. lib/assert.sh` relative to the
    # script being checked rather than the caller's cwd, which is what the
    # `# shellcheck source=` directives in the test files assume.
    #
    # Default severity deliberately: info-level findings are kept. Files that
    # legitimately pass shell snippets as strings carry a justified file-level
    # `# shellcheck disable=SC2016` immediately after their shebang -- which is
    # where shellcheck requires a file-level directive, before any command.
    # Blanket-suppressing info with -S warning would lose real signal elsewhere.
    if out=$(shellcheck -s bash -x --source-path=SCRIPTDIR "$f" 2>&1); then _pass; else _fail "$out"; fi
# tests/.cache holds built Apptainer images, whose .singularity.d/ contains
# the runtime's own shell scripts. Those are not ours and do not lint clean.
done < <(find ood scripts tests -name '*.sh' -type f -not -path 'tests/.cache/*' | sort)

# ERB shell templates must be rendered before they are valid shell.
while IFS= read -r f; do
    it "shellcheck (rendered): $f"
    rendered="$RENDER_TMP/$(echo "$f" | tr '/' '_').sh"
    if ! FAKE_GROUPS='canvas170681-999' FAKE_STAGED_ROOT=/tmp/staged \
         ruby tests/render.rb --template "$f" --form "$SUB" > "$rendered" 2>"$rendered.err"; then
        _fail "render failed: $(cat "$rendered.err")"
        continue
    fi
    if out=$(shellcheck -s bash --source-path="$RENDER_TMP" "$rendered" 2>&1); then _pass; else _fail "$out"; fi
done < <(find ood -name '*.sh.erb' -type f | sort)

finish
