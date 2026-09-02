#!/usr/bin/env bash
# The administrator's entry point for provisioning one course's Python
# environment. Submits the job; scripts/provision-course-env.sh is what runs.
#
#   submit-provision-course-env.sh --course <name> --canvas-id <id> \
#       --image <imagefile> \
#       [--rebuild] [--dry-run] [--environment-root <path>]
#
# Initial provisioning cannot use the normal OOD launch path: by definition,
# <environment_root>/default and its Python interpreter do not exist yet.
# Provisioning the environment is also compute work -- a solver run for an
# environment this size is not login-node work -- so this wrapper only
# validates and submits; it never provisions anything itself. `sbatch --wait`
# is what lets it return the job's real result: without --wait the
# administrator gets a job id and an apparent success for a job that may
# fail ten minutes later with nobody watching.
#
# REQUIRES `jq` (it reads the rendered sub-apps in step 4's agreement check).
# `ruby` is optional here -- without it the agreement check is skipped with a
# warning -- but without jq that check fails rather than being skipped.
set -uo pipefail

this_script="scripts/submit-provision-course-env.sh"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
LAUNCH_COMMON="${REPO_ROOT}/ood/lib/launch-common.sh"
# Guarded explicitly, the same way scripts/provision-course-env.sh guards it:
# without this, a missing file falls through into "command not found" errors
# (lc_log inside fail() itself doesn't exist yet) before exiting 1 as a side
# effect rather than a decision.
if [ ! -r "$LAUNCH_COMMON" ]; then
    echo "ERROR: ${this_script}: cannot read shared library '${LAUNCH_COMMON}'" >&2
    exit 1
fi
# shellcheck source=../ood/lib/launch-common.sh
. "$LAUNCH_COMMON"

fail() {
    lc_log "ERROR: $1"
    exit 1
}

usage() {
    cat >&2 <<EOF
usage: $0 --course <name> --canvas-id <id> --image <imagefile> [--rebuild] [--dry-run] [--environment-root <path>]
EOF
    exit 64
}

COURSE=""
CANVAS_ID=""
IMAGE_FILE=""
REBUILD=0
DRY_RUN=0
ENV_ROOT_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --course)
            [ $# -ge 2 ] || usage
            COURSE="$2"
            shift 2
            ;;
        --canvas-id)
            [ $# -ge 2 ] || usage
            CANVAS_ID="$2"
            shift 2
            ;;
        --image)
            [ $# -ge 2 ] || usage
            IMAGE_FILE="$2"
            shift 2
            ;;
        --environment-root)
            [ $# -ge 2 ] || usage
            ENV_ROOT_OVERRIDE="$2"
            shift 2
            ;;
        --rebuild)
            REBUILD=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        *)
            echo "ERROR: unknown flag: $1" >&2
            usage
            ;;
    esac
done

[ -n "$COURSE" ] && [ -n "$CANVAS_ID" ] && [ -n "$IMAGE_FILE" ] || usage

# --- Step 2: the course specification directory must exist -----------------
SPEC_DIR="${REPO_ROOT}/envs/${COURSE}"
[ -d "$SPEC_DIR" ] \
    || fail "no course specification directory for '${COURSE}' at '${SPEC_DIR}'"

# --- Step 3: derive the course folder and environment root, by the same ----
# convention the sub-apps use. Overridable ONLY for the root prefix, the same
# way the launch path's image roots and scratch root are overridable, so the
# test suite never has to touch a real /shared mount.
COURSE_SHARED_ROOT="${OOD_APPTAINER_COURSE_SHARED_ROOT:-/shared/courseSharedFolders}"
COURSE_FOLDER="${COURSE_SHARED_ROOT}/${CANVAS_ID}outer/${CANVAS_ID}"
if [ -n "$ENV_ROOT_OVERRIDE" ]; then
    ENV_ROOT="$ENV_ROOT_OVERRIDE"
else
    ENV_ROOT="${COURSE_FOLDER}/envs"
fi

lc_log "course_folder=${COURSE_FOLDER}"
lc_log "environment_root=${ENV_ROOT}"
printf 'course_folder=%s\n' "$COURSE_FOLDER"
printf 'environment_root=%s\n' "$ENV_ROOT"

[ -d "$COURSE_FOLDER" ] \
    || fail "course folder '${COURSE_FOLDER}' does not exist"
[ -w "$COURSE_FOLDER" ] \
    || fail "course folder '${COURSE_FOLDER}' is not writable"

# --- Step 4: cross-check both apps' rendered sub-apps against what was -----
# derived above. A silent disagreement here provisions one path while
# sessions launch against another. Skipped (with a warning) when Ruby is
# unavailable, and when the administrator explicitly overrode the
# environment root -- an explicit override is a deliberate deviation from the
# sub-apps' declared value, not a mistake to flag.
RENDER_RB="${REPO_ROOT}/tests/render.rb"
if [ -n "$ENV_ROOT_OVERRIDE" ]; then
    lc_log "WARNING: --environment-root override given; skipping the sub-app agreement check"
elif ! command -v ruby >/dev/null 2>&1; then
    lc_log "WARNING: ruby not found; skipping the sub-app agreement check"
