# Understanding the HUIT OOD Apptainer apps

This document explains the architecture, safety boundaries, and maintenance invariants for contributors. Site-specific deployment procedures and term operations are maintained separately. The two apps that bundle AI agents add a layer of their own, in [`docs/design-ai-family.md`](design-ai-family.md). Build and provisioning commands are in [`docs/images.md`](images.md) and [`docs/course-environments.md`](course-environments.md).

---

## The platform

Everything here is true of any app in this repository, including one you add.

### The components, and who owns each

The repository is a monorepo of Open OnDemand Batch Connect apps, and an app is any directory under `ood/` that holds a `manifest.yml`. Every app has the same four parts:

```
image (ours, immutable)        →  the server, and whatever the app bundles with it
course environment (staff)     →  the kernel, and everything a notebook imports
sub-app (ours, per course)     →  who can launch, which image, which folder, what resources
launcher (ours, two halves)    →  host side decides and checks. container side execs the server
```

The current apps bundle the Claude Code and Codex CLIs, which is a fact about that app family and not about the platform. [`docs/design-ai-family.md`](design-ai-family.md) covers what follows from it.

One division explains the most: **the image owns everything the server process imports. The course environment owns everything a notebook imports.** That is why JupyterLab is not in the course environment, and why `ipykernel` is not in the image. Kernel-side packages belong to staff, so staff self-serve. A Jupyter or code-server extension still needs a rebuild from us.

### Why two images and no shared base

Each app derives from the upstream base that fits it. Jupyter Docker Stacks serves one, Ubuntu the other. A shared base buys nothing at rest, because SIF is a flat SquashFS with no layer sharing. It also costs an extra build artifact to keep in step.

