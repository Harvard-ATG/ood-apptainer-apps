# Sign-in and deployment QA checklist

Run once per course per term, and again after any change to an image, a launch
template, or the shared containment library. This is a manual procedure: it exercises
things no automated test can reach from a stub image or a login-node shell — symlink
resolution on a real web node, group membership for a cross-listed section, and
whether a `git pull` silently stripped world-read off every file.

For each item, record a result (`pass`, `fail`, or `n/a` with a reason) and the date it
was checked. Use one row per run; keep prior runs rather than overwriting them, so a
regression shows up as a row that used to pass.

Three of these carry a warning explaining why they are checked exactly this way,
because each records a failure that has actually happened in this app family. Do not
shortcut them:

> **Sub-app visibility must be verified with a non-admin enrolled account.**
> Administrators match on a different group list than students do, so administrator
> visibility proves nothing about student visibility. Comparing `enabledGroups`
> against the raw group-name list instead of the extracted course IDs has happened
> twice in this app family: it fails closed and silently, leaving the sub-app
> invisible to every enrolled student while it keeps working correctly for
> administrators.

> **Containment items must be checked against the real, deployed image.** A stub
> image never contained Slurm binaries, Slurm configuration, or Munge sockets, so the
> automated containment suite's equivalent assertion cannot fail for any change to the
> launcher and proves nothing about what actually ships.

> **After any deployment pull, run `find . ! -perm -o+r`.** `git pull` does not
> preserve permissions beyond the executable bit; new files are created against the
> pulling administrator's umask. A pull performed with `umask 077` silently removes
> student read access, and the app then fails with no error surfaced anywhere.

---

## OOD and access

| # | Check | Result | Date |
|---|---|---|---|
| 0 | Confirm `ruby` and `jq` are on `PATH` on the node you are running from. Both are hard dependencies of `scripts/render-forms.sh` and of the test suite; `jq` is also required by `scripts/build-course-env.sh`. The gate reports which one is missing and exits nonzero, so this is a five-second check that saves reading its output twice. | | |
| 1 | Render all four sub-app forms (`scripts/render-forms.sh`) and verify access ID, canonical filesystem ID, image, environment, and resource values. | | |
| 2 | `scripts/render-forms.sh` exits zero and its final line reports **four** sub-app(s) checked, zero failures. | | |
| 3 | Verify every cross-listed population can see the intended app, checked with a **non-admin enrolled account**. Administrator visibility proves nothing about student visibility, because the two match on different group lists. | | |
| 4 | Verify an unrelated student (enrolled in neither course) cannot see or launch it. | | |
| 5 | Confirm every sub-app sets `cacheable: false`, and that no attribute consumed by `submit.yml.erb` or a launch template is missing from the `form` list. | | |
| 6 | Confirm the deployed system-app files match the intended repository revision, and that the PROD deploy clone is on the intended release tag rather than tracking `main`. | | |
| 7 | Confirm the PROD deploy clone has no uncommitted modifications. A dirty worktree is expected only during an announced maintenance window; one left behind afterward means a sub-app is still disabled or a temporary edit was never reverted. | | |
| 8 | Confirm both app symlinks resolve, and that `/opt`, `/opt/harvard-atg`, the repository directory, and the app files are traversable and readable as an **ordinary student account** — not merely as an administrator. | | |
| 9 | **After any deployment pull**, confirm no file landed without world-read: run `find . ! -perm -o+r` from the deploy clone root and confirm it reports nothing. This is the umask failure mode, and it produces no error anywhere else. | | |
| 10 | Confirm the Slurm job name (`build-course-env-<course>`) and log path (`<scratch>/provisioning/<course>/build.log`) used by `scripts/build-course-env.sh` match local operations conventions. Neither the design nor the implementation plan specified a convention here — this plan invented one because something had to be picked — so this is the point to align it with how this cluster's other Slurm jobs are named and logged, before anyone starts relying on the current values. It is two string literals in `scripts/build-course-env.sh`; changing it later, once run logs and muscle memory depend on it, is not as cheap. | | |

## Sign-in and tooling

