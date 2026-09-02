# The jupyter-codeserver-ai family

Everything here is true only of today's two apps and the image family behind them. An app that does not bundle the agents inherits none of it. The platform they sit on is [`docs/design.md`](design.md).

## Why the two images run one recipe

Both images stage in and run the *same recipe* to install the AI surface. Nothing in the filesystem makes them agree, because they share no base layer, so `tests/test-image-parity.sh` asserts the result: the same CLI versions, and the same checksums for every governance file. A bug that breaks *both* images identically stays invisible to it, so the suite requires real output from each side before it compares.

## What the agents add to the risk

[The platform](design.md#containment-what-it-protects-and-what-it-does-not) accepts two things: a real home mounted read-write, and unrestricted outbound HTTPS. An agent acts on the student's behalf and at machine speed, which widens that considerably.

Code-server workspace trust is disabled, because the Claude Code extension does not load at all without it. Either agent can read and transmit any unmasked file the student can read: `.aws`, `.gnupg`, `.netrc`, research files, the persistent GitHub token. **An app built without the agents inherits none of this**. That is the reason for keeping the variants separate rather than adding the CLIs to every image.

## The agents' own sandboxes, and the flags that keep them working

Both CLIs sandbox their own filesystem access with bubblewrap, *inside* our container. That is a second, independent sandbox nested in ours, and two unrelated flags were needed to make it work at all. Neither flag is a containment control. Both are required. The two agents do not even share a bwrap binary: Codex bundles its own, and Claude Code uses the image's `/usr/bin/bwrap`, which is part of why their failures differ.

**`--underlay`.** Apptainer's default overlay leaves the container root unbindable, and that property survives into the namespace bubblewrap makes for itself. bwrap's first move is to bind the old root onto the new one, the kernel refuses a bind whose source is unbindable, and it dies:

```
bwrap: Can't bind mount /oldroot/ on /newroot/: Invalid argument
```

`--underlay` assembles the root as a bindable tmpfs instead. Our launch flags do not cause this. A bare `apptainer exec <sif> codex` fails identically.

**`-B /dev/full:/dev/full`.** This repairs what `--containall` removes. `--containall` replaces `/dev` with a minimal fake one, and measured against this image, the only entries it drops are `core` and `full`. Codex's real workspace-write sandbox binds `/dev/full` while it assembles itself, and bwrap cannot bind a source that does not exist.

**The two are not alternatives.** If you drop `--underlay` and keep the `/dev/full` bind, you get the original failure unchanged. bwrap dies at its first bind and never reaches `/dev` at all. The `/dev/full` requirement also appears only under the complete flag set. A minimal `bwrap` probe passes without it and tells you nothing.

### How the two agents fail differently

| Agent | When it fails | How it looks |
|---|---|---|
| **Codex** | session start, fatally, every time | refuses to start. It sandboxes even its read of `AGENTS.md` |
| **Claude Code** | first Bash tool call | a refusal naming the bwrap error and pointing at `/sandbox` |

**"Claude seemed fine" usually means that nobody made a Bash call yet**, not that its sandbox is inert. A smoke test that opens Claude Code and reads its `/status` passes while the sandbox is entirely broken.

### A policy file now depends on a launch flag

Nothing about either file suggests this coupling. `images/.../codex/requirements.toml` sets `default_permissions = ":workspace"` and allows only `:workspace` and `:read-only`. The runtime derives the allowed set of modes from the denials themselves, so the `deny_read` block makes an enforcing sandbox mandatory. A non-enforcing profile beside that block is rejected at startup as an invalid `sandbox_mode`.

The Codex policy is therefore satisfiable only while `--underlay` is in the launcher. `tests/test-containment.sh` asserts the flag in the real argv, so that dependency fails in CI rather than in a student's session.

An interim state shipped briefly, with the profile at `:danger-full-access` and no `deny_read` block. Any document that describes `/status` as reporting `No Sandbox (Ask for approval)` predates `--underlay` and is wrong.

### Known expiry: the `--underlay` flag

Apptainer **deprecated `--underlay` and will remove it.** The deprecation warning it prints into every session log is expected, not a fault. When an upgrade drops the flag, both agents lose their sandbox: Codex stops starting at all, and Claude Code starts refusing Bash tool calls. No replacement flag is identified yet.

## The AI agents: what is enforced and what is not

Both CLIs are installed system-wide at pinned versions, and students authenticate individually. Two version floors are required rather than cosmetic. Codex below 0.138.0 *ignores* `allowed_permission_profiles`, which removes a restriction rather than degrading it. Claude Code below 2.1.223 does not merge `env` per variable across administrative sources.

Configuration lives at the **default** locations `~/.claude` and `~/.codex`. Bespoke paths were tried first and abandoned. The defaults give three things. Any tool, extension, plugin or skill that finds its configuration by convention works with no special-casing. The host and the container agree. A clean reset is one line a student can be told.

**The Claude governance file is inert on an EDU login.** We measured this on a live session. Claude Code selects managed settings **first-wins**, ranked remote, then MDM, then file. The remote enterprise policy delivers policy keys, so `/etc/claude-code/managed-settings.json` is skipped in its entirety, and `/status` says so explicitly. Treat every key in that file as not in effect. `DISABLE_AUTOUPDATER` is the exception. It survives only because the launcher also sets it as a real environment variable, and because the read-only image prevents in-place updates on its own.

The fix is server-side and not ours. `managedSourcesBehavior: "merge"` must be set in the **remote** policy. By design that key must live in the highest-priority source, so a lower source cannot opt itself into merging. Until then, treat that file as a statement of intent, and do not cite it as a mitigation. Containment is unaffected, because this was always defence in depth.

**One open question follows.** The managed file sets `sandbox.enabled: true`, and on an EDU login that key does not apply. Claude Code was still observed bootstrapping a bwrap sandbox on its first Bash tool call, and failing there before `--underlay` was added. Some route other than our file engages its sandbox: either the client's own default, or the remote enterprise policy. Which one is still unknown, and it decides whether our `denyRead` list can ever take effect. Settle it with a live `/status` the next time someone is in a session.

### The workaround: the process environment outranks everything

The managed file can contribute nothing, so **the launcher also exports anything that must hold**. No source-precedence rule outranks a process environment variable, which makes it the only reliable image-level default here. Both in-container launchers do this, and the duplication with `managed-settings.json` is deliberate rather than redundant.

One case forced this into use. Every code-server session showed a red IDE error from `code --force --install-extension anthropic.claude-code`. The image already installs that extension, and the CLI does find it. But its test is an **upgrade** test, not a presence test, so it reinstalls whenever the installed version sorts semver-lower than the CLI's own. That reinstall can never succeed, because `--extensions-dir` points at an image-owned directory the session cannot write. It is a failed upgrade, not a failed detection, so no amount of reinstalling fixes it.

`CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1` suppresses it. The equivalent configuration file lives in the student's writable home, so the environment variable is the only usable image default. Two consequences follow:

- **Keeping `CLAUDE_EXT_VERSION` and `CLAUDE_CODE_VERSION` in step is now a maintenance invariant**. Any drift between them reproduces this on every launch. They are pinned together in `versions.env` for that reason.
- JupyterLab gets `DISABLE_AUTOUPDATER` only. Its terminal sets no `TERM_PROGRAM` and writes no IDE lockfile, so the CLI never reaches the extension-install path there.

### Why Codex authentication is awkward and Claude's is not

Claude Code prints a URL and takes a **code pasted back** into the terminal, so nothing has to reach the compute node. Codex's default flow starts a listener on `localhost:1455` and registers `http://localhost:1455/auth/callback` as the redirect. From a browser on a laptop, that `localhost` is the laptop. The code arrives at a machine that is not listening, and the login never completes. Changing the port does not help. The wrong thing is the *host*.

`codex login --device-auth` exists in the pinned version and avoids the callback entirely. It was **checked from a real session on 2026-08-28 and worked**, and it is the supported path here. One caveat survives that test: a ChatGPT workspace-admin toggle can gate device-code auth, and one Harvard account was used for the check. If students are on a managed ChatGPT Edu workspace with different permissions than that account, check it again with a student-type account before term.

A related trap is easy to confuse with this one. In code-server's integrated terminal, a URL printed by either CLI raises a "Do you want code-server to open the external website?" popup. Clicking **Open** routes the URL through code-server's external-URI opener, the layer that rewrites `localhost` URLs for port forwarding, rather than handing it to the browser untouched. We observed that this breaks the Claude sign-in, and copy-paste avoids it. The two failures look identical to a student and have nothing in common: the Codex one is a `redirect_uri` fixed in the authorize URL before a browser is ever involved.

## An extension can be the missing half of a launcher setting

An extension request can sound cosmetic. Two of the ones these courses asked for are not:

- **`ms-python.python`** is the extension that *reads* `python.defaultInterpreterPath`, which the launcher generates per session. Without it, that setting is inert and code-server never selects the course interpreter. The launcher's half of the work looks correct and achieves nothing.
- **`jupyterlab_widgets`** is the front-end half of `ipywidgets`. Both course environments list `ipywidgets` for the kernel side. Without this package in the image, any notebook that uses widgets renders nothing at all.

The kernel half belongs to the course environment, the front-end half belongs to the image, and a course cannot fix the second half itself. Any app that pairs a server-side setting with a front-end extension inherits this shape, whatever the extension is.

## Two packaging traps in the extension pins

Both are recorded in `versions.env`. The five Open VSX extensions divide into two groups. The two AI extensions publish **per-platform** builds only, so the definition must select `linux-<arch>` explicitly. An unqualified request resolves to `alpine-arm64`, a musl build that cannot run in these glibc images. The three editor extensions publish a single **universal** build and must be fetched unqualified.

The second trap is a dependency ceiling. `notebook-intelligence` 5.3.1 declares `mcp>=1.28.1` with no upper bound, but imports `mcp.server.fastmcp`, which mcp 2.x removed. Left unconstrained, pip resolves mcp 2.x and the extension cannot be imported at all: JupyterLab starts and the extension is dead, with nothing to see. The `mcp<2` ceiling is ours to carry until upstream bounds its own dependency.
