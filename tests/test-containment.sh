#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh
# shellcheck source=lib/fixture.sh
. lib/fixture.sh
# shellcheck source=../ood/lib/launch-common.sh
. ../ood/lib/launch-common.sh

fixture_create
trap fixture_destroy EXIT
IMAGE=$(fixture_image)
export HOME="$FAKE_HOME"
export OOD_AI_APPTAINER_BIN="${OOD_AI_APPTAINER_BIN:-$(command -v apptainer)}"

ENVF="$FIXTURE_ROOT/env.list"
lc_write_env_file "$ENVF" \
    "COURSE_ENV=$FAKE_ENV_ROOT/default" \
    "ENVIRONMENT_ROOT=$FAKE_ENV_ROOT" \
    "PASSWORD=s3cr3t-must-not-appear-on-argv" \
    "PYTHONNOUSERSITE=1" \
    "PATH=/usr/local/bin:/usr/bin:/bin"

lc_build_binds "$FAKE_COURSE_ROOT" "$FAKE_SCRATCH" "$FAKE_JOB_STATE" "$FAKE_JOB_TMP" "$FAKE_SSH_MASK"
APB=$(lc_apptainer_bin)

# Hostile inputs. None of these may influence the launch.
export APPTAINER_BIND="$FAKE_SECRET_DIR:/mnt/leak"
export APPTAINER_BINDPATH="$FAKE_SECRET_DIR:/mnt/leak2"
export APPTAINER_MOUNT="$FAKE_SECRET_DIR:/mnt/leak3"
export SINGULARITY_BIND="$FAKE_SECRET_DIR:/mnt/leak4"
export SINGULARITY_BINDPATH="$FAKE_SECRET_DIR:/mnt/leak5"
export APPTAINERENV_INJECTED="injected-value"
export SINGULARITYENV_INJECTED2="injected-value-2"
export APPTAINER_HOME="$FAKE_SECRET_DIR"
export LEAK_PLAIN="plain-inherited-value"

probe() { lc_run "$APB" "$IMAGE" "$ENVF" /bin/sh -c "$1" 2>/dev/null; }

it "container HOME is the student's real home"
assert_eq "$(probe 'echo $HOME')" "$FAKE_HOME"

it "the real home's existing content is visible, not an empty auto-created dir"
# Binding anything under $HOME auto-creates $HOME in the container, so a
# writability check alone passes even when the home mount is entirely missing.
echo "home-marker" > "$FAKE_HOME/home-marker.txt"
assert_eq "$(probe 'cat $HOME/home-marker.txt 2>/dev/null')" "home-marker"

it "container home is writable"
assert_eq "$(probe 'touch $HOME/probe && echo writable')" "writable"

it "COURSE_ENV arrives from the environment file"
assert_eq "$(probe 'echo $COURSE_ENV')" "$FAKE_ENV_ROOT/default"

it "PYTHONNOUSERSITE is set"
assert_eq "$(probe 'echo $PYTHONNOUSERSITE')" "1"

it "APPTAINERENV_ injection does not reach the container"
assert_eq "$(probe 'echo ${INJECTED:-absent}')" "absent"

it "SINGULARITYENV_ injection does not reach the container"
assert_eq "$(probe 'echo ${INJECTED2:-absent}')" "absent"

it "a plain inherited variable does not reach the container"
assert_eq "$(probe 'echo ${LEAK_PLAIN:-absent}')" "absent"

for target in /mnt/leak /mnt/leak2 /mnt/leak3 /mnt/leak4 /mnt/leak5; do
    it "hostile bind $target is not mounted"
    assert_eq "$(probe "test -e $target && echo PRESENT || echo absent")" "absent"
done

it "the secret directory is not reachable at its own path"
assert_eq "$(probe "test -e $FAKE_SECRET_DIR && echo PRESENT || echo absent")" "absent"

it "APPTAINER_HOME cannot redirect the container home"
assert_eq "$(probe 'echo $HOME')" "$FAKE_HOME"

it "the course shared folder is readable at the same absolute path"
assert_eq "$(probe "cat $FAKE_COURSE_ROOT/marker.txt")" "course-marker"

it "the course python is executable in-container"
assert_contains "$(probe "$FAKE_ENV_ROOT/default/bin/python")" "Python 3.13"

it "\$HOME/.ssh is masked and empty"
assert_eq "$(probe 'ls -A $HOME/.ssh | wc -l | tr -d " "')" "0"

it "the host id_rsa is not visible through the mask"
assert_eq "$(probe 'test -e $HOME/.ssh/id_rsa && echo PRESENT || echo absent')" "absent"

it "/state is writable"
assert_eq "$(probe 'touch /state/probe && echo writable')" "writable"

it "/tmp is the per-job scratch directory, not the host /tmp"
probe 'touch /tmp/job-marker' >/dev/null
assert_success test -e "$FAKE_JOB_TMP/job-marker"

it "no Slurm client is present"
assert_eq "$(probe 'command -v sbatch >/dev/null 2>&1 && echo PRESENT || echo absent')" "absent"

it "no Munge socket is present"
assert_eq "$(probe 'test -e /run/munge && echo PRESENT || echo absent')" "absent"

it "the secret value does not appear in the Apptainer command line"
# Reconstruct the argv the launcher would produce and assert the secret is absent.
lc_sterile_prefix
argv="${LC_STERILE[*]} $APB exec --containall --cleanenv --no-mount home,cwd,tmp,hostfs,bind-paths --home $HOME:$HOME --env-file $ENVF ${LC_BINDS[*]} $IMAGE"
assert_not_contains "$argv" "s3cr3t-must-not-appear-on-argv"

it "the environment file path may appear in argv"
assert_contains "$argv" "$ENVF"

it "lc_run does not replace the calling shell"
# If lc_run exec'd, this line would never run.
lc_run "$APB" "$IMAGE" "$ENVF" /bin/true >/dev/null 2>&1
assert_eq "still-here" "still-here"

finish
