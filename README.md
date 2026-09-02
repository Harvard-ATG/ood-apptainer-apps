# ood-apptainer-apps

A monorepo for Apptainer-based [Open OnDemand][ood] interactive apps, built by Harvard ATG for HUIT OOD. Each app runs its server in a container on an HPC compute node and serves per-course sub-apps launched from the portal. The launcher, the build and deploy scripts, the course-environment tooling and the test suite are shared.

[ood]: https://openondemand.org/
[cc]: https://www.anthropic.com/claude-code
[codex]: https://openai.com/codex/

## Apps

| App | Server | Image family | Notes |
|---|---|---|---|
| `jupyterlab-ai` | Jupyter Lab | `jupyter-codeserver-ai` | [Claude Code][cc] and [Codex][codex] on `PATH` |
| `codeserver-ai` | Code Server | `jupyter-codeserver-ai` | [Claude Code][cc] and [Codex][codex] on `PATH`; workspace trust disabled |

> **The AI apps carry a wider blast radius than an app without the agents.** In
> both, the student's real home is mounted read-write and either agent can read
> and transmit any unmasked file the student can read. An app built without the
> agents does not inherit any of this, which is the point of keeping the
> variants separate.
>
> Students sign in to the agents with their own accounts; no shared
> credentials exist in any image.

Each app's per-course sub-apps live in `ood/<app>/local/`. A new app is another directory under `ood/`, backed by an image under `images/`.

## Architecture

There are four components, with a deliberate split of ownership between them:

| Component | Owns | Lives |
|---|---|---|
| **Image** | The server, its editor and JupyterLab extensions, and any AI CLIs | `images/` |
| **Course environment** | `ipykernel` and everything a notebook imports | Outside this repo, on the shared filesystem, maintained by teaching staff. `envs/<course>/` holds only the initial spec it is first built from |
| **Sub-app** | Who may launch it, which image, which course folder, what Slurm resources | `ood/<app>/local/` |
| **Launcher** | Path validation, containment, and starting the server | `ood/lib/` and `ood/<app>/template/` |

The image owns what the server process imports while the course environment owns what a notebook imports. That is why JupyterLab is not in the course environment and `ipykernel` is not in the image, and why teaching staff can add course packages themselves while a server extension needs a rebuild.

The launcher is split in two halves: the host-side half validates paths and decides containment before any namespace exists, whereas the in-container half probes what actually works inside the image and then `exec`s the server.

## Repository structure

```text
.
├── images/
│   └── jupyter-codeserver-ai/  the AI image family — one recipe, two servers
│       ├── common/             shared recipe both images run — identical AI surface
│       │   ├── claude-code/    managed settings and MCP policy, baked in at build
│       │   ├── codex/          managed config and its pinned requirements
│       │   └── versions.env    every pinned version, in one place
│       ├── jupyterlab/         Apptainer definition, from the Jupyter Docker Stacks base
│       └── codeserver/         Apptainer definition, from an Ubuntu base
├── envs/<course>/              initial course environment specification
├── docs/                       design rationale, building images, course environments
├── ood/
│   ├── lib/launch-common.sh    canonical shared launch logic — EDIT HERE
│   ├── jupyterlab-ai/          parent app (form.yml, manifest.yml, submit.yml.erb, …)
│   │   ├── template/           host-side scripts and the in-container launcher
│   │   │   └── lib/            vendored launch-common.sh — regenerate, never edit
│   │   ├── examples/           copy source for a new course sub-app
│   │   └── local/              live per-course sub-apps
│   └── codeserver-ai/          same shape
├── scripts/                    build, provisioning and release-gate scripts
│   └── lib/app-dirs.sh         app discovery — every per-app loop reads this
└── tests/                      verification suite
```

`images/` holds one directory per image family.

**Adding an app.** An app is a directory under `ood/` holding a `manifest.yml`. That is all `scripts/lib/app-dirs.sh` needs to discover it, so vendoring and most of the suite cover a new app as soon as the directory exists.

What you still have to write is everything that states a fact about the app: an image family under `images/`, its Canvas gating in `tests/test-subapps.sh`, and its display name and script expectations in the suites that assert those. Adding an app requires no edit to the apps already here.

## Scripts

| Script | Purpose |
|---|---|
| `submit-build-image.sh` | Submits the compute-node job that builds one image |
| `build-image.sh` | Builds one immutable image artifact with checksum and metadata sidecars |
| `deploy-image.sh` | Publishes one built artifact and its sidecars to both cluster image roots |
| `submit-provision-course-env.sh` | Submits the compute-node job that provisions one course's Python environment |
| `provision-course-env.sh` | The image-side script that job runs |
| `render-forms.sh` | Release gate — renders every sub-app against its templates and cross-checks them |
| `sync-launch-lib.sh` | Vendors the shared launch library into each app |
| `smoke-test-checklist.md` | Manual QA checklist, run once per course per term |

