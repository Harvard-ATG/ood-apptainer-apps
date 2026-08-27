#!/usr/bin/env bash
# SC2016: the probe helpers pass shell snippets to the container as strings, so
# $HOME and friends MUST stay unexpanded here and expand in the container's shell.
# Every occurrence in this file is deliberate. This directive must precede every
# command in the file, so it sits immediately after the shebang.
# shellcheck disable=SC2016
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

# --- Observe the REAL Apptainer invocation, rather than trusting a hand-built
# string. lc_sterile_prefix invokes the binary via `env -i`, which strips even
# variables this test exports, so the recording shim below cannot learn the
# real apptainer path or the log destination through the environment -- both
# are baked into the shim's own script text instead.
#
# printf '%s\0' is null-separated: an argument containing a space cannot be
# confused with an argument boundary the way a plain string join would allow.
REAL_APPTAINER_BIN=$(command -v apptainer)
ARGV_LOG="$FIXTURE_ROOT/apptainer-argv.log"
RECORDING_SHIM="$FIXTURE_ROOT/apptainer-recorder"
cat > "$RECORDING_SHIM" <<SHIM
#!/usr/bin/env bash
# Records the argv it was called with, then execs the real apptainer.
printf '%s\0' "\$@" >> "$ARGV_LOG"
exec "$REAL_APPTAINER_BIN" "\$@"
SHIM
chmod 755 "$RECORDING_SHIM"

: > "$ARGV_LOG"
lc_run "$RECORDING_SHIM" "$IMAGE" "$ENVF" /bin/true >/dev/null 2>&1
REAL_ARGV=$(tr '\0' '\n' < "$ARGV_LOG")
# Wrapped in newlines so a check for the exact token "--env" cannot be
# satisfied by "--env-file", which contains "--env" as a substring.
REAL_ARGV_LINES=$'\n'"$REAL_ARGV"$'\n'

it "the secret value does not appear in the real Apptainer argv"
assert_not_contains "$REAL_ARGV" "s3cr3t-must-not-appear-on-argv"

it "--containall appears in the real argv"
assert_contains "$REAL_ARGV" "--containall"

it "--cleanenv appears in the real argv"
assert_contains "$REAL_ARGV" "--cleanenv"

it "--no-mount appears in the real argv"
assert_contains "$REAL_ARGV" "--no-mount"

it "--no-mount's value is home,cwd,tmp,hostfs,bind-paths in the real argv"
assert_contains "$REAL_ARGV" "home,cwd,tmp,hostfs,bind-paths"

it "--home appears in the real argv"
assert_contains "$REAL_ARGV" "--home"

it "--env-file appears in the real argv"
assert_contains "$REAL_ARGV" "--env-file"

it "the environment file path appears in the real argv (the path is permitted; only values are not)"
assert_contains "$REAL_ARGV" "$ENVF"

it "--env does not appear at all in the real argv"
# The spec forbids passing container environment values as arguments. A bare
# "--env" is exactly what a regression smuggling a secret via --env KEY=value
# would add, and is distinct from the permitted "--env-file".
assert_not_contains "$REAL_ARGV_LINES" $'\n--env\n'

it "lc_run does not replace the calling shell"
# If lc_run exec'd, this line would never run.
lc_run "$APB" "$IMAGE" "$ENVF" /bin/true >/dev/null 2>&1
assert_eq "still-here" "still-here"

finish
