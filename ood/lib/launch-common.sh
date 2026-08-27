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

# lc_write_env_file <path> <KEY=VALUE>...
#
# Apptainer reads --env-file lines literally: there is no shell expansion. A
# value containing '$' therefore reaches the container unexpanded, which is
# always a bug, so it is rejected here rather than debugged later. Created under
# umask 077 in a subshell so the file is never briefly world-readable.
lc_write_env_file() {
    local path="$1"
    shift

    local kv
    for kv in "$@"; do
        case "$kv" in
            *'$'*)
                lc_log "ERROR: environment value is not expanded: ${kv%%=*}=... (env files are literal)"
                return 1
                ;;
            *$'\n'*)
                # NOT *"$(printf '\n')"*: command substitution strips trailing
                # newlines, making that pattern *""* -- which matches every input
                # and would reject every call.
                lc_log "ERROR: environment value contains a newline: ${kv%%=*}"
                return 1
                ;;
        esac
    done

    ( umask 077; : > "$path" ) || return 1
    for kv in "$@"; do
        printf '%s\n' "$kv" >> "$path"
    done
    chmod 600 "$path"
}

# lc_apptainer_bin
#
# Echoes the absolute path to the centrally managed Apptainer executable. Spack
# is sourced only to locate it; the resolved path is then invoked directly, so
# nothing downstream depends on an activated Spack environment.
lc_apptainer_bin() {
    if [ -n "${OOD_AI_APPTAINER_BIN:-}" ]; then
        printf '%s\n' "$OOD_AI_APPTAINER_BIN"
        return 0
    fi

    local setup=/shared/spack/share/spack/setup-env.sh
    if [ ! -r "$setup" ]; then
        lc_log "ERROR: Spack setup not readable at ${setup}"
        return 1
    fi
    # shellcheck disable=SC1090
    . "$setup" || { lc_log "ERROR: sourcing Spack setup failed"; return 1; }
    spack env activate apptainer || { lc_log "ERROR: activating Spack env 'apptainer' failed"; return 1; }

    local bin
    bin=$(command -v apptainer) || { lc_log "ERROR: apptainer not on PATH after activation"; return 1; }
    printf '%s\n' "$bin"
}

# lc_sterile_prefix
#
# Populates LC_STERILE with the env -i prefix used to invoke Apptainer. Nothing
# inherited reaches Apptainer, so no APPTAINER_*, APPTAINERENV_*, SINGULARITY_*
# or SINGULARITYENV_* variable can influence binds, mounts, home, overlays, or
# any future runtime control. LC_LD_LIBRARY_PATH exists because a Spack-built
# Apptainer may need its view's libraries; the cluster preflight determines
# whether it is required.
lc_sterile_prefix() {
    LC_STERILE=( env -i "PATH=/usr/bin:/bin" )
    if [ -n "${LC_LD_LIBRARY_PATH:-}" ]; then
        LC_STERILE+=( "LD_LIBRARY_PATH=${LC_LD_LIBRARY_PATH}" )
    fi
}

# lc_validate_under <target> <root>
#
# Echoes the fully resolved target when it stays beneath root; fails otherwise.
# Callers must use the echoed value for the lifetime of the job, so that a
# staff symlink switch mid-session cannot move a running job's prefix.
# realpath -m resolves without requiring every component to exist.
lc_validate_under() {
    local target="$1" root="$2" resolved_target resolved_root

    resolved_target=$(realpath -m "$target" 2>/dev/null) || {
        lc_log "ERROR: cannot resolve ${target}"
        return 1
    }
    resolved_root=$(realpath -m "$root" 2>/dev/null) || {
        lc_log "ERROR: cannot resolve root ${root}"
        return 1
    }

    case "$resolved_target" in
        "$resolved_root"|"$resolved_root"/*)
            printf '%s\n' "$resolved_target"
            return 0
            ;;
        *)
            lc_log "ERROR: ${target} resolves to ${resolved_target}, which escapes ${resolved_root}"
            return 1
            ;;
    esac
}

# lc_make_state_dirs <dir>...
lc_make_state_dirs() {
    local d
    for d in "$@"; do
        ( umask 077; mkdir -p "$d" ) || return 1
        chmod 700 "$d" || return 1
    done
}

# lc_build_binds <course_folder> <scratch_root> <job_state> <job_tmp> <ssh_mask>
#
# Populates LC_BINDS. The real home is deliberately absent: it is mounted by
# --home, because --env-file cannot set HOME and Apptainer otherwise derives it
# from the passwd entry. Binds are kept in an array and expanded quoted at the
# call site; flattening them into a string has been introduced, corrected, and
# re-introduced in this app family.
lc_build_binds() {
    local course="$1" scratch="$2" job_state="$3" job_tmp="$4" ssh_mask="$5"
    LC_BINDS=(
        -B "${course}:${course}"
        -B "${scratch}:${scratch}"
        -B "${job_state}:/state"
        -B "${job_tmp}:/tmp"
        -B "${ssh_mask}:${HOME}/.ssh"
    )
}
