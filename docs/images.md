# Building and deploying images

Three steps, three commands: build the image, copy it to the cluster image
roots, then point a sub-app at it.

## 1. Build

```bash
scripts/submit-build-image.sh jupyter-codeserver-ai/jupyterlab
```

This runs the build on a compute node and waits for it, so the command's exit
status is the build's. Commit or stash your changes first. The build refuses to
run in a dirty worktree.

It writes three files to `build/`:

| File | What it is |
|---|---|
| `<app>-<UTC stamp>-<short commit>.sif` | the image |
| `<artifact>.sha256` | its checksum |
| `<artifact>.metadata` | what it was built from |

Options:

| Flag | Default |
|---|---|
| `--cpus N` | `8` |
| `--mem SIZE` | `16G` |
| `--time HH:MM:SS` | `02:00:00` |
| `--partition NAME` | the cluster's choice |
| `--dry-run` | print the job script and stop |

The job log is at `$OOD_APPTAINER_BUILD_SCRATCH/logs/<family>-<app>.log`.

To test a change to a definition, run `apptainer build` yourself. Only the
output of `build-image.sh` can be deployed.

## 2. Deploy

```bash
scripts/deploy-image.sh build/jupyterlab-20260828T030141Z-4e73009.sif
```

This copies all three files to the canonical image root, then to the fast one,
checking the checksum at each. Add `--dry-run` to see where they would go
without copying anything.

It never overwrites. If any of the three files is already in either root, it
copies nothing and stops.

Deploying is a file copy. It needs no compute node and no Apptainer.

## 3. Point a sub-app at it

The deploy ends by printing the line to set:

```text
imagefile: "<family>/<artifact>"
```

Set it in the sub-app under `ood/<app>/local/`, run the release gate, and commit
the change:

```bash
scripts/render-forms.sh
```

Editing that line is the only thing that changes which image students launch.
The deploy does not do it for you.

## What the metadata records

Read the `.metadata` sidecar to identify a deployed image without rebuilding it.

| Key | Value |
|---|---|
| `artifact` | the `.sif` filename |
| `family`, `app` | which definition was built |
| `git_commit` | the commit it was built from |
| `build_timestamp` | the UTC stamp in the filename |
| `build_arch` | the architecture of the image |
| `build_command` | the `apptainer build` command used |
| `definition_sha256`, `recipe_sha256`, `versions_sha256` | checksums of the definition, the shared install script and `versions.env` |
| `pin_*` | every pinned version from `versions.env` |

## Troubleshooting

**The build stops before it starts, saying the worktree is dirty.** Commit or
stash your changes. The artifact name contains the commit, so the build needs
one.

**The build finishes, then deletes the artifact.** Its architecture does not
match `$OOD_APPTAINER_TARGET_ARCH`. Build on a matching host. To keep a
mismatched build for testing a definition, set `OOD_APPTAINER_TARGET_ARCH` to
the build host's architecture.

**The deploy says a file already exists.** That name has been used. Names are
never reused, so build again and deploy the new artifact.

**The deploy fails after the canonical copy.** The image still works. Sessions
use the canonical copy and read it over a slower filesystem. Do not re-run the
deploy, it will refuse. Copy the three files into the fast root by hand, or
build again.
