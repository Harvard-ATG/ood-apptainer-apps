#!/usr/bin/env bash
# Copies the canonical shared launch library into each app's template/lib/.
#
# OOD stages only the template/ directory of an app, so a library outside it is
# never available at runtime. Rather than maintain two copies of the
# containment logic — which this app family has repeatedly shown leads to
# divergence — the canonical file is vendored and tests/test-no-drift.sh fails
# the build if the copies differ.
set -euo pipefail

cd "$(dirname "$0")/.."
CANON=ood/lib/launch-common.sh

for app in jupyterlab-ai codeserver-ai; do
    dest="ood/${app}/template/lib"
    mkdir -p "$dest"
    cp "$CANON" "$dest/launch-common.sh"
    chmod 644 "$dest/launch-common.sh"
    printf 'synced %s -> %s/launch-common.sh\n' "$CANON" "$dest"
done
