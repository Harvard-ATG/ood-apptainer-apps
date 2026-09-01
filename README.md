# ood-apptainer-apps

Apptainer-based [Open OnDemand][ood] interactive apps with AI coding agents preinstalled, built by Harvard ATG for HUIT OOD. Two parent apps — **Jupyter Lab** and **Code Server** — each serve per-course sub-apps on an HPC cluster.

Students launch a session from the OOD portal, land in a container on a compute node, and get a notebook or editor with [Claude Code][cc] and [Codex][codex] on `PATH`. They sign in to those tools with their own accounts; no shared credentials exist in any image.

> **The AI apps carry a wider blast radius than the standard ones.** In
> `jupyterlab-ai` and `codeserver-ai` the student's real home is mounted
> read-write and either agent can read and transmit any unmasked file the
> student can read; in `codeserver-ai`, workspace trust is also disabled. An
> app built without the agents does not inherit any of this, which is the
> point of keeping the variants separate.

[ood]: https://openondemand.org/
[cc]: https://www.anthropic.com/claude-code
[codex]: https://openai.com/codex/

## Overview

There are four components, with a deliberate split of ownership between them:

| Component | Owns | Lives |
|---|---|---|
| **Image** | The server, the AI CLIs, editor and JupyterLab extensions | `images/` |
| **Course environment** | `ipykernel` and everything a notebook imports | Outside this repo, on the shared filesystem, maintained by teaching staff. `envs/<course>/` holds only the initial spec it is first built from |
| **Sub-app** | Who may launch it, which image, which course folder, what Slurm resources | `ood/<app>/local/` |
| **Launcher** | Path validation, containment, and starting the server | `ood/lib/` and `ood/<app>/template/` |

The image owns what the server process imports while the course environment owns what a notebook imports. That is why JupyterLab is not in the course environment and `ipykernel` is not in the image, and why teaching staff can add course packages themselves while a server extension needs a rebuild.

The launcher is split in two halves: the host-side half validates paths and decides containment before any namespace exists, whereas the in-container half probes what actually works inside the image and then `exec`s the server.

## Repository structure

```text
.
├── images/
│   ├── jupyter-codeserver-ai/  the AI image family — one recipe, two servers
│   │   ├── common/             shared recipe both images run — identical AI surface
│   │   │   ├── claude-code/    managed settings and MCP policy, baked in at build
│   │   │   ├── codex/          managed config and its pinned requirements
│   │   │   └── versions.env    every pinned version, in one place
│   │   ├── jupyterlab/         Apptainer definition, from the Jupyter Docker Stacks base
│   │   └── codeserver/         Apptainer definition, from an Ubuntu base
│   ├── jupyter-codeserver/     (not built) the same two servers, without the agents
│   └── rstudio/                (not built) an unrelated family would sit alongside
├── envs/<course>/              initial course environment specification
├── docs/                       how to provision and maintain those environments
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

**Adding an app.** An app is a directory under `ood/` holding a `manifest.yml`; that is the whole of what `scripts/lib/app-dirs.sh` needs to discover it, so vendoring and most of the suite cover a new app as soon as it exists. What still has to be written down is everything that states a fact about it: an image family under `images/`, its Canvas gating in `tests/test-subapps.sh`, and its display name and script expectations in the suites that assert those. Adding one requires no edit to the apps already here.

## Scripts

| Script | Purpose |
|---|---|
| `build-image.sh` | Builds one immutable image artifact with checksum and metadata sidecars |
| `submit-provision-course-env.sh` | Submits the compute-node job that provisions one course's Python environment |
| `provision-course-env.sh` | The image-side script that job runs |
| `render-forms.sh` | Release gate — renders every sub-app against its templates and cross-checks them |
| `sync-launch-lib.sh` | Vendors the shared launch library into each app |
| `smoke-test-checklist.md` | Manual QA checklist, run once per course per term |

## Environment overrides

**Nothing in a normal deployment sets any of these.** Every one is an optional override with an in-repo default, listed here so a deploy can be checked against it rather than against the source. Each is read as `${VAR:-default}`, so a setter whose name does not match one below is not an error — its value is silently ignored in favour of the default. That is the failure this table exists to make findable.

| Variable | Default | Read by |
|---|---|---|
| `OOD_APPTAINER_IMAGE_ROOT_FAST` | `/scratch/apptainerImages` | launcher |
| `OOD_APPTAINER_IMAGE_ROOT_CANONICAL` | `/shared/apptainerImages` | launcher |
| `OOD_APPTAINER_BIN` | discovered via the Spack `apptainer` environment | launcher |
| `OOD_APPTAINER_SCRATCH_ROOT` | `/scratch/<user>/ood/apptainer` | launcher, `submit-provision-course-env.sh` |
| `OOD_APPTAINER_COURSE_SHARED_ROOT` | `/shared/courseSharedFolders` | `submit-provision-course-env.sh` |
| `OOD_APPTAINER_TARGET_ARCH` | `x86_64` | `build-image.sh` |
| `OOD_APPTAINER_OUTPUT_DIR` | `<repo>/build` | `build-image.sh` |
| `OOD_APPTAINER_BUILD_SCRATCH` | `/scratch/<user>/apptainer-build` | `build-image.sh` |

The test suite sets all but `OOD_APPTAINER_OUTPUT_DIR` and `OOD_APPTAINER_BUILD_SCRATCH`, pointing them at fixtures; that is what they exist for. `build-image.sh` names `OOD_APPTAINER_TARGET_ARCH` and `OOD_APPTAINER_BUILD_SCRATCH` in its own failure messages, at the moment either one is needed.

## Before you deploy

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
