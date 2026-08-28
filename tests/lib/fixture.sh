# shellcheck shell=bash
# Builds a fake host filesystem layout and a stub Apptainer image.
#
# The image is a sandbox directory when /dev/fuse is unavailable (the dev
# sandbox) and a .sif otherwise (a cluster node). apptainer exec accepts both,
# so no test needs to know which it got.

FIXTURE_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_CACHE="$FIXTURE_TESTS_DIR/.cache"

fixture_create() {
    FIXTURE_ROOT=$(mktemp -d)
    export FIXTURE_ROOT

    export FAKE_HOME="$FIXTURE_ROOT/shared/home/tester"
    export FAKE_COURSE_ROOT="$FIXTURE_ROOT/shared/courseSharedFolders/170681outer/170681"
    export FAKE_ENV_ROOT="$FAKE_COURSE_ROOT/envs"
    export FAKE_SCRATCH="$FIXTURE_ROOT/scratch/tester/ood/jupyter-codeserver-ai"
    export FAKE_JOB_STATE="$FAKE_SCRATCH/jobs/42/state"
    export FAKE_JOB_TMP="$FAKE_SCRATCH/jobs/42/tmp"
    export FAKE_SSH_MASK="$FAKE_JOB_STATE/ssh-mask"
    export FAKE_SECRET_DIR="$FIXTURE_ROOT/secret"
    export FAKE_IMAGE_ROOT_FAST="$FIXTURE_ROOT/scratch/apptainerImages"
    export FAKE_IMAGE_ROOT_CANONICAL="$FIXTURE_ROOT/shared/apptainerImages"

    mkdir -p "$FAKE_HOME/.ssh" "$FAKE_COURSE_ROOT" \
             "$FAKE_ENV_ROOT/default/bin" "$FAKE_ENV_ROOT/staging/bin" \
             "$FAKE_JOB_STATE" "$FAKE_JOB_TMP" "$FAKE_SSH_MASK" \
             "$FAKE_SCRATCH/cache" "$FAKE_SCRATCH/workspaces" \
             "$FAKE_SECRET_DIR" \
             "$FAKE_IMAGE_ROOT_FAST" "$FAKE_IMAGE_ROOT_CANONICAL"

    # A course python that is executable, reports a version, and succeeds at
    # `-c`, so both the interpreter check and the in-container import probe have
    # something real to find. Without the `-c` arm this stub would print the
    # version banner in response to a probe -- passing it by accident, and
    # making the "broken environment" tests unable to fail.
    for variant in default staging; do
        cat > "$FAKE_ENV_ROOT/$variant/bin/python" <<'PY'
#!/bin/sh
case "$1" in
    -c) exit 0 ;;
esac
echo "Python 3.13.0"
PY
        chmod 755 "$FAKE_ENV_ROOT/$variant/bin/python"
    done

    echo "SECRET-CONTENT-MUST-NOT-BE-VISIBLE" > "$FAKE_SECRET_DIR/leaky.txt"
    echo "course-marker" > "$FAKE_COURSE_ROOT/marker.txt"
    echo "id_rsa-must-be-masked" > "$FAKE_HOME/.ssh/id_rsa"
}

fixture_destroy() {
    [ -n "${FIXTURE_ROOT:-}" ] && rm -rf "$FIXTURE_ROOT"
}

# Leaves the interpreter in place but makes it fail, which is the shape of a
# course environment broken by a failed staff update: the file is there, the
# launcher's -x test passes, and only running it reveals the problem.
fixture_break_course_python() {
    cat > "$FAKE_ENV_ROOT/default/bin/python" <<'PY'
#!/bin/sh
echo "ImportError: broken course environment" >&2
exit 1
PY
    chmod 755 "$FAKE_ENV_ROOT/default/bin/python"
}

# The unprovisioned case: nothing at <environment_root>/default at all.
fixture_remove_course_env() {
    rm -rf "$FAKE_ENV_ROOT/default"
}

# Builds the stub image once and caches it. Echoes a path for apptainer exec.
fixture_image() {
    local def="$FIXTURE_TESTS_DIR/fixtures/stub.def"
    local target

    # A .sif can only be mounted where /dev/fuse is usable. Where it is not
    # (the dev sandbox), build a sandbox directory instead; apptainer exec
    # accepts either, so no caller needs to know which it got.
    if [ -e /dev/fuse ]; then
        target="$FIXTURE_CACHE/stub.sif"
    else
        target="$FIXTURE_CACHE/stub.dir"
    fi

    mkdir -p "$FIXTURE_CACHE"

    if [ ! -e "$target" ] || [ "$def" -nt "$target" ]; then
        rm -rf "$target"
        # Build to /tmp to work around xattr issues on bind mounts
        local tmpbuild="/tmp/stub-build-$$"
        local build_out build_err
        case "$target" in
            *.sif)
                build_out=$("${OOD_AI_APPTAINER_BIN:-apptainer}" build --fakeroot "$tmpbuild.sif" "$def" 2>&1) || {
                    printf 'fixture_image: apptainer build failed: %s\n' "$build_out" >&2
                    rm -rf "$tmpbuild.sif"
                    return 1
                }
                mv "$tmpbuild.sif" "$target" || {
                    build_err=$?
                    printf 'fixture_image: mv %s to %s failed: %s\n' "$tmpbuild.sif" "$target" "$build_err" >&2
                    rm -rf "$tmpbuild.sif"
                    return "$build_err"
                }
                ;;
            *)
                build_out=$("${OOD_AI_APPTAINER_BIN:-apptainer}" build --fakeroot --sandbox "$tmpbuild.dir" "$def" 2>&1) || {
                    printf 'fixture_image: apptainer build failed: %s\n' "$build_out" >&2
                    rm -rf "$tmpbuild.dir"
                    return 1
                }
                mv "$tmpbuild.dir" "$target" || {
                    build_err=$?
                    printf 'fixture_image: mv %s to %s failed: %s\n' "$tmpbuild.dir" "$target" "$build_err" >&2
                    rm -rf "$tmpbuild.dir"
                    return "$build_err"
                }
                ;;
        esac
    fi

    # Place a copy under the fake canonical image root so image-selection tests
    # have a realistic layout to resolve against.
    if [ -n "${FAKE_IMAGE_ROOT_CANONICAL:-}" ] && [ ! -e "$FAKE_IMAGE_ROOT_CANONICAL/stub" ]; then
        cp -a "$target" "$FAKE_IMAGE_ROOT_CANONICAL/stub"
    fi

    export OOD_AI_TEST_IMAGE="$target"
    printf '%s\n' "$target"
}
