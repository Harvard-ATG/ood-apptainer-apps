#!/usr/bin/env bash
# Creates one course Python environment prefix, AT ITS FINAL ABSOLUTE PATH.
#
# Runs inside the JupyterLab image on a compute node, launched by
# scripts/build-course-env.sh's batch job -- never through the OOD launch
# path, because by definition the interpreter it is about to create does not
# exist yet.
#
#   provision-course-env.sh --spec <dir> --environment-root <path> \
#       --course-folder <path> --scratch <dir> [--rebuild]
#
# Exit status is nonzero for every failure, and every failure names the path
# involved. Staff records (manager, source files, README.md) are written only
# after the new prefix validates; a prefix that fails validation is left with
# no records at all, since a record is a claim that the prefix is usable.
set -uo pipefail

this_script="scripts/provision-course-env.sh"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../ood/lib/launch-common.sh
. "${REPO_ROOT}/ood/lib/launch-common.sh"

fail() {
    lc_log "ERROR: $1"
    exit 1
}

usage() {
    cat >&2 <<EOF
usage: $0 --spec <dir> --environment-root <path> --course-folder <path> --scratch <dir> [--rebuild]
EOF
    exit 64
}

SPEC=""
ENV_ROOT_ARG=""
COURSE_FOLDER_ARG=""
SCRATCH=""
REBUILD=0

while [ $# -gt 0 ]; do
    case "$1" in
        --spec)
            [ $# -ge 2 ] || usage
            SPEC="$2"
            shift 2
            ;;
        --environment-root)
            [ $# -ge 2 ] || usage
            ENV_ROOT_ARG="$2"
            shift 2
            ;;
        --course-folder)
            [ $# -ge 2 ] || usage
            COURSE_FOLDER_ARG="$2"
            shift 2
            ;;
        --scratch)
            [ $# -ge 2 ] || usage
            SCRATCH="$2"
            shift 2
            ;;
        --rebuild)
            REBUILD=1
            shift
            ;;
        *)
            echo "ERROR: unknown flag: $1" >&2
            usage
            ;;
    esac
done

[ -n "$SPEC" ] && [ -n "$ENV_ROOT_ARG" ] && [ -n "$COURSE_FOLDER_ARG" ] && [ -n "$SCRATCH" ] || usage

# --- Step 2: environment root must resolve beneath the course folder -------
# Same realpath-and-prefix test the host-side launcher uses (lc_validate_under
# in ood/lib/launch-common.sh), so a compromised or misconfigured environment
# root can never point provisioning somewhere outside the course's own space.
# lc_validate_under already logs its own "... which escapes ..." diagnostic to
# stderr on failure; the message below adds the "course folder" framing so a
# plain out-of-bounds path (no symlink involved) is described in those terms
# too, not just as a resolved-path mismatch.
RESOLVED_ENV_ROOT=$(lc_validate_under "$ENV_ROOT_ARG" "$COURSE_FOLDER_ARG") \
    || fail "environment root '${ENV_ROOT_ARG}' is not within the course folder '${COURSE_FOLDER_ARG}'"

PREFIX="${RESOLVED_ENV_ROOT}/default"

# --- Step 3: read the spec's manager and python-version ---------------------
[ -f "${SPEC}/manager" ] || fail "no manager file in spec directory '${SPEC}'"
MANAGER=$(tr -d '[:space:]' < "${SPEC}/manager")
case "$MANAGER" in
    micromamba | uv) : ;;
    *) fail "unsupported manager '${MANAGER}' in spec directory '${SPEC}' (must be micromamba or uv)" ;;
esac

[ -f "${SPEC}/python-version" ] || fail "no python-version file in spec directory '${SPEC}'"
PY_VERSION=$(tr -d '[:space:]' < "${SPEC}/python-version")
[ -n "$PY_VERSION" ] || fail "python-version file in spec directory '${SPEC}' is empty"

# --- Step 4: the source files must match the manager, and only that manager -
# A directory carrying both managers' files is ambiguous about ownership: one
# manager owns a prefix for its whole lifetime, so mixed source files here
# mean the spec itself cannot be trusted to say which manager is authoritative.
if [ "$MANAGER" = micromamba ]; then
    [ -f "${SPEC}/environment.yml" ] \
        || fail "manager is micromamba but no environment.yml in spec directory '${SPEC}'"
    [ -f "${SPEC}/pyproject.toml" ] \
        && fail "spec directory '${SPEC}' declares manager micromamba but also carries pyproject.toml -- ambiguous ownership"