| # | Check | Result | Date |
|---|---|---|---|
| 1 | Launch each app for each course. | | |
| 2 | Complete the Claude Code login flow with a representative account. **Copy the sign-in link into the browser — do NOT click code-server's "Open" button**, which routes it through an external-URI opener that rewrites `localhost` and has been observed to break this flow. | | |
| 2a | Complete the Codex login with `codex login --device-auth`. **The default `codex login` cannot work from a compute node** — it registers `redirect_uri=http://localhost:1455/auth/callback`, and that `localhost` is the student's own laptop. Device auth needs no callback. | | |
| 3 | Restart the jobs and confirm both credentials persist in their isolated directories. | | |
| 4 | Confirm all five Open VSX extensions load and workspace trust does not block them: `Anthropic.claude-code`, `openai.chatgpt`, `ms-python.python`, `ms-toolsai.jupyter`, `ms-toolsai.jupyter-renderers`. | | |
| 5 | Confirm both CLIs are on `PATH` in both integrated terminals. | | |
| 6 | Record bundled CLI versions in both Open VSX extensions, and test their effective policy behavior separately from the system CLIs. | | |
| 7 | Confirm CLI update checks are disabled. | | |

## Policy and containment

| # | Check | Result | Date |
|---|---|---|---|
| 1 | Inspect Claude `/status` and record which managed source won. | | |
| 2 | Confirm Claude's sandbox is engaged, **and make at least one Bash tool call to prove it**. Claude Code bootstraps its sandbox on first Bash use, not at session start, so a session where nobody ran a Bash call proves nothing. A refusal naming `bwrap: Can't bind mount /oldroot/ on /newroot/` and pointing at `/sandbox` means the launcher's `--underlay` is missing. Record which managed source supplied the sandbox settings — on an EDU login ours is skipped, so this also answers whether `denyRead` can take effect at all. | | |
| 2a | Record Claude `/status` shows **no** IDE error. A red `code --force --install-extension anthropic.claude-code` error means `CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1` is not reaching the session, or `CLAUDE_EXT_VERSION` and `CLAUDE_CODE_VERSION` have drifted apart in `versions.env`. | | |
| 3 | Inspect Codex's effective requirements after login. It must start a session at all, and `/status` must report an **enforcing** sandbox consistent with `default_permissions = ":workspace"` — record the exact string. **`No Sandbox (Ask for approval)` is now a failure, not the expected result**: that was the interim `:danger-full-access` state, and `--underlay` reversed it. `requirements.toml` allows only `:workspace` and `:read-only`, and its `deny_read` block cannot coexist with a non-enforcing mode, so a non-enforcing Codex here means the sandbox is silently broken. Confirm it also still prompts for approval. | | |
| 3a | Confirm the cross-agent read denial is in effect, in both directions: from **Codex**, reading `~/.claude` must be denied; from **Claude Code**, reading `~/.codex` must be denied. Each agent is denied the **other** agent's credentials, never its own — denying an agent its own store would break its sign-in rather than protect anything. On an EDU login the Claude half depends on which managed source won (item 2), so record that result before reading this one. | | |
| 4 | Confirm `.ssh` is empty and masked. | | |
| 5 | Confirm Slurm binaries, configuration, and Munge are absent. **Check this against the real, deployed image** — a stub image never contained them, so the equivalent automated test in the containment suite cannot fail for any change to the launcher and proves nothing about the shipped image. | | |
| 6 | Confirm no other course's shared folder is reachable. | | |
| 7 | Confirm configured `hostfs` and system bind paths are absent. | | |
| 8 | Attempt launch with hostile bind and environment variables and confirm they do not reach Apptainer or the container. | | |
| 9 | Confirm connection secrets do not appear in process command lines, and that the per-job environment file is mode `0600`. | | |
| 10 | Confirm `PYTHONNOUSERSITE=1` and that host `~/.local` packages are not importable. | | |

## Launch and lifecycle

| # | Check | Result | Date |
|---|---|---|---|
| 1 | Confirm the OOD staged session directory, the in-container launcher, and every launch-generated configuration file resolve inside the container under `--containall`. | | |
| 2 | Confirm the in-container launcher is mode `0755` after staging. | | |
| 3 | Confirm the session launches from `/scratch/apptainerImages` when the Lustre copy is present and its size matches EFS. | | |
| 4 | Confirm the fallback by renaming the Lustre copy: the session must still start from `/shared/apptainerImages` and must log that it took the slower path. | | |
| 5 | Confirm a truncated Lustre copy is rejected on size mismatch and falls back rather than launching from it. | | |
| 6 | Confirm the launcher never writes to `/scratch/apptainerImages`. | | |
| 7 | Confirm `HOME` inside the container is the student's real home and is writable, and that it matches the host-side value from `before.sh.erb`. A container `HOME` pointing anywhere else means `--home` is missing or malformed, which an environment-file entry cannot compensate for. | | |
| 8 | Confirm the server is the container's first process and that `scancel` terminates the session promptly rather than waiting for walltime. | | |
| 9 | Confirm a deliberately broken launch surfaces as a failed session with a usable diagnostic, not as a session that appears to start and then does nothing. | | |
| 10 | Confirm two concurrent sessions by different users on the same node do not collide on any host path the launcher writes. | | |
| 11 | Record image mount and server start times from both image roots under representative CS1090A concurrency. | | |

## Environment and workflow

| # | Check | Result | Date |
|---|---|---|---|
| 1 | Confirm students see `Python 3 (<COURSE LABEL>)` — e.g. `Python 3 (APMTH 115)`, taken from the sub-app's `course_label` — backed by the validated target of `<environment_root>/default`, that it is the kernel a new notebook opens with, and that it reports the course's configured Python version. | | |
| 2 | Confirm the secondary `Python 3 (System Default — no course packages)` kernel is present, is never the default while the course kernel exists, and cannot import course packages. | | |
| 3 | Confirm a session still starts with `<environment_root>/default` **renamed away**: the server comes up, the image kernel is the only kernel and becomes the default, and the session log states why. | | |
| 4 | Confirm the same degraded behavior for a `default` whose `bin/python` exists but does not run (present on disk, not executable, or executes and fails): server still comes up, image kernel is the only kernel and becomes the default, session log states why. | | |
| 5 | Confirm an `<environment_root>` symlink **escaping the course folder** still fails the launch outright — this must be treated as fatal, not as another case of the degraded path above. A containment failure must never soften into a warning. | | |
| 6 | If `<environment_root>/staging` exists, confirm eligible staff also see `Python 3 (<COURSE LABEL> — STAGING)` and students do not. | | |
| 7 | Confirm code-server selects the same `<COURSE_ENV>/bin/python`. The launcher writes `python.defaultInterpreterPath`; `ms-python.python` is what reads it, so this is an end-to-end check of both halves. | | |
| 8 | Confirm a key present **only** in the image's own `/etc/code-server/settings.json` (never generated by the launcher) reaches a live code-server session's effective settings. This is the assertion that the launcher merges the image's seed with its own generated keys rather than overwriting the seed outright — a launcher that copies the seed and then rewrites the same path with a heredoc would still show the generated keys (workspace trust among them) while silently discarding every image-level one, and the session would look correct. | | |
| 9 | Import representative compiled packages in both app images. | | |
| 9a | Confirm `ipywidgets` output renders in JupyterLab. Both halves are needed and they live in different places: the kernel half comes from the course environment, the front-end half (`jupyterlab_widgets`) from the image. | | |
| 10 | For a uv-managed course, confirm the prefix's base interpreter resolves beneath `environment_root` rather than into the image. | | |
| 11 | Confirm staff can modify a test file inside the environment and a student cannot. | | |
| 12 | Confirm the documented manager-specific maintenance works from an integrated terminal without using the other manager against the prefix. | | |
| 13 | Confirm the fixed environment root and any `default` or `staging` symlink resolve beneath the canonical course folder; reject an escaping or broken target. | | |
| 14 | Confirm `gh auth login`, HTTPS Git push, and token persistence across jobs. | | |
| 15 | Confirm simultaneous sessions by one user do not share job-local state or sockets. | | |

## Resource behavior

| # | Check | Result | Date |
|---|---|---|---|
| 1 | Confirm server-side validation rejects out-of-range CPU and walltime values. | | |
| 2 | Confirm Slurm receives `--mem-per-cpu=4G`, including the unit. | | |
| 3 | Measure JupyterLab and code-server separately with representative course workloads. | | |
| 4 | Repeat memory testing when cluster cgroup memory enforcement is enabled. | | |