else
    for app_dir in jupyterlab-ai codeserver-ai; do
        subapp="${REPO_ROOT}/ood/${app_dir}/local/${COURSE}.yml.erb"
        if [ ! -f "$subapp" ]; then
            lc_log "WARNING: no sub-app at '${subapp}'; skipping its agreement check"
            continue
        fi

        rendered=$(ruby "$RENDER_RB" --form "$subapp" 2>&1) \
            || fail "sub-app '${subapp}' failed to render: ${rendered}"

        rendered_folder=$(printf '%s' "$rendered" | jq -r '.attributes.course_folder // empty')
        rendered_env_root=$(printf '%s' "$rendered" | jq -r '.attributes.environment_root // empty')

        # An EMPTY environment_root is not a disagreement about a path: it is
        # the sub-app declaring that this course wants no course-shared
        # environment at all. Provisioning one would build a prefix no session
        # ever looks at, so say what is actually wrong instead of printing two
        # paths that differ.
        if [ -z "$rendered_env_root" ]; then
            fail "sub-app '${subapp}' declares no environment_root, so this course runs on its image alone. Set environment_root in the sub-app first, or pass --environment-root to provision one deliberately anyway."
        fi

        if [ "$rendered_folder" != "$COURSE_FOLDER" ] || [ "$rendered_env_root" != "$ENV_ROOT" ]; then
            fail "sub-app '${subapp}' declares course_folder='${rendered_folder}' environment_root='${rendered_env_root}', which disagrees with the derived course_folder='${COURSE_FOLDER}' environment_root='${ENV_ROOT}'"
        fi
    done
fi

# --- Step 5: resolve the deployed image, through the same two roots the ----
# launcher uses.
IMAGE_PATH=$(lc_select_image "$IMAGE_FILE") \
    || fail "could not resolve image '${IMAGE_FILE}'"
[ -r "$IMAGE_PATH" ] \
    || fail "resolved image '${IMAGE_PATH}' is not readable"

# --- Step 6: generate the batch script --------------------------------------
# Provisioning scratch: its own subtree of the same scratch root the launch
# path uses, so nothing here competes with a live session's cache.
SCRATCH_ROOT="${OOD_APPTAINER_SCRATCH_ROOT:-/scratch/$(id -nu)/ood/apptainer}"
PROVISION_SCRATCH="${SCRATCH_ROOT}/provisioning/${COURSE}"
SLURM_LOG="${PROVISION_SCRATCH}/provision.log"

REBUILD_FLAG=""
[ "$REBUILD" -eq 1 ] && REBUILD_FLAG=" --rebuild"

JOB_SCRIPT_CONTENT=$(cat <<EOF
#!/usr/bin/env bash
# Generated by ${this_script}. Runs on a compute node; binds ONLY the course
# folder, the provisioning scratch directory, and this repository (read-only)
# -- no home bind, because provisioning has no reason to touch it.
set -uo pipefail

# shellcheck source=../ood/lib/launch-common.sh
. "${REPO_ROOT}/ood/lib/launch-common.sh"

# Spack is sourced only to LOCATE Apptainer; the resolved path is then
# invoked directly, so nothing downstream depends on an activated Spack
# environment.
APPTAINER_BIN=\$(lc_apptainer_bin) || exit 1
echo "apptainer=\${APPTAINER_BIN}"

lc_sterile_prefix

"\${LC_STERILE[@]}" "\${APPTAINER_BIN}" exec \\
    --containall \\
    --cleanenv \\
    --no-mount home,cwd,tmp,hostfs,bind-paths \\
    -B "${COURSE_FOLDER}:${COURSE_FOLDER}" \\
    -B "${PROVISION_SCRATCH}:${PROVISION_SCRATCH}" \\
    -B "${REPO_ROOT}:${REPO_ROOT}:ro" \\
    "${IMAGE_PATH}" \\
    bash "${REPO_ROOT}/scripts/provision-course-env.sh" \\
        --spec "${SPEC_DIR}" \\
        --environment-root "${ENV_ROOT}" \\
        --course-folder "${COURSE_FOLDER}" \\
        --scratch "${PROVISION_SCRATCH}"${REBUILD_FLAG}
status=\$?
echo "provision-course-env.sh exited with status \${status}"
exit "\${status}"
EOF
)

# --- Step 7: --dry-run prints the job script and exits, without submitting -
if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "$JOB_SCRIPT_CONTENT"
    exit 0
fi

mkdir -p "$PROVISION_SCRATCH" \
    || fail "cannot create provisioning scratch directory '${PROVISION_SCRATCH}'"

JOB_SCRIPT_FILE=$(mktemp "${PROVISION_SCRATCH}/provision-XXXXXX.sh") \
    || fail "cannot create a temporary job script under '${PROVISION_SCRATCH}'"
trap 'rm -f "$JOB_SCRIPT_FILE"' EXIT
printf '%s\n' "$JOB_SCRIPT_CONTENT" > "$JOB_SCRIPT_FILE"
chmod 755 "$JOB_SCRIPT_FILE"

# --- Step 8: submit ONE job, wait for it, and report its real result --------
lc_log "submitting provisioning job for course '${COURSE}' (Slurm log: ${SLURM_LOG})"
sbatch --wait \
    --job-name="provision-course-env-${COURSE}" \
    --output="$SLURM_LOG" \
    "$JOB_SCRIPT_FILE"
status=$?

if [ "$status" -ne 0 ]; then
    lc_log "ERROR: provisioning job for course '${COURSE}' failed (exit ${status}); see Slurm log at ${SLURM_LOG}"
else
    lc_log "provisioning job for course '${COURSE}' succeeded"
fi

exit "$status"
