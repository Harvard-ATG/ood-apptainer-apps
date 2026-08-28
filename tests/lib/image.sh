# shellcheck shell=bash
# Locating and running built images. Builds are slow and produce large
# artifacts, so tests skip cleanly when an image is absent rather than failing
# and hiding real regressions in noise.

IMAGE_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_CACHE="$IMAGE_TESTS_DIR/.cache/images"

image_path() {
    local name="$1"
    for candidate in "$IMAGE_CACHE/$name.sif" "$IMAGE_CACHE/$name"; do
        [ -e "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

image_skip_unless_built() {
    local name="$1"
    if ! image_path "$name" >/dev/null; then
        printf '%s: SKIP (image %s not built; see the plan for the build step)\n' \
            "${0##*/}" "$name"
        exit 0
    fi
}

image_exec() {
    local name="$1"; shift
    local img
    img=$(image_path "$name") || return 1
    "${OOD_AI_APPTAINER_BIN:-apptainer}" exec "$img" "$@"
}