else
    [ -f "${SPEC}/pyproject.toml" ] \
        || fail "manager is uv but no pyproject.toml in spec directory '${SPEC}'"
    [ -f "${SPEC}/environment.yml" ] \
        && fail "spec directory '${SPEC}' declares manager uv but also carries environment.yml -- ambiguous ownership"
fi

# --- Step 5: refuse to clobber an existing default, unless --rebuild -------
if [ -e "$PREFIX" ]; then
    if [ "$REBUILD" -ne 1 ]; then
        fail "environment prefix already exists at '${PREFIX}'; pass --rebuild to recreate it"
    fi
    rm -rf "$PREFIX"
fi

# --- Step 6: point manager caches and temp files at scratch, never the course
# folder. Nothing large -- solver caches, package downloads -- belongs beside
# the prefixes staff look at.
mkdir -p "$SCRATCH" || fail "cannot create scratch directory '${SCRATCH}'"
MAMBA_ROOT_PREFIX="${SCRATCH}/mamba-root"
UV_CACHE_DIR="${SCRATCH}/uv-cache"
TMPDIR="${SCRATCH}/tmp"
export MAMBA_ROOT_PREFIX UV_CACHE_DIR TMPDIR
mkdir -p "$MAMBA_ROOT_PREFIX" "$UV_CACHE_DIR" "$TMPDIR" \
    || fail "cannot create manager cache directories under scratch '${SCRATCH}'"

# --- Step 7: create the prefix at its FINAL absolute path -------------------
mkdir -p "$RESOLVED_ENV_ROOT" || fail "cannot create environment root '${RESOLVED_ENV_ROOT}'"

if [ "$MANAGER" = micromamba ]; then
    micromamba create --yes --prefix "$PREFIX" --file "${SPEC}/environment.yml" \
        || fail "micromamba create failed for prefix '${PREFIX}'"
else
    # A uv prefix built against the image's Python would break when the image's
    # Python changed rather than when anything about the environment changed.
    # Installing the base interpreter beneath the environment root keeps the
    # prefix self-contained, the same as a micromamba prefix.
    UV_PYTHON_INSTALL_DIR="${RESOLVED_ENV_ROOT}/python"
    export UV_PYTHON_INSTALL_DIR
    mkdir -p "$UV_PYTHON_INSTALL_DIR" || fail "cannot create '${UV_PYTHON_INSTALL_DIR}'"

    uv python install "$PY_VERSION" \
        || fail "uv python install ${PY_VERSION} failed"

    INSTALLED_PYTHON=$(uv python find "$PY_VERSION") \
        || fail "cannot locate the uv-installed interpreter for Python ${PY_VERSION}"
    [ -n "$INSTALLED_PYTHON" ] \
        || fail "uv python find returned no interpreter for Python ${PY_VERSION}"

    UV_PROJECT_ENVIRONMENT="$PREFIX" uv sync --project "$SPEC" --python "$INSTALLED_PYTHON" \
        || fail "uv sync failed for prefix '${PREFIX}'"
fi

# --- Step 8: validate before recording anything -----------------------------
[ -x "${PREFIX}/bin/python" ] || fail "no usable interpreter at '${PREFIX}/bin/python' after provisioning"

PY_BANNER=$("${PREFIX}/bin/python" -V 2>&1) \
    || fail "'${PREFIX}/bin/python -V' failed"
ACTUAL_PY_VERSION=$(printf '%s\n' "$PY_BANNER" | awk '{print $2}')
case "$ACTUAL_PY_VERSION" in
    "${PY_VERSION}" | "${PY_VERSION}".*) : ;;
    *) fail "prefix '${PREFIX}' reports Python '${ACTUAL_PY_VERSION}', expected ${PY_VERSION}" ;;
esac

"${PREFIX}/bin/python" -c "import ipykernel" >/dev/null 2>&1 \
    || fail "prefix '${PREFIX}' cannot import ipykernel; no kernel can start"

# A representative import from the spec: the first dependency that is neither
# python nor ipykernel (both already checked above). Best-effort by design --
# a spec that declares nothing beyond ipykernel has nothing further to check.
pick_representative_package() {
    if [ "$MANAGER" = micromamba ]; then
        sed -n '/^dependencies:/,/^[^ ]/p' "${SPEC}/environment.yml" \
            | grep -E '^[[:space:]]*-[[:space:]]+[A-Za-z]' \
            | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/[<>=!,;].*$//; s/:$//; s/[[:space:]]+$//' \
            | grep -vxE 'python|ipykernel|pip' \
            | head -n1
    else
        grep -oE '"[A-Za-z0-9_.-]+' "${SPEC}/pyproject.toml" \
            | sed -E 's/^"//' \
            | grep -vxE 'python|ipykernel' \
            | head -n1
    fi
}

