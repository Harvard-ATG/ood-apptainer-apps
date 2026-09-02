# Building and deploying images

Three steps, three commands: build the image, copy it to the cluster image roots, then point a sub-app at it.

## 1. Build

```bash
scripts/submit-build-image.sh jupyter-codeserver-ai/jupyterlab
```

This runs the build on a compute node and waits for it, so the command's exit status is the build's. Commit or stash your changes first. The build refuses to run in a dirty worktree.

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

To test a change to a definition, run `apptainer build` yourself. Only the output of `build-image.sh` can be deployed.

## 2. Deploy

```bash
scripts/deploy-image.sh build/jupyterlab-20260828T030141Z-4e73009.sif
```

This copies all three files to the canonical image root, then to the fast one, checking the checksum at each. Add `--dry-run` to see where they would go without copying anything.

It never overwrites. If any of the three files is already in either root, it copies nothing and stops.

Deploying is a file copy. It needs no compute node and no Apptainer.

## 3. Point a sub-app at it

The deploy ends by printing the line to set:

```text
imagefile: "<family>/<artifact>"
```

Set it in the sub-app under `ood/<app>/local/`, run the release gate, and commit the change:

```bash
scripts/render-forms.sh
```

Editing that line is the only thing that changes which image students launch. The deploy does not do it for you.

## Driving a build before a course names it

`ood/<app>/local/admin.yml.erb` is an administrator sandbox. It is a normal sub-app with one difference: its `enabledGroups` list is empty, so only the OOD admin group can see it. Everyone else gets `disable_this_app`.

Its `imagefile`, `course_folder` and `environment_root` are dropdowns rather than fixed strings. That lets you launch a build, mount a real course folder, and drive the session before any course sub-app names the image. Nothing is committed to test a build.

The image list is read from the canonical image root each time an administrator loads the dashboard. A deploy therefore appears in the dropdown at once, with no symlink to repoint and nothing to commit. The list is newest first, because the artifact name carries a fixed-width UTC stamp and a descending sort of those names is chronological.

Everyone else gets a placeholder entry and no filesystem access at all. That gate matters. The dashboard renders every sub-app's header for every user on every page load. An ungated listing therefore puts a readdir on the slower filesystem in every student's dashboard.

When the image root is unreadable, an administrator sees that same placeholder, `NO-DEPLOYED-IMAGE-FOUND.sif`. It names no real artifact, so selecting it fails at launch with "image not found at authoritative path" instead of starting something unintended.

The course environment dropdown offers each course's `envs` prefix, and `(none)` first. `(none)` starts the session on the image alone, with no course kernel and no warning about one.

**Never add a Canvas ID to a sandbox `enabledGroups` list.** The dropdowns are a convenience, not a boundary. A hand-posted form carries any value, exactly as `submit.yml.erb` says of its widget bounds. Two facts make that safe. Only administrators reach the form, and the job runs as the submitting user, so a mount grants nothing that user's own shell does not. One Canvas ID in that list ends both. `tests/test-subapps.sh` asserts the list is empty.

A sandbox is not a course template. Copy `examples/course.yml.erb` for a course, so its image stays pinned by name and the git history answers which build the course ran.

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

**The build stops before it starts, saying the worktree is dirty.** Commit or stash your changes. The artifact name contains the commit, so the build needs one.

**The build finishes, then deletes the artifact.** Its architecture does not match `$OOD_APPTAINER_TARGET_ARCH`. Build on a matching host. To keep a mismatched build for testing a definition, set `OOD_APPTAINER_TARGET_ARCH` to the build host's architecture.

**The deploy says a file already exists.** That name has been used. Names are never reused, so build again and deploy the new artifact.

**The deploy fails after the canonical copy.** The image still works. Sessions use the canonical copy and read it over a slower filesystem. Do not re-run the deploy, it will refuse. Copy the three files into the fast root by hand, or build again.
