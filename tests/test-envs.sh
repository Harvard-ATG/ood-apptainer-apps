#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

for course in am115 cs1090a; do
    D="images/jupyter-codeserver-ai/envs/$course"

    it "$course: declares a manager"
    assert_success test -f "$D/manager"

    it "$course: the manager is one this project supports"
    m=$(tr -d '[:space:]' < "$D/manager" 2>/dev/null)
    case "$m" in micromamba|uv) _pass ;; *) _fail "manager is '$m'" ;; esac

    it "$course: declares a Python version"
    assert_success grep -qE '^3\.[0-9]+$' "$D/python-version"

    it "$course: the source files match the declared manager"
    if [ "$m" = micromamba ]; then
        assert_success test -f "$D/environment.yml"
    else
        assert_success test -f "$D/pyproject.toml"
    fi

    it "$course: pins the configured Python version in the source file"
    assert_contains "$(cat "$D"/environment.yml "$D"/pyproject.toml 2>/dev/null)" "$(cat "$D/python-version")"

    it "$course: includes ipykernel, without which no kernel can start"
    assert_contains "$(cat "$D"/environment.yml "$D"/pyproject.toml 2>/dev/null)" "ipykernel"

    it "$course: does NOT carry server-side packages that belong in the image"
    # A JupyterLab in the course environment is not merely redundant: the
    # launcher prepends this prefix to PATH, so it would shadow the image's.
    body=$(cat "$D"/environment.yml "$D"/pyproject.toml 2>/dev/null)
    for pkg in jupyterlab jupyterlab-git nbdime jupytext notebook-intelligence nodejs; do
        assert_not_contains "$body" "- $pkg"
    done
done

it "cs1090a keeps the otter-grader upper bound the course asked us not to cross"
assert_contains "$(cat images/jupyter-codeserver-ai/envs/cs1090a/environment.yml)" "otter-grader>=7,<8"

it "a staff-facing README template exists to be written beside the prefixes"
assert_success test -f images/jupyter-codeserver-ai/envs/README-template.md

finish
