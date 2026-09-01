#!/usr/bin/env bash
# scripts/submit-build-image.sh: the wrapper that validates and submits ONE
# Slurm job to build an image, and reports that job's real result.
#
# An image build is compute work that does not belong on a login node, and
# Apptainer is not on PATH there without Spack. The wrapper exists so neither
# fact has to be remembered; scripts/build-image.sh is what actually runs.
#
# Tested against a throwaway git repository, because the wrapper refuses a
# dirty worktree -- checking that against this repository would fail whenever
# someone is midway through an edit.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

it "submit-build-image.sh exists and is executable"
assert_success test -x scripts/submit-build-image.sh

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
PATH="$BIN:$PATH"; export PATH

SBI_REPO="$ROOT/repo"
mkdir -p "$SBI_REPO/scripts" "$SBI_REPO/ood/lib" "$SBI_REPO/images/fam/app"
cp scripts/submit-build-image.sh scripts/build-image.sh "$SBI_REPO/scripts/"
cp ood/lib/launch-common.sh "$SBI_REPO/ood/lib/"
chmod 755 "$SBI_REPO/scripts/submit-build-image.sh" "$SBI_REPO/scripts/build-image.sh"
printf 'Bootstrap: docker\nFrom: ubuntu:24.04\n' > "$SBI_REPO/images/fam/app/app.def"

git -C "$SBI_REPO" init -q
git -C "$SBI_REPO" config user.email t@example.com
git -C "$SBI_REPO" config user.name Test
git -C "$SBI_REPO" add -A
git -C "$SBI_REPO" commit -qm init

# Without this the wrapper writes its log under the real /scratch.
export OOD_APPTAINER_BUILD_SCRATCH="$ROOT/build-scratch"

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

submit() {
    : > "$SBATCH_ARGV_LOG"
    : > "$SBATCH_JOB_SCRIPT_FILE"
    "$SBI_REPO/scripts/submit-build-image.sh" "$@" 2>&1
    local status=$?
    SBATCH_ARGV=$(cat "$SBATCH_ARGV_LOG" 2>/dev/null || true)
    JOB_SCRIPT=$(cat "$SBATCH_JOB_SCRIPT_FILE" 2>/dev/null || true)
    return "$status"
}

submit fam/app >/dev/null

it "it submits ONE job"
assert_eq "$(grep -c -- '--wait' <<<"$SBATCH_ARGV")" "1"

it "it waits, so the caller gets the build's real result not a job id"
assert_contains "$SBATCH_ARGV" "--wait"

it "the job is named for the script that runs it and the target it builds"
assert_contains "$SBATCH_ARGV" "--job-name=build-image-fam-app"

it "it requests the default 8 CPUs"
assert_contains "$SBATCH_ARGV" "--cpus-per-task=8"

it "it requests the default 16G"
assert_contains "$SBATCH_ARGV" "--mem=16G"

it "it requests the default 2 hour limit"
assert_contains "$SBATCH_ARGV" "--time=02:00:00"

it "--cpus overrides the default"
submit --cpus 32 fam/app >/dev/null
assert_contains "$SBATCH_ARGV" "--cpus-per-task=32"

it "--mem overrides the default"
submit --mem 64G fam/app >/dev/null
assert_contains "$SBATCH_ARGV" "--mem=64G"

it "--time overrides the default"
submit --time 06:00:00 fam/app >/dev/null
assert_contains "$SBATCH_ARGV" "--time=06:00:00"

it "no partition is requested unless one is asked for"
# Inventing a partition name would be a guess about someone's cluster.
submit fam/app >/dev/null
assert_not_contains "$SBATCH_ARGV" "--partition"

it "--partition is passed through when given"
submit --partition bigmem fam/app >/dev/null
assert_contains "$SBATCH_ARGV" "--partition=bigmem"

submit fam/app >/dev/null

it "the job leaves Apptainer resolution to build-image.sh"
# build-image.sh resolves it through lc_apptainer_bin, inside a command
# substitution. The job must not `spack env activate` on its own: that would
# leave Spack's environment active for `apptainer build --fakeroot`, which
# reads PATH and LD_LIBRARY_PATH. One place resolves Apptainer, not two.
assert_not_contains "$JOB_SCRIPT" "spack env activate"

it "the job runs build-image.sh against the requested target"
assert_contains "$JOB_SCRIPT" "scripts/build-image.sh"
assert_contains "$JOB_SCRIPT" "fam/app"

it "it refuses a target with no definition file, without submitting"
assert_failure submit fam/nonexistent
submit fam/nonexistent >/dev/null 2>&1
assert_eq "$SBATCH_ARGV" ""

it "it refuses a dirty worktree, without submitting"
# build-image.sh refuses one too, but only once the job is running -- after a
# queue wait spent to learn the tree was not committed.
printf 'dirty\n' > "$SBI_REPO/images/fam/app/scratch.txt"
assert_failure submit fam/app
submit fam/app >/dev/null 2>&1
assert_eq "$SBATCH_ARGV" ""
rm -f "$SBI_REPO/images/fam/app/scratch.txt"

it "--dry-run prints the job script and submits nothing"
out=$(submit --dry-run fam/app)
assert_contains "$out" "build-image.sh"
assert_eq "$SBATCH_ARGV" ""

it "it reports the job's real exit status"
SBATCH_EXIT=7 submit fam/app >/dev/null 2>&1
assert_eq "$?" "7"

finish