## Environment overrides

**Nothing in a normal deployment sets any of these.** Every one is an optional override with an in-repo default, listed here so a deploy can be checked against it rather than against the source. Each is read as `${VAR:-default}`. A variable whose name does not exactly match one below is not an error: it is ignored and the default is used instead. When an override appears to have had no effect, check its spelling against this table first.

| Variable | Default | Read by |
|---|---|---|
| `OOD_APPTAINER_IMAGE_ROOT_FAST` | `/scratch/apptainerImages` | launcher, `deploy-image.sh` |
| `OOD_APPTAINER_IMAGE_ROOT_CANONICAL` | `/shared/apptainerImages` | launcher, `deploy-image.sh` |
| `OOD_APPTAINER_BIN` | discovered via the Spack `apptainer` environment | launcher, `build-image.sh`, the provisioning job |
| `OOD_APPTAINER_SCRATCH_ROOT` | `/scratch/<user>/ood/apptainer` | launcher, `submit-provision-course-env.sh` |
| `OOD_APPTAINER_COURSE_SHARED_ROOT` | `/shared/courseSharedFolders` | `submit-provision-course-env.sh` |
| `OOD_APPTAINER_TARGET_ARCH` | `x86_64` | `build-image.sh` |
| `OOD_APPTAINER_OUTPUT_DIR` | `<repo>/build` | `build-image.sh` |
| `OOD_APPTAINER_BUILD_SCRATCH` | `/scratch/<user>/apptainer-build` | `build-image.sh`, `submit-build-image.sh` |

The test suite sets all but `OOD_APPTAINER_OUTPUT_DIR`, pointing them at fixtures; that is what they exist for. `build-image.sh` names `OOD_APPTAINER_TARGET_ARCH` and `OOD_APPTAINER_BUILD_SCRATCH` in its own failure messages, at the moment either one is needed.

## Before you ship an app change

Run the release gate (needs `ruby` and `jq`):

```bash
scripts/render-forms.sh    # nonzero exit means do not deploy
```

After editing `ood/lib/launch-common.sh`, vendor it and confirm the copies match, since OOD stages only an app's `template/` directory:

```bash
bash scripts/sync-launch-lib.sh
bash tests/test-no-drift.sh
```

Neither replaces the smoke checklist, which covers what no automated suite can reach from a stub image — real symlink resolution, Canvas group membership, and deployment file permissions among them.

## Deploying an image

```bash
scripts/submit-build-image.sh jupyter-codeserver-ai/jupyterlab    # builds into build/
scripts/deploy-image.sh build/jupyterlab-<stamp>-<commit>.sif     # publishes to both image roots
```

See [docs/images.md](docs/images.md) for the options, what a build produces, and how to point a sub-app at a new image.

## Provisioning a course environment

```bash
scripts/submit-provision-course-env.sh --course cs1090a --canvas-id 12345 \
    --image jupyter-codeserver-ai/jupyterlab-<stamp>-<commit>.sif
```

See [docs/course-environments.md](docs/course-environments.md) for the spec format, how staff maintain a prefix afterwards, and what the common failures mean.

## Tests

```bash
bash tests/run-all.sh
```

Runs on a Linux laptop or a cluster compute node, but **not on a stock macOS shell** — bash 3.2, BSD `sed` and BSD `stat` each produce failures that read like real defects. Needs `bash` ≥ 4, `ruby`, `jq`, `apptainer`, and GNU `coreutils` and `sed`; `shellcheck` is optional.

**Only four suites skip themselves:** `test-lint.sh` without `shellcheck`, and the three image-backed suites when no built image is available. Every other suite fails rather than skipping, so **`apptainer` is required, not optional** — dozens of failures across the containment and launcher suites on a fresh clone usually means it is missing, not that something regressed.

To include the image-backed suites, point them at a built image:

```bash
mkdir -p tests/.cache/images
ln -s /path/to/built/jupyterlab tests/.cache/images/jupyterlab
ln -s /path/to/built/codeserver tests/.cache/images/codeserver
```

## Scope

Building images, provisioning course environments, and deploying to the OOD web nodes are administrative actions performed against a live cluster. This repository holds the code and the checks; the operational runbooks and the implementation history are maintained elsewhere.

**No credential, token, or private value may ever be committed here.** The deployed clone is world-readable to every user on the cluster, `.git` history included. That is a structural property of how OOD resolves app symlinks, not a matter of hygiene.
