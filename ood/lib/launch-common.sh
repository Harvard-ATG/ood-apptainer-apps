# shellcheck shell=bash
# Shared host-side launch logic for the -ai OOD apps.
#
# Canonical source: ood/lib/launch-common.sh
# Vendored into each app's template/lib/ by scripts/sync-launch-lib.sh, because
# OOD stages only the template/ directory. tests/test-no-drift.sh enforces that
# the copies stay byte-identical.
#
# Every containment decision lives here so the two apps cannot diverge.

: "${OOD_AI_IMAGE_ROOT_FAST:=/scratch/apptainerImages}"
: "${OOD_AI_IMAGE_ROOT_CANONICAL:=/shared/apptainerImages}"

lc_log() {
    # stderr, not stdout. lc_select_image, lc_validate_under and lc_apptainer_bin
    # all return their value on stdout, so a log line there would be captured into
    # the caller's variable -- putting a timestamped log line inside an image path.
    # OOD directs both streams to the session log, so nothing is lost.
    echo -e "[$(date -Iseconds)][${this_script:-launch-common}] $1" >&2
}

lc_file_size() {
    stat -c '%s' "$1" 2>/dev/null || printf ''
}

# lc_select_image <imagefile relative to an image root>
#
# Echoes the absolute path to launch from. Prefers the Lustre copy when it
# exists and its size matches the authoritative EFS copy; otherwise falls back
# to EFS and says so. Never writes to either root: a hundred sessions
# discovering the same cache miss would each start copying the same
# multi-gigabyte file, producing contention and partial files exactly when load
# is highest. Populating the fast root is an administrative deploy step.
lc_select_image() {
    local rel="$1"
    local fast="${OOD_AI_IMAGE_ROOT_FAST}/${rel}"
    local canonical="${OOD_AI_IMAGE_ROOT_CANONICAL}/${rel}"

    if [ ! -e "$canonical" ]; then
        lc_log "ERROR: image not found at authoritative path: ${canonical}"
        return 1
    fi

    if [ -e "$fast" ]; then
        local size_fast size_canonical
        size_fast=$(lc_file_size "$fast")
        size_canonical=$(lc_file_size "$canonical")
        if [ -n "$size_fast" ] && [ "$size_fast" = "$size_canonical" ]; then
            lc_log "Using fast image root: ${fast}"
            printf '%s\n' "$fast"
            return 0
        fi
        lc_log "WARNING: fast copy size mismatch (fast=${size_fast:-none} authoritative=${size_canonical:-none}); using ${canonical}"
    else
        lc_log "WARNING: no fast copy at ${fast}; using ${canonical} (slower startup)"
    fi

    printf '%s\n' "$canonical"
}