# A small number of well-known distribution names whose import name differs.
representative_import_name() {
    case "$1" in
        beautifulsoup4) echo bs4 ;;
        scikit-learn) echo sklearn ;;
        python-graphviz) echo graphviz ;;
        pyyaml) echo yaml ;;
        pillow) echo PIL ;;
        imbalanced-learn) echo imblearn ;;
        *) echo "${1//-/_}" ;;
    esac
}

REP_PACKAGE=$(pick_representative_package)
if [ -n "$REP_PACKAGE" ]; then
    REP_IMPORT=$(representative_import_name "$REP_PACKAGE")
    "${PREFIX}/bin/python" -c "import ${REP_IMPORT}" >/dev/null 2>&1 \
        || fail "prefix '${PREFIX}' cannot import ${REP_IMPORT} (from spec package '${REP_PACKAGE}')"
fi

# --- Step 9: validate the permission model ----------------------------------
# Every directory in the new prefix must be traversable and readable by
# others; that is what makes the environment usable by students. Report an
# ownership/ACL surprise rather than silently fixing it -- provisioning
# preserves the course folder's existing permission model, it does not
# replace it.
BAD_PERMS=$(find "$PREFIX" ! -perm -o+rX)
if [ -n "$BAD_PERMS" ]; then
    fail "prefix '${PREFIX}' has entries not readable/traversable by others (students would be unable to use the environment): $(printf '%s' "$BAD_PERMS" | tr '\n' ' ')"
fi

# --- Step 10: only now write the staff records ------------------------------
printf '%s\n' "$MANAGER" > "${RESOLVED_ENV_ROOT}/manager" \
    || fail "cannot write manager record at '${RESOLVED_ENV_ROOT}/manager'"

if [ "$MANAGER" = micromamba ]; then
    cp "${SPEC}/environment.yml" "${RESOLVED_ENV_ROOT}/environment.yml" \
        || fail "cannot copy environment.yml to '${RESOLVED_ENV_ROOT}'"
else
    cp "${SPEC}/pyproject.toml" "${RESOLVED_ENV_ROOT}/pyproject.toml" \
        || fail "cannot copy pyproject.toml to '${RESOLVED_ENV_ROOT}'"
    if [ -f "${SPEC}/uv.lock" ]; then
        cp "${SPEC}/uv.lock" "${RESOLVED_ENV_ROOT}/uv.lock" \
            || fail "cannot copy uv.lock to '${RESOLVED_ENV_ROOT}'"
    fi
fi

TEMPLATE="${REPO_ROOT}/images/jupyter-codeserver-ai/envs/README-template.md"
[ -f "$TEMPLATE" ] || fail "README template missing at '${TEMPLATE}'"

# The spec directory's own basename is the only course identifier this script
# is given (there is no --course flag; the interface is spec/root/folder/
# scratch only), and it is exactly how the spec directories are already named
# (am115, cs1090a) -- uppercased to match the display name used elsewhere
# (the environment.yml headers, e.g. "AM115").
COURSE_NAME=$(basename "$SPEC" | tr '[:lower:]' '[:upper:]')

sed -e "s/__COURSE__/${COURSE_NAME}/g" \
    -e "s/__MANAGER__/${MANAGER}/g" \
    -e "s/__PYTHON_VERSION__/${PY_VERSION}/g" \
    "$TEMPLATE" > "${RESOLVED_ENV_ROOT}/README.md" \
    || fail "cannot render README to '${RESOLVED_ENV_ROOT}/README.md'"

# An optional per-course note, appended verbatim when the spec carries one.
# This replaces the template's old BEGIN/END COURSE-SPECIFIC marker mechanism:
# "does this course have a note" is now a test -f, not a marker scan that
# every other course's render had to skip correctly.
if [ -f "${SPEC}/README-note.md" ]; then
    cat "${SPEC}/README-note.md" >> "${RESOLVED_ENV_ROOT}/README.md" \
        || fail "cannot append course-specific README note to '${RESOLVED_ENV_ROOT}/README.md'"
fi

# --- Step 11: report what was built -----------------------------------------
printf 'prefix=%s\n' "$PREFIX"
printf 'manager=%s\n' "$MANAGER"
printf 'python_version=%s\n' "$ACTUAL_PY_VERSION"
