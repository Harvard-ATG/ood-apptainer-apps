# shellcheck shell=bash
# Discovering the OOD apps in this repository.
#
# An app is a directory under ood/ that holds a manifest.yml. That is OOD's own
# predicate for registering an app, not one invented here, which is why ood/lib/
# is excluded without having to be named: it is vendored launch logic, not an
# app, and has no manifest.
#
# The point of discovering rather than listing is that adding ood/rstudio/ then
# costs no edit to the tooling or the suites that loop over apps. The cost is
# that an empty result is possible where a hardcoded list could not be empty, so
# ood_app_dirs fails rather than returning nothing -- see the guard below.

# Prints one app directory name per line. Fails nonzero, with an explanation on
# stderr, if no app is found.
#
# Callers MUST capture before looping:
#
#     apps=$(ood_app_dirs) || exit 1
#     for app in $apps; do ...
#
# and not `for app in $(ood_app_dirs)`, which discards the exit status: bash
# ignores a command substitution's status in a for list, so an empty discovery
# would iterate zero times and still look like success.
ood_app_dirs() {
    local repo_root manifest app found=0

    # Resolved from this file's location, deliberately not from cwd: the suites
    # disagree about cwd (test-envs.sh cds to the repo root, test-images.sh
    # stays in tests/), so anything cwd-derived would work in only some of them.
    repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || return 1

    for manifest in "$repo_root"/ood/*/manifest.yml; do
        # An unmatched glob comes back literally, so this also covers "no apps".
        [ -f "$manifest" ] || continue
        app=${manifest%/manifest.yml}
        printf '%s\n' "${app##*/}"
        found=1
    done

    if [ "$found" -eq 0 ]; then
        printf '%s: no ood/*/manifest.yml found under %s\n' \
            "${FUNCNAME[0]}" "$repo_root" >&2
        return 1
    fi
}
