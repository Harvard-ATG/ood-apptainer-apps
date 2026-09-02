# The jupyter-codeserver-ai family

Everything here is specific to the AI-enabled apps and their image family: the two CLIs they bundle are OpenAI's Codex and Anthropic's Claude Code. An app that does not bundle the agents inherits none of it. The shared architecture they sit on is [`docs/design.md`](design.md).

## Why the two images run one recipe

Both images stage in and run the *same recipe* to install the AI surface. Nothing in the filesystem makes them agree, because they share no base layer, so `tests/test-image-parity.sh` asserts the result: the same CLI versions, and the same checksums for every governance file. A bug that breaks *both* images identically stays invisible to it, so the suite requires real output from each side before it compares.

## What the agents add to the risk

[The shared architecture](design.md#containment-what-it-protects-and-what-it-does-not) accepts two things: a real home mounted read-write, and unrestricted outbound HTTPS. An agent acts on the student's behalf and at machine speed, which widens that considerably.

Code-server workspace trust is disabled, because the Claude Code extension does not load at all without it. Either agent can read and transmit any unmasked file the student can read: `.aws`, `.gnupg`, `.netrc`, research files, the persistent GitHub token. **An app built without the agents inherits none of this**. That is the reason for keeping the variants separate rather than adding the CLIs to every image.

## The agents' own sandboxes, and the flags that keep them working

Both CLIs sandbox their own filesystem access with bubblewrap, *inside* our container: a second, independent sandbox nested in ours. This is defense in depth, not a replacement for [the shared architecture's containment](design.md#containment-what-it-protects-and-what-it-does-not). It gives the student a tool to restrict what the agent itself can read or write inside that boundary.

```text
Compute node — Slurm job
└── Apptainer container (student UID)      containment boundary, design.md
    └── bwrap sandbox (per agent)          defense in depth, this doc
        └── Codex or Claude Code process
```

Two unrelated Apptainer flags make that sandbox work. Neither is a containment control. Codex bundles its own bwrap binary, while Claude Code uses the image's `/usr/bin/bwrap`, so their failures differ.

**`--underlay`.** Apptainer's default overlay leaves the container root unbindable, and that property survives into the namespace bubblewrap makes for itself. bwrap's first move is to bind the old root onto the new one, the kernel refuses a bind whose source is unbindable, and it dies:

```
bwrap: Can't bind mount /oldroot/ on /newroot/: Invalid argument
```

`--underlay` assembles the root as a bindable tmpfs instead. Without it, a bare `apptainer exec <sif> codex` fails identically.

**`-B /dev/full:/dev/full`.** This repairs what `--containall` removes. Codex's workspace-write sandbox binds `/dev/full` while it assembles itself, and bwrap cannot bind a source that does not exist.

**The two are not alternatives.** Without `--underlay`, bwrap dies before it reaches `/dev`. A minimal bwrap probe also misses the `/dev/full` requirement. Only the complete Codex sandbox exercises it.

### How the two agents fail differently

| Agent | When it fails | How it looks |
|---|---|---|
| **Codex** | session start, fatally, every time | refuses to start. It sandboxes even its read of `AGENTS.md` |
| **Claude Code** | first Bash tool call | a refusal naming the bwrap error and pointing at `/sandbox` |

Opening Claude Code is not a sufficient sandbox test because it does not invoke bwrap until the first Bash tool call.

### Codex's policy file requires an enforcing sandbox

`images/.../codex/requirements.toml` sets the profile every session starts in:

```toml
default_permissions = ":workspace"

[allowed_permission_profiles]
":workspace" = true
":read-only" = true

[permissions.filesystem]
deny_read = [
  "~/.ssh",
  "~/.config/gh",
  "~/.claude",
  "~/.aws",
  "~/.gnupg",
  "~/.netrc",
]
```

The runtime derives the allowed modes from the denials, so the `deny_read` block makes an enforcing sandbox mandatory. A non-enforcing profile beside that block is rejected as an invalid `sandbox_mode`.

The Codex policy is therefore satisfiable only while `--underlay` is in the launcher. `tests/test-containment.sh` asserts the flag in the real argv, so that dependency fails in CI rather than in a student's session.

### `--underlay` is deprecated, and removal breaks both agents

Apptainer **[deprecated `--underlay` and will remove it](https://apptainer.org/docs/admin/main/configfiles.html#supplemental-filesystems).** The deprecation warning it prints into every session log is expected, not a fault. When an upgrade drops the flag, both agents lose their sandbox: Codex stops starting at all, and Claude Code starts refusing Bash tool calls. No replacement flag is identified yet.

This has already happened once, before `--underlay` was found: Codex's bundled bwrap failed to `pivot_root` inside this cluster's unprivileged Apptainer, and every profile that needs the sandbox helper crashed instead of starting. The fallback that shipped then is still the one to reach for:

```toml
# Working state, requires a functioning sandbox helper:
# default_permissions = ":workspace"
# [allowed_permission_profiles]
# ":workspace" = true
# ":read-only" = true
# [permissions.filesystem]
# deny_read = ["~/.ssh", "~/.config/gh", "~/.claude", "~/.aws", "~/.gnupg", "~/.netrc"]

# Fallback, when the sandbox helper cannot run at all:
default_permissions = ":danger-full-access"

[allowed_permission_profiles]
# ":workspace" and ":read-only" both need the helper. Leaving either allowed
# hands a student a bwrap crash instead of a restricted session.
":danger-full-access" = true

# The [permissions.filesystem] deny_read block is removed entirely, not just
# emptied. An enforcing sandbox_mode is derived from that block, so it cannot
# coexist with a profile that has no working sandbox to enforce it in.
```

That gives up Codex's own filesystem sandbox, not the container mount boundary or the `~/.ssh` mask, both of which stay in force regardless. `allowed_approval_policies` still governs approval prompts, so it becomes the sole remaining interactive restraint rather than one layer among several.

Claude Code has no policy file to relax the same way. [Its own documentation](https://code.claude.com/docs/en/sandboxing#get-started) describes two different defaults, and which one applies depends on *why* the sandbox fails:

- Bubblewrap or `socat` missing entirely: Claude Code warns and falls back to running commands unsandboxed, unless `sandbox.failIfUnavailable` is set to `true`. This is a startup dependency check, and does not apply here, because bubblewrap is present in this image.
- Bubblewrap present but a specific command's sandbox setup fails at runtime, such as the bind-mount crash this section describes: Anthropic's documentation offers configuration fixes for the failures it covers, not an automatic silent fallback.

The second case is the one measured on this cluster, and it matches the refusal in the table above, not a silent fallback. Whether that measurement still holds is tied to [the open question below](#the-claude-governance-file-is-not-enforced): the policy that actually governs this today is a remote one this repository does not control.

## Version pinning and configuration conventions

Both CLIs are installed system-wide at versions pinned in `versions.env`, and students authenticate individually. The minimum versions are security and configuration requirements: older Codex releases ignore `allowed_permission_profiles`, and older Claude Code releases do not merge `env` per variable across administrative sources.

Configuration lives at the **default** locations `~/.claude` and `~/.codex`. Tools and extensions can therefore find it by convention, and the host and container agree on its location.

## The Claude governance file is not enforced

In the current managed-account configuration, Claude Code selects managed settings first-wins, and the higher-priority remote policy causes `/etc/claude-code/managed-settings.json` to be skipped in its entirety. Treat that file as a statement of intent, not as a mitigation. `DISABLE_AUTOUPDATER` remains effective because the launcher also sets it as a process environment variable and the image is read-only.

Containment is unaffected because the managed file was always defence in depth.

**One open question remains.** Claude Code still starts a bwrap sandbox on its first Bash tool call, but whether the client default or remote policy enables it is unknown. The answer determines whether the image's `denyRead` list can take effect.

## Suppressing the Claude extension upgrade attempt

Whenever the installed extension sorts semver-lower than the CLI, the Claude Code CLI tries to upgrade its code-server extension. That cannot succeed because `--extensions-dir` is image-owned and read-only.

`CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1` suppresses that upgrade attempt. Two consequences follow:

- **Keeping `CLAUDE_EXT_VERSION` and `CLAUDE_CODE_VERSION` in step is now a maintenance invariant**. Any drift between them reproduces this on every launch. They are pinned together in `versions.env` for that reason.
- JupyterLab gets `DISABLE_AUTOUPDATER` only. Its terminal sets no `TERM_PROGRAM` and writes no IDE lockfile, so the CLI never reaches the extension-install path there.

## Why Codex authentication is awkward and Claude's is not

Claude Code accepts a code pasted back into the terminal, so its authentication flow does not require the browser to reach the compute node. Codex's default flow registers a callback on compute-node `localhost`. From the user's browser, `localhost` is the user's own machine, so the callback cannot reach Codex.

`codex login --device-auth` avoids the callback and is the supported path here. Device-code authentication can be disabled by workspace policy, so its availability is not controlled by this repository.

## An extension can be the missing half of a launcher setting

An extension request can sound cosmetic. Two current extensions are not:

- **`ms-python.python`** is the extension that *reads* `python.defaultInterpreterPath`, which the launcher generates per session. Without it, that setting is inert and code-server never selects the course interpreter. The launcher's half of the work looks correct and achieves nothing.
- **`jupyterlab_widgets`** is the front-end half of `ipywidgets`. Both course environments list `ipywidgets` for the kernel side. Without this package in the image, any notebook that uses widgets renders nothing at all.

The kernel half belongs to the course environment, the front-end half belongs to the image, and a course cannot fix the second half itself. Any app that pairs a server-side setting with a front-end extension inherits this shape, whatever the extension is.

## Two packaging traps in the extension pins

Both constraints are recorded in `versions.env`. The AI extensions publish **per-platform** builds, so the definition must select `linux-<arch>` explicitly. The editor extensions publish **universal** builds and must be fetched unqualified.

The second trap is a dependency ceiling. `notebook-intelligence` declares an open-ended `mcp` dependency but imports an API removed in mcp 2.x. The `mcp<2` ceiling remains necessary until upstream bounds its dependency.