What the choice gives up is any guarantee that two images agree. When two apps must agree on something, a test has to say so, and [the AI family doc](design-ai-family.md#why-the-two-images-run-one-recipe) holds today's instance.

### Why the launcher is split in two

`template/script.sh.erb` runs on the compute node as the student. It resolves and checks paths, decides which image root to use, writes a mode-`0600` environment file, and starts Apptainer. `template/<app>.script.sh` runs *inside* the container and `exec`s the server.

The two halves answer different questions. Path containment must be decided outside the container, before any namespace exists, and that is where the kernel enforces the enrolled-group gate. Only the inside can answer whether an interpreter *runs*, because the compute node and the image do not share a libc. A probe that succeeds on the host can fail in the image.

`exec` in the inner script is required. The server becomes the container's first process, so `scancel` and walltime expiry reach it directly instead of waiting for the job to be killed. The outer script is deliberately **not** `exec`'d, because OOD records its pid as `SCRIPT_PID` and reaps with `pkill -P`.

Both inner scripts `exec` an **absolute, image-owned path**. A bare command name resolves through a `PATH` whose first element is a staff-writable directory on a shared filesystem. Anyone who can write the course environment can then replace the server every student runs, silently. That was a real defect on the code-server side.

### Containment: what it protects and what it does not

Host-level containment is the security boundary. Apptainer runs unprivileged in the target deployment, so mounts go through FUSE. The launcher runs Apptainer behind `env -i`, with `--containall --cleanenv` and an explicit `--no-mount` list. The bind set is fixed:

- The student's real home.
- The one course folder.
- Their scratch root.
- Job-local state at `/state`, and job-local `/tmp`.
- An empty directory that masks `~/.ssh`.

Two further flags in the same launch line are not containment controls at all: `--underlay` and `-B /dev/full:/dev/full`, which [the AI family doc](design-ai-family.md#the-agents-own-sandboxes-and-the-flags-that-keep-them-working) explains. They are unconditional in `lc_run`, so **every** app that vendors the shared library carries them, including one that has no use for either.

This design **explicitly accepts** two things: the real home is mounted read-write, and outbound HTTPS is unrestricted. A session can read, write and transmit anything the student can reach, because it runs as the student.

Masking `~/.ssh` reduces accidental reuse of existing keys. It does not prevent SSH egress, because a student can generate a new key. The control that keeps the container from becoming a cluster-management interface is the absence of Slurm and Munge inside it.

One rule follows from the namespace: **never gate behaviour on group membership inside the container.** A user namespace's GID map means `id -G` reports the primary GID plus `65534`. The group has no name there. The kernel still holds the real supplementary GIDs, so *access* works. Ask the kernel whether an operation is permitted (`[ -w "$ENVIRONMENT_ROOT" ]`), never whether a name is in a list.

### Why images use two shared storage roots

Apptainer mounts a SIF through `squashfuse_ll`, which has a **hardcoded ten-second mount timeout** that no Apptainer or environment variable governs. A multi-gigabyte SIF read from EFS under load can exceed it. Raising OOD's readiness budget does not change that mount timeout, so the launcher prefers a copy on Lustre and falls back to the authoritative copy on EFS.

Node-local copies do not fit the expected concurrency profile: many sessions can mount the same multi-gigabyte image on one node, while local temporary storage is limited and shared with the jobs themselves. Copying during launch would also turn a cache miss into many simultaneous copies.

The launcher therefore **selects** between a fast root and a canonical root. It never copies between them. Loss of the fast copy degrades start latency rather than making the image unavailable.

### Why a deploy refuses to run twice

`deploy-image.sh` publishes one built artifact and its two sidecars to both image roots. Nearly every rule in it follows from one fact: **a deployed name is permanent.** A committed `imagefile:` string identifies one exact build for as long as a sub-app names it. That holds only while the name is never reused.

So the script is deliberately **not** idempotent, and its header says so. It checks both roots before it writes either one, so a half-refused deploy is not a state it can leave behind. If any of the three files is already present, it refuses the whole deploy, including a completed deploy that you run again. The rest of its rules follow:

- **The canonical root is written first**, because it is the copy the launcher requires. A fast copy that arrives late puts every session on the size-mismatch fallback path. A failure at the fast root exits nonzero, but says plainly that the canonical deploy is complete. That is a slow session rather than no session.
- **The source checksum is checked before the first copy**, because the canonical root is the one root the launcher does not check for integrity. A bad file written there burns that name permanently.
- **The destination family comes from the metadata sidecar**, never from the artifact name, which carries a timestamp and a commit rather than a family. Requiring both sidecars also means that only `build-image.sh` output is publishable.
- **Modes are set explicitly**, on the files and on the family directory that a first deploy creates, rather than left to the deploying account's umask. Under `umask 077` that directory is `0700`, students cannot traverse it, and an image no student can read fails every session in the course silently, long after the deploy looked successful.
- **A sub-app's `imagefile:` line is printed, not set.** Putting a new image in front of students is a reviewed change. A file copy is not.

### Course environments and the three states

The environment is external to the image, under the course shared folder, at a tool-neutral root. The app's only runtime contract is a single interpreter beneath the resolved prefix. **Which interpreter counts is a fact about the app, not about the shared launch library.** `lc_classify_course_env` therefore takes it as an argument. Both current apps pass `bin/python`; an R app could pass `bin/R`. The argument is required rather than defaulted, so that one app cannot inherit another's assumption in silence: before it existed, an R prefix classified as **missing**, and the student got a degraded session complaining that there was no interpreter at `.../bin/python`.

One manager owns a prefix for its whole lifetime, so changing manager means recreating the prefix rather than mutating it. A uv-managed course installs its own standalone interpreter beneath the environment root. The prefix is therefore self-contained under either manager, and does not break when the image's Python changes. The prefix is created **at its final absolute path**, never built elsewhere and moved, because prefixes embed absolute paths in scripts and metadata.

A session classifies the environment into one of three states:

| State | Meaning | Behaviour |
|---|---|---|
| **ok** | prefix exists, interpreter runs, imports `ipykernel` | course kernel is generated and is the default |
| **missing** | prefix or interpreter absent | session **still starts**, image kernel only, logged loudly |
| **broken** | interpreter exists but does not run | same as missing, detected by probe rather than by file test |

The three states are a way of thinking about it, not three values in a variable. The host-side `COURSE_ENV_STATUS` carries only `ok` or `missing`. **broken** arrives there as `ok`, and the container catches it later. `lc_classify_course_env` in `ood/lib/launch-common.sh` writes the two values.

Only a path that **escapes the course folder** is fatal. That is a containment failure, not an absent environment, and it must never soften into a warning. Everything else degrades because a missing or broken dependency is recoverable, and a running session gives the user a way to diagnose it. JupyterLab therefore always generates a second, clearly-labelled kernel backed by the image's own interpreter, and `MultiKernelManager.default_kernel_name` makes the course kernel *preferred* rather than merely present.

Kernel names describe the **course**, not our implementation, and `write_kernel` in `ood/jupyterlab-ai/template/jupyterlab.script.sh` holds the exact strings. One part must survive any rewording: **"no course packages"**. That phrase is the entire control that prevents a student from quietly using a kernel with none of their course's libraries.

### Sub-apps and access control

Students only ever see gated sub-apps, so the name they read is the sub-app's `title:`. Files under `local/` are live, independent, and **do not inherit from each other**. That is why the copy source lives under `examples/`, where OOD does not publish it, and why a shared value must be updated in every live sub-app.

`enabledGroups` holds bare Canvas IDs **as quoted strings**, compared against IDs extracted from the user's group names by `scan(/^canvas(\d+)-\d+/)`. Comparing against the raw group-name list instead fails closed and silently: the sub-app becomes invisible to every enrolled student while continuing to work for administrators, who match on a different list. Automated rendering tests exercise the enrolled-user path separately.

Access Canvas IDs and the canonical filesystem Canvas ID are separate named values. Adding a cross-listed section's access group can therefore never change which folder is mounted.

Every value a template or `submit.yml.erb` reads must appear in the sub-app's `form:` list, because OOD passes only `form:`-listed attributes into the template context. An attribute set under `attributes:` but missing from `form:` renders as **nothing**, with no error. The test renderer reproduces that binding exactly, and exits rather than returning an empty string.

`cacheable: false` is on every sub-app because `cluster:` is computed per user, and a cached rendering can carry one user's access decision to another.

Server-side resource checks **reject** rather than clamp, because widget `min`/`max` are user-interface guidance and a hand-posted form arrives with anything. `--mem-per-cpu` must carry its unit, because Slurm reads a bare `4` as four megabytes. It is never multiplied by the CPU count.

### Non-obvious Apptainer behaviour

**The environment file is evaluated, not parsed.** Apptainer treats `--env-file` as a shell-ish script rather than plain `key=value` lines. An unquoted value containing a space is parsed as a command and aborts the launch outright:

```
COURSE_LABEL=Example Course
FATAL: while evaluating environment script: could not execute "Course"
```

`lc_write_env_file` therefore quotes and escapes values, and rejects `$` and newlines. An unexpanded `$` in an environment file is always a bug, because nothing expands it. Secrets never appear in `apptainer exec --env` arguments, because other users can see command lines through `/proc`. Only the path to the mode-`0600` file appears there.

**The container prompt is set twice.** Apptainer injects both `PS1="Apptainer> "` and `PROMPT_COMMAND='PS1="Apptainer> "; unset PROMPT_COMMAND'`. The second one is what students saw. bash *does* read `/etc/bash.bashrc` and set a normal prompt. It then runs `PROMPT_COMMAND` before it draws the first prompt, which overwrites that prompt and unsets itself, leaving no trace. `PS1` alone matters only for shells that read no rc files, such as dash. Both are unset before the server starts. The terminal shell is pinned to bash rather than inherited, because `jupyter_server_terminals` falls back to `which("sh")` when `SHELL` is unset.

**The build needs Apptainer's own bindir on `PATH`.** `apptainer build --fakeroot` shells out to `mksquashfs`, which lives beside the `apptainer` binary in the Spack view. Resolving that binary inside a command substitution keeps the activated environment away from the build itself. `mksquashfs` was then not findable, and the build failed on a compute node. `build-image.sh` prepends that one directory, for the build command alone.

### Deployment consequences of the symlink model

The parent apps are nested one level inside the repository, so the repository cannot be cloned into OOD's system-app directory directly. OOD scans `/var/www/ood/apps/sys/*` one level deep for a `manifest.yml`, and a monorepo presents none at that level. Each parent app is symlinked instead. Three consequences follow:

1. **The entire clone must be world-readable and world-traversable**, because OOD resolves the symlink as the student's own uid. `images/`, `scripts/`, every `local/*.yml.erb`, and `.git` with its full history are readable by every cluster user. **Never commit a credential, a token, or any private value here.** That is structural, not hygiene.
2. **Repository updates must preserve those permissions.** Git does not preserve general read permissions, so deployment tooling or procedure must verify that every required path remains readable and traversable.
3. **Updating the clone updates every symlinked app.** Deploy only reviewed revisions; a partial or in-progress repository state affects all apps at once.

---

## Compatibility risks

These unresolved dependencies can change the guarantees described above:

| Risk | Where it is explained |
|---|---|
| **`--underlay` is deprecated and will be removed**, and no replacement flag is identified | [Known expiry](design-ai-family.md#known-expiry-the---underlay-flag) |
| **What engages Claude Code's sandbox here is unknown**, and the answer decides whether our `denyRead` list can ever take effect | [The AI agents](design-ai-family.md#the-ai-agents-what-is-enforced-and-what-is-not) |

## What is deliberately not built

A future `jupyter-stacks` family. A registry, triggered or automated builds, or pull-based deployment. Cluster-side QOS and concurrency policy. Automated OAuth sign-in tests. Outbound network filtering. Any attempt to stop students running arbitrary code in their own writable directories.

Building, deploying and provisioning **are** scripted: `submit-build-image.sh`, `build-image.sh`, `deploy-image.sh`, `submit-provision-course-env.sh` and `provision-course-env.sh`. A person runs every one of them by hand, after deciding to run it. Scripting those steps removed the transcription errors, not the decision.
