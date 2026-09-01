#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
REAL_HOME="$HOME"
BIN="$ROOT/bin"; mkdir -p "$BIN"

# Stub managers. They record argv and build a prefix that looks provisioned, so
# the validation half of the script runs against something real.
cat > "$BIN/micromamba" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >> "$STUB_LOG"
printf 'HOME=%s\n' "${HOME:-<unset>}" >> "$STUB_LOG.env"
for a in "$@"; do case "$a" in --prefix=*) P=${a#--prefix=};; esac; done
[ -n "${P:-}" ] || { i=1; for a in "$@"; do [ "$a" = --prefix ] && P=$(eval echo \"\$$((i+1))\"); i=$((i+1)); done; }
mkdir -p "$P/bin"
printf '#!/bin/sh\ncase "$1" in -c) exit 0;; esac\necho "Python 3.13.0"\n' > "$P/bin/python"
chmod 755 "$P/bin/python"
STUB
chmod 755 "$BIN/micromamba"
cp "$BIN/micromamba" "$BIN/uv"
export PATH="$BIN:$PATH"

setup() {   # fresh course folder + spec, echoes the environment root
    rm -rf "$ROOT/course" "$ROOT/spec" "$ROOT/scratch"
    mkdir -p "$ROOT/course/envs" "$ROOT/spec" "$ROOT/scratch"
    printf 'micromamba\n' > "$ROOT/spec/manager"
    printf '3.13\n'       > "$ROOT/spec/python-version"
    printf 'name: t\nchannels:\n  - conda-forge\ndependencies:\n  - python=3.13\n  - ipykernel\n' \
        > "$ROOT/spec/environment.yml"
    printf '%s\n' "$ROOT/course/envs"
}

provision() {
    STUB_LOG="$ROOT/stub.log" scripts/provision-course-env.sh \
        --spec "$ROOT/spec" --environment-root "$1" \
        --course-folder "$ROOT/course" --scratch "$ROOT/scratch" "${@:2}" 2>&1
}

it "provision-course-env.sh exists and is executable"
assert_success test -x scripts/provision-course-env.sh

ENVROOT=$(setup)
: > "$ROOT/stub.log"
OUT=$(provision "$ENVROOT"); STATUS=$?

it "a clean provisioning run succeeds"
# shellcheck disable=SC2015  # not if/then/else, but _pass and _fail can't fail
[ "$STATUS" -eq 0 ] && _pass || _fail "$OUT"

it "it creates the prefix at its FINAL absolute path"
# Environment prefixes embed absolute paths in scripts and metadata, so they
# must be built where they will be used, never built elsewhere and moved.
assert_contains "$(cat "$ROOT/stub.log")" "$ENVROOT/default"

it "it produces a usable interpreter"
assert_success test -x "$ENVROOT/default/bin/python"

it "it records the manager beside the prefixes, where staff will look"
assert_eq "$(tr -d '[:space:]' < "$ENVROOT/manager")" "micromamba"

it "it records the source file beside the prefixes"
assert_success test -f "$ENVROOT/environment.yml"

it "it writes no documentation into the course folder"
# The course folder is readable by every student on the course. Provisioning
# records the manager and the source spec beside the prefixes, and nothing
# else: prose for staff lives in docs/, in this repository.
assert_failure test -f "$ENVROOT/README.md"

it "manager caches go to provisioning scratch, not the course folder"
assert_failure test -d "$ENVROOT/.mamba"

it "the manager runs with HOME redirected under scratch"
# Not redundant with the cache variables. The provisioning container binds no
# home, so an inherited HOME names a path that does not exist; micromamba writes
# there anyway -- the sharded-repodata index and the environment registry -- and
# dies with "cannot create directories: Read-only file system". Assert on the
# HOME the manager actually saw, not on the export, so the redirect is checked
# where it has to hold.
assert_contains "$(cat "$ROOT/stub.log.env")" "HOME=$ROOT/scratch/home"

it "the manager does NOT inherit the invoking user's home"
# The consequence, stated separately: the value above must not be the real HOME,
# which is what an unset or unexported redirect would leave behind.
assert_not_contains "$(cat "$ROOT/stub.log.env")" "HOME=$REAL_HOME"

it "it refuses to overwrite an existing default"
OUT=$(provision "$ENVROOT")
assert_contains "$OUT" "already exists"

it "--rebuild is the documented way past that refusal"
assert_success provision "$ENVROOT" --rebuild

it "it rejects an unknown manager"
ENVROOT=$(setup); printf 'conda\n' > "$ROOT/spec/manager"
assert_contains "$(provision "$ENVROOT")" "manager"

it "the unsupported-manager rejection specifically names the bad value"
# The assertion above also matches an unrelated downstream message (step 4's
# "manager is uv but no pyproject.toml..." also contains the word "manager"),
# so on its own it would still pass if the manager whitelist were broken open
# to accept anything. This pins the rejection to the actual bad value.
assert_contains "$(provision "$ENVROOT")" "conda"

it "it rejects source files that do not match the manager"
ENVROOT=$(setup); printf 'uv\n' > "$ROOT/spec/manager"
assert_contains "$(provision "$ENVROOT")" "pyproject.toml"

it "it rejects an environment root outside the course folder"
ENVROOT=$(setup)
assert_contains "$(provision "$ROOT/elsewhere")" "course folder"

it "it rejects an environment root that escapes by symlink"
ENVROOT=$(setup); mkdir -p "$ROOT/outside"
ln -sfn "$ROOT/outside" "$ROOT/course/sneaky"
assert_contains "$(provision "$ROOT/course/sneaky")" "escapes"

it "it fails loudly, once, when the shared launch library is missing"
# Copies the script into an isolated fake repo with no ood/lib/launch-common.sh
# beside it. Without the guard, sourcing a missing file falls through into two
# more "command not found" errors (lc_validate_under, then lc_log inside
# fail()) before exiting 1 as a side effect rather than a decision.
FAKEREPO="$ROOT/fakerepo"
rm -rf "$FAKEREPO"
mkdir -p "$FAKEREPO/scripts"
cp scripts/provision-course-env.sh "$FAKEREPO/scripts/provision-course-env.sh"
chmod 755 "$FAKEREPO/scripts/provision-course-env.sh"
ENVROOT=$(setup)
MISSING_LIB_OUT=$("$FAKEREPO/scripts/provision-course-env.sh" \
    --spec "$ROOT/spec" --environment-root "$ENVROOT" \
    --course-folder "$ROOT/course" --scratch "$ROOT/scratch" 2>&1)
assert_contains "$MISSING_LIB_OUT" "launch-common.sh"

it "the missing-library failure doesn't cascade into command-not-found noise"
assert_not_contains "$MISSING_LIB_OUT" "command not found"

it "a failed validation leaves NO staff records behind"
# Records are the signal that a prefix is usable. Writing them for a prefix that
# failed validation is worse than writing nothing.
ENVROOT=$(setup)
cat > "$BIN/micromamba" <<'STUB'
#!/bin/sh
exit 3
STUB
chmod 755 "$BIN/micromamba"
provision "$ENVROOT" >/dev/null 2>&1
assert_failure test -f "$ENVROOT/manager"

# ---------------------------------------------------------------------------
# Additions beyond the brief's given suite. The numbered structure in the
# brief mandates several behaviors the assertions above never exercise:
#   - rejecting a spec that carries BOTH managers' source files (step 4's
#     second sentence: "reject the other manager's files being present")
#   - the representative-import check actually running a distinct probe from
#     the ipykernel check (step 8)
#   - the permission-model validation (step 9) actually failing a prefix
#   - manager caches actually landing under --scratch (the given "manager
#     caches go to scratch" check only proves the course folder stays clean,
#     which would also be true if scratch were never used at all)
#   - a full uv provisioning run (step 7's uv branch, and step 10's uv-only
#     pyproject.toml/uv.lock copy), never exercised by the given suite
# Restore the good generic stub first; the previous test left micromamba
# broken on purpose.
cat > "$BIN/micromamba" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >> "$STUB_LOG"
for a in "$@"; do case "$a" in --prefix=*) P=${a#--prefix=};; esac; done
[ -n "${P:-}" ] || { i=1; for a in "$@"; do [ "$a" = --prefix ] && P=$(eval echo \"\$$((i+1))\"); i=$((i+1)); done; }
mkdir -p "$P/bin"
printf '#!/bin/sh\ncase "$1" in -c) exit 0;; esac\necho "Python 3.13.0"\n' > "$P/bin/python"
chmod 755 "$P/bin/python"
STUB
chmod 755 "$BIN/micromamba"

it "it rejects a spec directory carrying both managers' source files (declared micromamba)"
ENVROOT=$(setup)
: > "$ROOT/spec/pyproject.toml"
assert_contains "$(provision "$ENVROOT")" "ambiguous"

it "it rejects a spec directory carrying both managers' source files (declared uv)"
# The micromamba-declared case above only exercises one of the two symmetric
# branches; a spec can just as easily be uv-declared with a stray
# environment.yml left behind, and that branch has its own ambiguity check.
ENVROOT=$(setup)
printf 'uv\n' > "$ROOT/spec/manager"
: > "$ROOT/spec/pyproject.toml"
assert_contains "$(provision "$ENVROOT")" "ambiguous"

it "it rejects a prefix whose representative import fails"
# A stub that actually distinguishes ipykernel (must pass) from a real course
# package (must fail), so this proves the representative-import check is a
# real, separate probe -- not a restatement of the ipykernel check.
ENVROOT=$(setup)
printf 'name: t\nchannels:\n  - conda-forge\ndependencies:\n  - python=3.13\n  - ipykernel\n  - numpy\n' \
    > "$ROOT/spec/environment.yml"
cat > "$BIN/micromamba" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >> "$STUB_LOG"
for a in "$@"; do case "$a" in --prefix=*) P=${a#--prefix=};; esac; done
[ -n "${P:-}" ] || { i=1; for a in "$@"; do [ "$a" = --prefix ] && P=$(eval echo \"\$$((i+1))\"); i=$((i+1)); done; }
mkdir -p "$P/bin"
cat > "$P/bin/python" <<'PY'
#!/bin/sh
if [ "$1" = "-c" ]; then
    case "$2" in
        *numpy*) exit 1 ;;
        *) exit 0 ;;
    esac
fi
echo "Python 3.13.0"
PY
chmod 755 "$P/bin/python"
STUB
chmod 755 "$BIN/micromamba"
OUT=$(provision "$ENVROOT")
assert_contains "$OUT" "numpy"

it "a failed representative-import check leaves no staff records either"
assert_failure test -f "$ENVROOT/manager"

it "it rejects a prefix whose interpreter reports the wrong Python version"
# Step 8 requires that `python -V` reports the CONFIGURED version, not merely
# that the interpreter runs at all. A stub that reports a version other than
# the spec's python-version proves this is a real, distinct check.
ENVROOT=$(setup)
cat > "$BIN/micromamba" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >> "$STUB_LOG"
for a in "$@"; do case "$a" in --prefix=*) P=${a#--prefix=};; esac; done
[ -n "${P:-}" ] || { i=1; for a in "$@"; do [ "$a" = --prefix ] && P=$(eval echo \"\$$((i+1))\"); i=$((i+1)); done; }
mkdir -p "$P/bin"
printf '#!/bin/sh\ncase "$1" in -c) exit 0;; esac\necho "Python 3.11.0"\n' > "$P/bin/python"
chmod 755 "$P/bin/python"
STUB
chmod 755 "$BIN/micromamba"
OUT=$(provision "$ENVROOT")
assert_contains "$OUT" "3.11.0"

it "a Python-version mismatch leaves no staff records"
assert_failure test -f "$ENVROOT/manager"

it "it rejects a prefix with a directory that is not traversable by others"
# Restore the plain-import-succeeds stub and instead break the permission
# model, so this test isolates step 9 from step 8.
ENVROOT=$(setup)
cat > "$BIN/micromamba" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >> "$STUB_LOG"
for a in "$@"; do case "$a" in --prefix=*) P=${a#--prefix=};; esac; done
[ -n "${P:-}" ] || { i=1; for a in "$@"; do [ "$a" = --prefix ] && P=$(eval echo \"\$$((i+1))\"); i=$((i+1)); done; }
mkdir -p "$P/bin" "$P/share/private"
printf '#!/bin/sh\ncase "$1" in -c) exit 0;; esac\necho "Python 3.13.0"\n' > "$P/bin/python"
chmod 755 "$P/bin/python"
chmod 700 "$P/share/private"
STUB
chmod 755 "$BIN/micromamba"
OUT=$(provision "$ENVROOT")
assert_contains "$OUT" "share/private"

it "a permission-validation failure leaves no staff records"
assert_failure test -f "$ENVROOT/manager"

# Restore the good generic stub again for the remaining tests.
cat > "$BIN/micromamba" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >> "$STUB_LOG"
for a in "$@"; do case "$a" in --prefix=*) P=${a#--prefix=};; esac; done
[ -n "${P:-}" ] || { i=1; for a in "$@"; do [ "$a" = --prefix ] && P=$(eval echo \"\$$((i+1))\"); i=$((i+1)); done; }
mkdir -p "$P/bin"
printf '#!/bin/sh\ncase "$1" in -c) exit 0;; esac\necho "Python 3.13.0"\n' > "$P/bin/python"
chmod 755 "$P/bin/python"
STUB
chmod 755 "$BIN/micromamba"

it "manager caches are actually created under the scratch directory, not just absent from the course folder"
ENVROOT=$(setup)
: > "$ROOT/stub.log"
provision "$ENVROOT" >/dev/null 2>&1
FOUND_CACHE_DIR=0
for d in "$ROOT/scratch"/*/; do [ -d "$d" ] && FOUND_CACHE_DIR=1; done
# shellcheck disable=SC2015  # not if/then/else, but _pass and _fail can't fail
[ "$FOUND_CACHE_DIR" -eq 1 ] && _pass || _fail "no cache directory was created under $ROOT/scratch"

ENVROOT=$(setup)
OUT=$(provision "$ENVROOT")

it "it prints the resolved prefix"
assert_contains "$OUT" "prefix=$ENVROOT/default"

it "it prints the manager"
assert_contains "$OUT" "manager=micromamba"

it "it prints the validated python version"
assert_contains "$OUT" "python_version=3.13.0"

it "it rejects an unknown flag"
assert_contains "$(scripts/provision-course-env.sh --nope 2>&1)" "usage"

it "it requires all four mandatory flags"
assert_contains "$(scripts/provision-course-env.sh --spec "$ROOT/spec" 2>&1)" "usage"

# --- A full uv provisioning run --------------------------------------------
# uv's own venv-creation env vars (UV_PROJECT_ENVIRONMENT, UV_PYTHON_INSTALL_DIR)
# never appear in argv, so the generic micromamba-shaped stub above (which only
# parses --prefix out of argv) cannot exercise this path at all -- it would
# silently mkdir -p "/bin" and lie. This stub honors the real env vars uv uses.
setup_uv() {
    rm -rf "$ROOT/course-uv" "$ROOT/spec-uv" "$ROOT/scratch-uv"
    mkdir -p "$ROOT/course-uv/envs" "$ROOT/spec-uv" "$ROOT/scratch-uv"
    printf 'uv\n' > "$ROOT/spec-uv/manager"
    printf '3.13\n' > "$ROOT/spec-uv/python-version"
    cat > "$ROOT/spec-uv/pyproject.toml" <<'EOF'
[project]
name = "t"
requires-python = ">=3.13"
dependencies = ["ipykernel"]
EOF
    printf 'lockfile-marker\n' > "$ROOT/spec-uv/uv.lock"
    printf '%s\n' "$ROOT/course-uv/envs"
}

cat > "$BIN/uv" <<'STUB'
#!/bin/sh
printf 'ARGV %s\n' "$*" >> "$STUB_LOG"
printf 'ENV UV_PYTHON_INSTALL_DIR=%s UV_PROJECT_ENVIRONMENT=%s\n' \
    "${UV_PYTHON_INSTALL_DIR:-}" "${UV_PROJECT_ENVIRONMENT:-}" >> "$STUB_LOG"
cmd="$1"
case "$cmd" in
    python)
        sub="$2"; ver="$3"
        case "$sub" in
            install)
                mkdir -p "$UV_PYTHON_INSTALL_DIR/cpython-$ver/bin"
                printf '#!/bin/sh\ncase "$1" in -c) exit 0;; esac\necho "Python 3.13.0"\n' \
                    > "$UV_PYTHON_INSTALL_DIR/cpython-$ver/bin/python3"
                chmod 755 "$UV_PYTHON_INSTALL_DIR/cpython-$ver/bin/python3"
                ;;
            find)
                echo "$UV_PYTHON_INSTALL_DIR/cpython-$ver/bin/python3"
                ;;
        esac
        ;;
    sync)
        mkdir -p "$UV_PROJECT_ENVIRONMENT/bin"
        printf '#!/bin/sh\ncase "$1" in -c) exit 0;; esac\necho "Python 3.13.0"\n' \
            > "$UV_PROJECT_ENVIRONMENT/bin/python"
        chmod 755 "$UV_PROJECT_ENVIRONMENT/bin/python"
        ;;
esac
exit 0
STUB
chmod 755 "$BIN/uv"

ENVROOT=$(setup_uv)
: > "$ROOT/stub.log"
OUT=$(STUB_LOG="$ROOT/stub.log" scripts/provision-course-env.sh \
    --spec "$ROOT/spec-uv" --environment-root "$ENVROOT" \
    --course-folder "$ROOT/course-uv" --scratch "$ROOT/scratch-uv" 2>&1)
STATUS=$?

it "a clean uv provisioning run succeeds"
# shellcheck disable=SC2015  # not if/then/else, but _pass and _fail can't fail
[ "$STATUS" -eq 0 ] && _pass || _fail "$OUT"

it "uv: it creates the prefix at its final absolute path"
assert_contains "$(cat "$ROOT/stub.log")" "UV_PROJECT_ENVIRONMENT=$ENVROOT/default"

it "uv: it installs the base interpreter beneath the environment root, self-contained under either manager"
assert_contains "$(cat "$ROOT/stub.log")" "UV_PYTHON_INSTALL_DIR=$ENVROOT/python"

it "uv: it produces a usable interpreter"
assert_success test -x "$ENVROOT/default/bin/python"

it "uv: it records the manager beside the prefixes"
assert_eq "$(tr -d '[:space:]' < "$ENVROOT/manager")" "uv"

it "uv: it copies pyproject.toml beside the prefixes"
assert_success test -f "$ENVROOT/pyproject.toml"

it "uv: it copies uv.lock beside the prefixes"
assert_success test -f "$ENVROOT/uv.lock"

it "uv: it writes no documentation into the course folder"
assert_failure test -f "$ENVROOT/README.md"

it "cs1090a's otter-grader ceiling is recorded beside the pin it constrains"
# The constraint lives in the dependency file so that whoever edits the pin
# reads it. It is deliberately not shipped anywhere: the course folder is
# readable by every student on the course.
assert_contains "$(cat envs/cs1090a/environment.yml)" "consult ATG"

# ---------------------------------------------------------------------------
# scripts/submit-provision-course-env.sh: the admin wrapper that validates, submits ONE
# compute-node job, and reports that job's real result.
#
# It needs a stub `sbatch` (records its argv and the job script it was
# handed, exits with $SBATCH_EXIT) plus a fabricated /shared-shaped tree,
# because the wrapper cross-checks its derived paths against the REAL
# committed sub-apps (ood/*/local/<course>.yml.erb), and those hardcode the
# real /shared/courseSharedFolders convention. Rather than touch that real
# path (unwritable here, and not ours to touch even where it exists), a
# throwaway repo copy is built with am115's own sub-apps rewritten onto a
# writable fake root -- the same indirection tests/test-launch-e2e.sh and
# tests/lib/fixture.sh already use for "/shared/...". The convention
# STRUCTURE (<id>outer/<id>) is exercised for real; only the root prefix is
# fake.
# ---------------------------------------------------------------------------

it "submit-provision-course-env.sh exists and is executable"
assert_success test -x scripts/submit-provision-course-env.sh

BCE_REPO="$ROOT/bce-repo"
mkdir -p "$BCE_REPO/scripts" "$BCE_REPO/ood/lib" \
         "$BCE_REPO/ood/jupyterlab-ai/local" "$BCE_REPO/ood/codeserver-ai/local" \
         "$BCE_REPO/envs/am115" "$BCE_REPO/tests"
cp scripts/submit-provision-course-env.sh "$BCE_REPO/scripts/submit-provision-course-env.sh"
cp scripts/provision-course-env.sh "$BCE_REPO/scripts/provision-course-env.sh"
chmod 755 "$BCE_REPO/scripts/submit-provision-course-env.sh" "$BCE_REPO/scripts/provision-course-env.sh"
cp ood/lib/launch-common.sh "$BCE_REPO/ood/lib/launch-common.sh"
cp tests/render.rb "$BCE_REPO/tests/render.rb"
cp envs/am115/manager \
   envs/am115/python-version \
   envs/am115/environment.yml \
   "$BCE_REPO/envs/am115/"

# am115's REAL sub-apps, rewritten onto a writable fake course-shared root.
# Everything else about them -- title, access control, imagefile -- is
# untouched, so the agreement check below runs against a realistic sub-app,
# not a hand-built fixture that might not exercise the real template shape.
BCE_COURSE_ROOT="$ROOT/bce-shared/courseSharedFolders"
sed "s#/shared/courseSharedFolders#${BCE_COURSE_ROOT}#g" \
    ood/jupyterlab-ai/local/am115.yml.erb > "$BCE_REPO/ood/jupyterlab-ai/local/am115.yml.erb"
sed "s#/shared/courseSharedFolders#${BCE_COURSE_ROOT}#g" \
    ood/codeserver-ai/local/am115.yml.erb > "$BCE_REPO/ood/codeserver-ai/local/am115.yml.erb"

mkdir -p "$BCE_COURSE_ROOT/172566outer/172566"
mkdir -p "$ROOT/bce-images-canonical"
: > "$ROOT/bce-images-canonical/ok.sif"

SBATCH_ARGV_LOG="$ROOT/sbatch-argv.log"
SBATCH_JOB_SCRIPT_FILE="$ROOT/job-script.sh"
export SBATCH_ARGV_LOG SBATCH_JOB_SCRIPT_FILE
cat > "$BIN/sbatch" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >> "$SBATCH_ARGV_LOG"
for last; do :; done
cp "$last" "$SBATCH_JOB_SCRIPT_FILE"
exit "${SBATCH_EXIT:-0}"
STUB
chmod 755 "$BIN/sbatch"

export OOD_APPTAINER_COURSE_SHARED_ROOT="$BCE_COURSE_ROOT"
export OOD_APPTAINER_IMAGE_ROOT_FAST="$ROOT/bce-images-fast"
export OOD_APPTAINER_IMAGE_ROOT_CANONICAL="$ROOT/bce-images-canonical"
export OOD_APPTAINER_SCRATCH_ROOT="$ROOT/bce-scratch"

DERIVED_COURSE_FOLDER="${BCE_COURSE_ROOT}/172566outer/172566"

# build_course_env <args...>
#
# Runs the wrapper, echoing its combined stdout+stderr (so callers can use
# command substitution the normal way) and returning its real exit status.
# Also refreshes the global SBATCH_ARGV and JOB_SCRIPT from the stub's log
# files -- meaningful only for a call NOT wrapped in $(...), since a command
# substitution runs this function in a subshell and any plain variable
# assignment inside it is discarded when the subshell exits. Every test below
# that reads $SBATCH_ARGV or $JOB_SCRIPT calls build_course_env directly
# (never through $()) for exactly that reason.
build_course_env() {
    : > "$SBATCH_ARGV_LOG"
    : > "$SBATCH_JOB_SCRIPT_FILE"
    "$BCE_REPO/scripts/submit-provision-course-env.sh" "$@" 2>&1
    local status=$?
    SBATCH_ARGV=$(cat "$SBATCH_ARGV_LOG" 2>/dev/null || true)
    JOB_SCRIPT=$(cat "$SBATCH_JOB_SCRIPT_FILE" 2>/dev/null || true)
    return "$status"
}

build_course_env --course am115 --canvas-id 172566 --image ok.sif >/dev/null

it "submit-provision-course-env.sh submits ONE job and waits for it"
# --wait is what lets the wrapper return the build's real result. Without it
# the administrator gets a job id and a success message for a build that may
# fail ten minutes later with nobody watching.
assert_contains "$SBATCH_ARGV" "--wait"

it "it derives the course folder from the Canvas ID by the documented convention"
assert_contains "$JOB_SCRIPT" "$DERIVED_COURSE_FOLDER"

it "the job binds exactly three paths: course folder, scratch, and the repository"
# A substring check on one specific bind spelling (e.g. "-B \$HOME") would
# still pass for a HOME bind written with different quoting or variable
# syntax. Counting binds catches ANY extra bind, spelled any way.
BIND_COUNT=$(printf '%s\n' "$JOB_SCRIPT" | grep -c -- '-B ')
assert_eq "$BIND_COUNT" "3"

it "the job binds ONLY the course folder, scratch, and the repository -- no HOME reference at all"
# Independent of the count above: a script could bind exactly three paths and
# still have one of them be HOME (e.g. swapped in for the repo bind). This
# checks the whole generated script never mentions HOME, in any quoting or
# variable-syntax style -- \$HOME, \${HOME}, or an already-expanded literal
# path, none of which share a common substring with each other.
assert_not_contains "$JOB_SCRIPT" "HOME"

it "the job runs the image-owned provisioning helper, not the OOD launch path"
# A bare substring check on the filename would still pass if only a COMMENT
# mentioned provision-course-env.sh while the actual invocation line called
# something else -- this pins it to the real invocation, at its real path.
assert_contains "$JOB_SCRIPT" "bash \"${BCE_REPO}/scripts/provision-course-env.sh\""

it "the job's apptainer invocation names the resolved image"
assert_contains "$JOB_SCRIPT" "$ROOT/bce-images-canonical/ok.sif"

# --- The provisioning job's containment. This is the one path in the system
# that runs as an administrator with WRITE access to a course folder, and
# because it reimplements the Apptainer invocation inline rather than calling
# lc_run it inherits none of the launch path's containment coverage. Every
# flag below was individually deletable with this suite green.

it "the job's apptainer invocation carries --containall"
assert_contains "$JOB_SCRIPT" "--containall"

it "the job's apptainer invocation carries --cleanenv"
assert_contains "$JOB_SCRIPT" "--cleanenv"

it "the job suppresses Apptainer's own default mounts, in full"
# Asserted as the whole list, not as the flag name: dropping any single
# element of it -- hostfs and bind-paths especially -- reopens a host mount
# the launch path is careful to close, and a check for "--no-mount" alone
# would not notice.
assert_contains "$JOB_SCRIPT" "--no-mount home,cwd,tmp,hostfs,bind-paths"

it "the job invokes apptainer through the sterile env -i prefix"
# Two assertions because the prefix has two halves that fail independently:
# the call that populates LC_STERILE, and the expansion that actually uses it.
# Deleting either leaves the other looking correct.
assert_contains "$JOB_SCRIPT" "lc_sterile_prefix"

it "the job expands the sterile prefix at the apptainer call site"
assert_contains "$JOB_SCRIPT" "LC_STERILE[@]"

it "the job binds the course folder at its own path"
# The bind COUNT above catches an extra bind; only identity assertions catch a
# substituted one. Swapping the scratch bind for -B /tmp:/tmp, for instance,
# keeps the count at three.
assert_contains "$JOB_SCRIPT" "-B \"${DERIVED_COURSE_FOLDER}:${DERIVED_COURSE_FOLDER}\""

it "the job binds the provisioning scratch directory, and nothing else as scratch"
BCE_PROVISION_SCRATCH="$ROOT/bce-scratch/provisioning/am115"
assert_contains "$JOB_SCRIPT" "-B \"${BCE_PROVISION_SCRATCH}:${BCE_PROVISION_SCRATCH}\""

it "the job binds the repository READ-ONLY"
# :ro is what stops a provisioning run from writing to the deploy clone it was
# launched from. It is three characters at the end of a line and its loss is
# invisible in every other assertion here.
assert_contains "$JOB_SCRIPT" "-B \"${BCE_REPO}:${BCE_REPO}:ro\""

it "sbatch is told where to write the job's output"
# The failure message naming the log path is asserted below, and that message
# is a string: it stays correct-looking with the flag gone. Without the flag
# Slurm writes slurm-<jobid>.out into whatever directory the administrator
# submitted from, while the error message points at a path that does not
# exist -- discovered after a ten-minute solve.
assert_contains "$SBATCH_ARGV" "--output=$ROOT/bce-scratch/provisioning/am115/provision.log"

it "the job is named for the script that runs it, not for the submitter"
assert_contains "$SBATCH_ARGV" "--job-name=provision-course-env-am115"

it "it fails when the course specification directory is missing"
assert_contains "$(build_course_env --course nosuch --canvas-id 1 --image i.sif)" "nosuch"

it "it fails when the resolved image does not exist"
# Pinned to "not found" (lc_select_image's own diagnostic), distinct from the
# readability failure below -- a bare "image" substring would pass for either
# failure and catch neither specifically.
assert_contains "$(build_course_env --course am115 --canvas-id 172566 --image absent.sif)" "not found"

it "it fails when the resolved image exists but is not readable"
# Distinct from the nonexistent-file case above: this constructs a REAL file
# at the resolved path and strips read permission, so only the explicit
# `[ -r "$IMAGE_PATH" ]` check (not lc_select_image's existence check) can be
# what catches it.
: > "$ROOT/bce-images-canonical/unreadable.sif"
chmod 000 "$ROOT/bce-images-canonical/unreadable.sif"
UNREADABLE_OUT=$(build_course_env --course am115 --canvas-id 172566 --image unreadable.sif)
chmod 644 "$ROOT/bce-images-canonical/unreadable.sif"
assert_contains "$UNREADABLE_OUT" "not readable"

it "it propagates the job's failure to its own exit status"
SBATCH_EXIT=7 build_course_env --course am115 --canvas-id 172566 --image ok.sif >/dev/null
assert_eq "$?" "7"

it "a failed job names the Slurm log path so an administrator knows where to look"
# The exit-status test above redirects all output to /dev/null and checks
# only $?, so it would not notice this text vanishing. The submission message
# ALSO names the log path unconditionally (both on success and failure), so a
# bare check for the path anywhere in the output would still pass even if the
# failure branch's own restatement were deleted -- pin this to the actual
# failure phrasing plus the path together, which only the failure branch
# emits.
FAILED_OUT=$(SBATCH_EXIT=7 build_course_env --course am115 --canvas-id 172566 --image ok.sif)
assert_contains "$FAILED_OUT" "see Slurm log at $ROOT/bce-scratch/provisioning/am115/provision.log"

it "--rebuild is reflected in the generated job script"
build_course_env --course am115 --canvas-id 172566 --image ok.sif --rebuild >/dev/null
assert_contains "$JOB_SCRIPT" "--rebuild"

it "--rebuild is absent from the generated job script when not passed"
# An administrator's explicit rebuild request silently dropped (or, in the
# other direction, an implicit rebuild nobody asked for) is a real footgun in
# either direction -- assert both.
build_course_env --course am115 --canvas-id 172566 --image ok.sif >/dev/null
assert_not_contains "$JOB_SCRIPT" "--rebuild"

it "--dry-run prints the job script without submitting"
: > "$SBATCH_ARGV_LOG"
out=$(build_course_env --course am115 --canvas-id 172566 --image ok.sif --dry-run)
assert_contains "$out" "apptainer"

it "--dry-run does not submit anything"
assert_eq "$(cat "$SBATCH_ARGV_LOG")" ""

it "--dry-run still exits 0"
build_course_env --course am115 --canvas-id 172566 --image ok.sif --dry-run >/dev/null
assert_eq "$?" "0"

it "it requires all three mandatory flags"
assert_contains "$(scripts/submit-provision-course-env.sh --course am115 2>&1)" "usage"

it "it rejects an unknown flag"
assert_contains "$(scripts/submit-provision-course-env.sh --nope 2>&1)" "usage"

it "it prints the derived course folder and environment root"
OUT=$(build_course_env --course am115 --canvas-id 172566 --image ok.sif)
assert_contains "$OUT" "course_folder=${DERIVED_COURSE_FOLDER}"
assert_contains "$OUT" "environment_root=${DERIVED_COURSE_FOLDER}/envs"

it "it fails when the derived course folder does not exist"
# Naming the ID alone would also pass if the writable check alone caught this
# (test -w on a nonexistent path is also false) with a message that merely
# happens to repeat the ID -- pin this to "does not exist" specifically, so
# an existence check that got silently deleted shows up as a failure here,
# not just as a coincidentally-similar writability failure.
assert_contains "$(build_course_env --course am115 --canvas-id 999999 --image ok.sif)" "does not exist"

it "it fails when the derived course folder exists but is not writable"
mkdir -p "${BCE_COURSE_ROOT}/555555outer/555555"
chmod 500 "${BCE_COURSE_ROOT}/555555outer/555555"
NOTWRITABLE_OUT=$(build_course_env --course am115 --canvas-id 555555 --image ok.sif)
chmod 700 "${BCE_COURSE_ROOT}/555555outer/555555"
assert_contains "$NOTWRITABLE_OUT" "writable"

it "it fails, naming the disagreement, when a sub-app's declared path disagrees with what was derived"
# A course whose spec directory exists but whose sub-apps declare a DIFFERENT
# course folder than the one just derived -- the copy-paste-and-forgot-to-
# update-the-folder mistake render-forms.sh's own check #6 guards against at
# the OOD-form layer. This proves the submitter guards it too, at the
# provisioning layer, independently.
mkdir -p "$BCE_REPO/envs/mismatched"
cp envs/am115/manager \
   envs/am115/python-version \
   envs/am115/environment.yml \
   "$BCE_REPO/envs/mismatched/"
# Swaps BOTH halves of the folder ID uniformly (172566outer/172566 ->
# 172567outer/172567), so the sub-app still declares an internally
# consistent, well-formed course folder -- just for the WRONG Canvas ID. The
# --canvas-id passed below stays 172566, so the derived folder still resolves
# to the real, pre-created fixture directory.
sed 's#172566outer/172566#172567outer/172567#g' "$BCE_REPO/ood/jupyterlab-ai/local/am115.yml.erb" \
    > "$BCE_REPO/ood/jupyterlab-ai/local/mismatched.yml.erb"
cp "$BCE_REPO/ood/codeserver-ai/local/am115.yml.erb" "$BCE_REPO/ood/codeserver-ai/local/mismatched.yml.erb"
MISMATCH_OUT=$(build_course_env --course mismatched --canvas-id 172566 --image ok.sif)
assert_contains "$MISMATCH_OUT" "disagrees"

it "--environment-root skips the sub-app agreement check for a deliberate override"
# The mismatched course above still fails once an override is given, because
# the course folder itself must still exist and be writable -- so this reuses
# a fresh course whose derived folder legitimately exists.
OVERRIDE_OUT=$(build_course_env --course am115 --canvas-id 172566 --image ok.sif \
    --environment-root "${DERIVED_COURSE_FOLDER}/alt-envs")
assert_not_contains "$OVERRIDE_OUT" "disagrees"

it "--environment-root override is reflected in the generated job script"
build_course_env --course am115 --canvas-id 172566 --image ok.sif \
    --environment-root "${DERIVED_COURSE_FOLDER}/alt-envs" >/dev/null
assert_contains "$JOB_SCRIPT" "${DERIVED_COURSE_FOLDER}/alt-envs"

finish
