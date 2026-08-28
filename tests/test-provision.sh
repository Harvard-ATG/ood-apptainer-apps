#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# Stub managers. They record argv and build a prefix that looks provisioned, so
# the validation half of the script runs against something real.
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

it "it writes the staff-facing README"
assert_success test -f "$ENVROOT/README.md"

it "manager caches go to provisioning scratch, not the course folder"
assert_failure test -d "$ENVROOT/.mamba"

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
#   - the README-note append design ruling: an optional per-course file
#     appended verbatim, and its absence changing nothing
#   - the actual repo-level move: README-template.md loses its marker
#     mechanism, cs1090a gets its own README-note.md
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

it "it appends an optional per-course README note verbatim when present"
ENVROOT=$(setup)
printf 'COURSE-SPECIFIC-NOTE-MARKER\n' > "$ROOT/spec/README-note.md"
provision "$ENVROOT" >/dev/null 2>&1
assert_contains "$(cat "$ENVROOT/README.md")" "COURSE-SPECIFIC-NOTE-MARKER"

it "it does not append a README note when the spec carries none"
ENVROOT=$(setup)
provision "$ENVROOT" >/dev/null 2>&1
assert_not_contains "$(cat "$ENVROOT/README.md")" "COURSE-SPECIFIC-NOTE-MARKER"

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

it "uv: it writes the staff-facing README"
assert_success test -f "$ENVROOT/README.md"

# --- The repo-level design ruling: move CS1090A's note out of the template --
it "README-template.md no longer carries the course-specific removal markers"
assert_failure grep -q "BEGIN COURSE-SPECIFIC" images/jupyter-codeserver-ai/envs/README-template.md

it "cs1090a's course-specific note now lives in its own file beside its spec"
assert_success test -f images/jupyter-codeserver-ai/envs/cs1090a/README-note.md

it "the moved note still pins the otter-grader constraint"
assert_contains "$(cat images/jupyter-codeserver-ai/envs/cs1090a/README-note.md)" "otter-grader"

finish
