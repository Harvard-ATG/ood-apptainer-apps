# ood-apptainer-apps

Apptainer-based [Open OnDemand][ood] interactive apps with AI coding agents
preinstalled, built by Harvard ATG for HUIT OOD. Two parent apps — **Jupyter
Lab** and **Code Server** — each serve per-course sub-apps on an HPC cluster.

Students launch a session from the OOD portal, land in a container on a compute
node, and get a notebook or editor with [Claude Code][cc] and [Codex][codex] on
`PATH`. They sign in to those tools with their own accounts; no shared
credentials exist in any image.

> **These apps carry a wider blast radius than the standard ones.** Code-server
> workspace trust is disabled, the student's real home is mounted read-write,
> and either agent can read and transmit any unmasked file the student can
> read. They are teaching environments — **not** suitable for regulated or
> otherwise sensitive research data.

[ood]: https://openondemand.org/
[cc]: https://www.anthropic.com/claude-code
[codex]: https://openai.com/codex/

## How it fits together

Four pieces, with a deliberate split of ownership between them:

| Piece | Owns | Lives |
|---|---|---|
| **Image** | The server, the AI CLIs, editor and JupyterLab extensions | `images/` |
| **Course environment** | `ipykernel` and everything a notebook imports | Outside this repo, on the shared filesystem, maintained by teaching staff |
| **Sub-app** | Who may launch it, which image, which course folder, what Slurm resources | `ood/<app>-ai/local/` |
| **Launcher** | Path validation, containment, and starting the server | `ood/lib/` and `ood/<app>-ai/template/` |

The rule that explains most of the layout: **the image owns what the server
process imports; the course environment owns what a notebook imports.** That is
why JupyterLab is not in the course environment and `ipykernel` is not in the
image — and why teaching staff can add course packages themselves while a
server extension needs a rebuild.

The launcher is split in two halves because they can answer different
questions. The host-side half validates paths and decides containment before
any namespace exists; the in-container half probes what actually works inside
the image and then `exec`s the server.

## Repository structure

```text
images/jupyter-codeserver-ai/
  common/            shared recipe both images run, so their AI surface is identical
    versions.env     every pinned version, in one place
  jupyterlab/        Apptainer definition, from the Jupyter Docker Stacks base
  codeserver/        Apptainer definition, from an Ubuntu base
  envs/<course>/     initial course environment specification

ood/
  lib/               canonical shared launch logic — EDIT HERE
  jupyterlab-ai/
    template/        host-side launch scripts and the in-container launcher
    examples/        copy source for a new course sub-app
    local/           live per-course sub-apps
  codeserver-ai/     same shape

scripts/             build, provisioning and release-gate scripts
tests/               verification suite
```

Two spellings coexist on purpose: path segments and app names use
`codeserver`, while the software itself is `code-server`. Display names are a
third form (`Code Server`). All three are correct in their own place.

## Scripts

| Script | Purpose |
|---|---|
| `build-image.sh` | Builds one immutable image artifact with checksum and metadata sidecars |
| `build-course-env.sh` | Submits a compute-node job that provisions one course's Python environment |
| `provision-course-env.sh` | The image-side helper that job runs |
| `render-forms.sh` | Release gate — renders every sub-app against its templates and cross-checks them |
| `sync-launch-lib.sh` | Vendors the shared launch library into each app |
| `smoke-test-checklist.md` | Manual QA checklist, run once per course per term |

## Tests

```bash
bash tests/run-all.sh
```

29 suites. It runs unchanged on a Linux laptop or a cluster compute node, but it
is **not portable to a stock macOS shell** — bash 3.2, BSD `sed` and BSD `stat`
each produce failures that read like real defects.

| Dependency | Needed for |
|---|---|
| `bash` ≥ 4 | `declare -A` and `mapfile`, in the release gate and two suites |
| `ruby` | rendering every sub-app and template |
| `jq` | the release gate, `build-course-env.sh`, `test-forms.sh` |
| `apptainer` | nine suites that build and exec a stub container |
| GNU `coreutils` | `stat -c` in the assertion helpers |
| GNU `sed` | in-place fixture edits in `test-forms.sh` |
| `shellcheck` | *optional* — `test-lint.sh` skips without it |

**Only four suites skip themselves:** `test-lint.sh` without `shellcheck`, and
the three image-backed suites when no built image is available. Every other
suite fails rather than skipping, so **`apptainer` is required, not optional** —
dozens of failures across the containment and launcher suites on a fresh clone
usually means it is missing, not that something regressed.

To include the image-backed suites, point them at a built image:

```bash
mkdir -p tests/.cache/images
ln -s /path/to/built/jupyterlab tests/.cache/images/jupyterlab
ln -s /path/to/built/codeserver tests/.cache/images/codeserver
```

`jq` is also a hard dependency of `scripts/render-forms.sh`, which is the gate
to run before any deployment:

```bash
scripts/render-forms.sh    # nonzero exit means do not deploy
```

Neither replaces `scripts/smoke-test-checklist.md`, which covers what no
automated suite can reach from a stub image — real symlink resolution, Canvas
group membership, and deployment file permissions among them.

After editing `ood/lib/launch-common.sh`, vendor it and confirm the copies
match, since OOD stages only an app's `template/` directory:

```bash
bash scripts/sync-launch-lib.sh
bash tests/test-no-drift.sh
```

## A note on scope

Building images, provisioning course environments, and deploying to the OOD web
nodes are administrative actions performed against a live cluster. This
repository holds the code and the checks; the operational runbooks, the design
specification, and the implementation history are maintained by Harvard ATG
outside it.

**No credential, token, or private value may ever be committed here.** The
deployed clone is world-readable to every user on the cluster, `.git` history
included. That is a structural property of how OOD resolves app symlinks, not a
matter of hygiene.
