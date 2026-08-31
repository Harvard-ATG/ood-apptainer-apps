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
    local key value
    for kv in "$@"; do
        key="${kv%%=*}"
        value="${kv#*=}"
        # Apptainer EVALUATES this file as a shell-ish script rather than reading
        # it as plain key=value pairs, so an unquoted value containing a space is
        # parsed as a command and aborts the launch outright:
        #   COURSE_LABEL=APMTH 115
        #   FATAL: while evaluating environment script: could not execute "115"
        # Every value is therefore quoted, and the characters double quotes do
        # not protect are escaped. `$` and newlines are rejected above, so only
        # backslash, double quote and backtick remain.
        value=${value//\\/\\\\}
        value=${value//\"/\\\"}
        value=${value//\`/\\\`}
        printf '%s="%s"\n' "$key" "$value" >> "$path"
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

# lc_classify_course_env <environment_root> <course_folder>
#
# Sets LC_COURSE_ENV to the resolved <environment_root>/default and
# LC_COURSE_ENV_STATUS to "ok" or "missing". Returns nonzero ONLY when the
# prefix escapes the course folder.
#
# The asymmetry is deliberate. An escaping path is a containment failure and
# must stop the launch. An absent prefix is an ordinary operational state --
# the environment has not been provisioned yet, or a staff update removed it --
# and stopping the launch for it leaves the student with a failed job and no
# way to see why. The session starts either way; only the kernel set degrades.
#
# What is NOT checked here: whether the interpreter actually runs. The compute
# node and the image do not share a libc, so a probe that succeeds on the host
# can still fail inside the container. That probe belongs to the in-container
# launcher, which is the only place its answer is true.
#
# shellcheck disable=SC2034
# LC_COURSE_ENV and LC_COURSE_ENV_STATUS are outputs: this file is linted in
# isolation, so shellcheck cannot see the callers (script.sh.erb, and this
# file's own test suite) that read them after this function returns.
lc_classify_course_env() {
    local env_root="$1" course_folder="$2" prefix

    prefix=$(lc_validate_under "${env_root}/default" "${course_folder}") || return 1
    LC_COURSE_ENV="$prefix"

    if [ -x "${prefix}/bin/python" ]; then
        LC_COURSE_ENV_STATUS="ok"
        lc_log "course environment=${prefix}"
        return 0
    fi

    LC_COURSE_ENV_STATUS="missing"
    lc_log "WARNING: no executable interpreter at ${prefix}/bin/python"
    lc_log "WARNING: the course environment is not available; the session will START but will"
    lc_log "WARNING: offer only the image kernel, which has no course packages."
    return 0
}

# lc_resolve_staging <environment_root> <course_folder>
#
# Echoes the resolved <environment_root>/staging, or nothing when it escapes the
# course folder. Whether this user may SEE a staging kernel is decided in the
# container by [ -w "$ENVIRONMENT_ROOT" ]: the staff group cannot be named
# there, so group membership is not a question that can be asked.
lc_resolve_staging() {
    local env_root="$1" course_folder="$2" resolved
    if resolved=$(lc_validate_under "${env_root}/staging" "${course_folder}" 2>/dev/null); then
        printf '%s\n' "$resolved"
    else
        lc_log "WARNING: ${env_root}/staging escapes ${course_folder}; no staging kernel"
    fi
    return 0
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
# Populates LC_BINDS. The real home needs BOTH --home (to set HOME, since
# --env-file cannot) AND an explicit bind here (to actually mount it):
# lc_run's --no-mount home,... suppresses the mount that --home would
# otherwise perform on its own, so without this bind the container's HOME
# points at a path that does not exist inside the container.
#
# The home bind must come FIRST, before the .ssh mask: the mask's destination
# is a path beneath home, and Apptainer applies binds in order, so mounting
# the mask before home exists fails the launch outright with
# "destination .../.ssh doesn't exist in container".
#
# Binds are kept in an array and expanded quoted at the call site; flattening
# them into a string has been introduced, corrected, and re-introduced in this
# app family.
lc_build_binds() {
    local course="$1" scratch="$2" job_state="$3" job_tmp="$4" ssh_mask="$5"
    LC_BINDS=(
        -B "${HOME}:${HOME}"
        -B "${course}:${course}"
        -B "${scratch}:${scratch}"
        -B "${job_state}:/state"
        -B "${job_tmp}:/tmp"
        -B "${ssh_mask}:${HOME}/.ssh"
    )
}

# lc_run <apptainer_bin> <image> <env_file> <inner_cmd>...
#
# Runs Apptainer as an ordinary child process. It is deliberately NOT exec'd:
# OOD's basic Batch Connect template backgrounds script.sh, records its pid as
# SCRIPT_PID, and after.sh reaps the session with pkill -P "${SCRIPT_PID}" when
# startup fails. Replacing the shell would break that contract. Signal delivery
# to the server is handled instead by the in-container launcher, which execs the
# server so it becomes the container's first process.
#
# LC_BINDS must be populated by lc_build_binds first.
lc_run() {
    local bin="$1" image="$2" env_file="$3"
    shift 3

    lc_sterile_prefix

    # --underlay is what makes the AGENTS' OWN sandboxes work. It is the one flag
    # here that is not about containment.
    #
    # Apptainer's default overlay leaves the container root MNT_UNBINDABLE, and on
    # this cluster's kernel that flag survives the clone(CLONE_NEWNS|CLONE_NEWUSER)
    # that bubblewrap makes for itself. bwrap's next step binds /oldroot onto
    # /newroot, the kernel rejects a bind whose source is unbindable, and it dies:
    #
    #   bwrap: Can't bind mount /oldroot/ on /newroot/: Invalid argument
    #
    # Both agents hit this, at different moments, and the asymmetry is the useful
    # diagnostic. Codex sandboxes even its read of AGENTS.md, so it fails at
    # session start, fatally, every time. Claude Code bootstraps its sandbox on
    # the first Bash tool call instead, so the same failure surfaces later, as a
    # refusal that names the bwrap error and points at /sandbox. "Claude seemed
    # fine" usually means no Bash call has been made yet, not that its sandbox is
    # inert. --underlay assembles the root as a bindable tmpfs instead, and every
    # bwrap in the image then succeeds.
    #
    # Containment is unaffected either way: every mount underlay adds is sourced
    # from the image or the session tmpfs, never the host disk, and the ~/.ssh mask
    # survives it. The bind allowlist below remains the security boundary.
    #
    # -B /dev/full:/dev/full repairs what --containall removes. --containall
    # replaces /dev with a minimal fake one providing null, zero, random, urandom
    # and tty; measured against this image, the only entries it drops are `core`
    # and `full`. Codex's real workspace-write sandbox binds /dev/full while
    # assembling itself, and bwrap cannot bind a source that does not exist:
    #
    #   bwrap: Can't bind mount /oldroot/dev/full on /newroot/dev/full:
    #          No such file or directory
    #
    # This is NOT the unbindable-root failure --underlay fixes; it is a missing
    # bind source, and it appears only under the complete flag set, which is why
    # a minimal `bwrap --ro-bind / / /bin/true` probe passes without it.
    #
    # The two are not alternatives, so do not drop one on the strength of the
    # other. Removing --underlay while keeping this bind reproduces the original
    # failure unchanged: bwrap dies at its very first bind and never reaches /dev
    # at all. Both are required, and they fail at different stages.
    #
    # It is kept here rather than in lc_build_binds deliberately. That array is
    # the host-data exposure surface -- the paths this session can see of the
    # user's filesystem -- and tests/test-binds.sh asserts its exact size so that
    # statement stays true. /dev/full is a character device, not a path into any
    # filesystem, and it exists only because of the --containall directly above.
    #
    # KNOWN EXPIRY: Apptainer has deprecated --underlay and will remove it. The
    # deprecation warning it prints into the session log on every launch is
    # expected, not a fault. When an upgrade drops the flag BOTH agents lose their
    # sandbox -- Codex stops starting at all, because its policy file requires the
    # helper, and Claude Code begins refusing Bash tool calls.
    # tests/test-containment.sh asserts the flag so that fails loudly here instead.
    "${LC_STERILE[@]}" "$bin" exec \
        --underlay \
        --containall \
        --cleanenv \
        --no-mount home,cwd,tmp,hostfs,bind-paths \
        --home "${HOME}:${HOME}" \
        --env-file "$env_file" \
        -B /dev/full:/dev/full \
        "${LC_BINDS[@]}" \
        "$image" "$@"
}
