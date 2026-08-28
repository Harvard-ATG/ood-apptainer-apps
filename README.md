# ood-apptainer-apps

Apptainer-based Open OnDemand interactive apps with preinstalled AI coding
agents, for HUIT OOD. Two parent apps — JupyterLab and code-server — serve
per-course sub-apps.

The design specification and implementation plans are maintained by Harvard ATG
outside this repository and are not tracked here.

These apps carry a wider blast radius than the standard ones: code-server
workspace trust is disabled, the student's real home is mounted read-write, and
either agent can read and transmit any unmasked file the student can read. They
are teaching environments, not suitable for regulated or sensitive research
data.

## Layout

| Path | Contents | Status |
|---|---|---|
| `ood/lib/launch-common.sh` | Canonical shared containment logic. **Edit here.** | present |
| `ood/<app>-ai/template/lib/launch-common.sh` | Vendored copy staged by OOD. Generated — do not edit. | present |
| `ood/<app>-ai/template/` | Host-side launch scripts (`before`/`script`/`after`) and in-container launchers | present |
| `ood/<app>-ai/` (`form.yml`, `submit.yml.erb`, sub-apps under `local/`) | Parent OOD app metadata and per-course sub-apps | present |
| `images/` | Apptainer definition files and initial course environment specs | present |
| `scripts/` | Build, provisioning, and maintenance scripts | present |
| `tests/` | Verification suite | present |

This repository holds the full build-out: the shared containment logic, the
host-side launch scripts, the in-container launchers, the Apptainer image
definitions and per-course environment specs (`images/`), the OOD-facing app
metadata and course sub-apps (`form.yml`, `submit.yml.erb`, `local/`), the
image and course-environment build/provisioning scripts (`scripts/`), and the
test suite that verifies all of it end to end against a stub image. Building
the two production images, provisioning the two courses' real environments,
and deploying to the OOD web nodes are administrative actions performed
outside this repository — see **Deployment** below.

## Tests

```bash
bash tests/run-all.sh
```

The suite has no dependencies beyond the OS, `ruby`, and optionally
`shellcheck`, so it runs both here and on a cluster compute node as part of
sign-in QA.

`tests/render.rb` stands in for OOD's template binding. It builds the `context`
double from the sub-app's `form:` list only, because that is what OOD actually
passes through — an attribute set under `attributes:` but omitted from `form:`
silently reaches templates as nothing.

`fixture_image` builds (or reuses a cached) stub image, which may be a `.sif` or
an Apptainer sandbox directory -- the fixture builds a sandbox directory
automatically where `/dev/fuse` is unavailable. It exports the resulting path as
`OOD_AI_TEST_IMAGE` for any test that wants it, but nothing else reads that
variable as an input.

`scripts/render-forms.sh` is the release gate for the course sub-apps: it renders
every sub-app and its parent app's templates and cross-checks the values that
must agree within a sub-app and across a course's two apps. Run it before
deploying; a nonzero exit means do not deploy.

```bash
scripts/render-forms.sh
```

None of this is a substitute for `scripts/smoke-test-checklist.md`, the manual
checklist covering everything the automated suite cannot reach from a stub
image or a login-node shell — real symlink resolution, Canvas group
membership, and deployment file permissions among them. Run it once per course
per term, and again after any image or launch-template change; see
**Deployment** below for when it fits into a release.

## After editing the shared library

```bash
bash scripts/sync-launch-lib.sh
bash tests/test-no-drift.sh
```

OOD stages only an app's `template/` directory, so the library must be vendored
into each app. The drift test fails the build if the copies diverge.

## Deployment

Building and deployment are manual and admin-driven. There is no registry,
CI/CD, or pull-based automation.

### The two clones

Two clones of this repository exist, for two different purposes, and they are
never the same checkout:

- **Build clone** — in an administrator's cluster home or another
  shared-filesystem path reachable from compute nodes. Used only to build
  images with `scripts/build-image.sh`.
- **Deploy clone** — at `/opt/harvard-atg/ood-apptainer-apps` on each OOD web
  node. This is the one the portal actually serves from. It is kept
  node-local rather than on a shared filesystem so form rendering does not
  depend on that filesystem being healthy.

STAGE and PROD are separate deploy clones on separate refs: **STAGE tracks
`main`**, while **PROD sits on a release tag**. Promoting a revision to PROD
is `git fetch && git checkout <tag>` followed by the permission pass below —
never a copy, and never a `git pull` on the tag branch.

### Deploying an image

After `scripts/build-image.sh` produces an immutable timestamp-and-commit SIF
and its SHA-256 sidecar:

1. Copy the SIF, checksum, and metadata files into
   `/shared/apptainerImages/jupyter-codeserver-ai/` **without overwriting** an
   existing path — deployed image filenames are immutable, so a name that
   already exists there means nothing needs to change.
2. Verify the copied checksum at that destination.
3. Copy the SIF to the matching path under
   `/scratch/apptainerImages/jupyter-codeserver-ai/` — the Lustre performance
   copy the launcher prefers when present and size-matched to the EFS copy.
4. Verify the checksum at that destination too. This is the only place a full
   checksum of the Lustre copy is taken; the launcher itself only compares
   byte size at launch time.

Skipping steps 3–4 is not a failure — sessions fall back to the EFS copy at a
logged performance cost — but it forfeits the reason the Lustre copy exists.

### Deploying the OOD apps

The two parent apps are nested one level inside this repository, so it cannot
be cloned directly into OOD's system-app directory the way a single-app repo
can: OOD scans `/var/www/ood/apps/sys/*` one level deep and registers each
directory containing a `manifest.yml`. Instead, each parent app directory is
symlinked into place:

```bash
ln -s /opt/harvard-atg/ood-apptainer-apps/ood/jupyterlab-ai \
  /var/www/ood/apps/sys/ood-jupyterlab-ai
ln -s /opt/harvard-atg/ood-apptainer-apps/ood/codeserver-ai \
  /var/www/ood/apps/sys/ood-codeserver-ai
```

**The symlink name becomes the app's directory identity and its URL segment.**
It is cheap to choose before the first student holds a bookmark to it and
costly to change afterward.

Three consequences follow from this model:

- **The entire clone must be world-traversable and world-readable.** OOD
  resolves the symlink as the student's own uid, so `/opt`,
  `/opt/harvard-atg`, the repository directory, and every app file need
  `o+x`/`o+r` — mode `0755` on directories. This is why **no credential,
  token, or private value may ever be committed to this repository**:
  committing one publishes it to every user on the cluster, `.git` history
  included. Because `git pull` does not preserve permissions beyond the
  executable bit, new files land with whatever mode the pulling
  administrator's umask allows — a pull done with `umask 077` creates mode
  `0600` files, silently removing student read access, with no error
  surfaced anywhere. Every deployment pull must therefore either be run under
  an explicit `umask 022`, or be followed by `chmod -R o+rX` as the
  documented final step. Setgid on the directory does not substitute for
  this: it governs group ownership, not the other-read bit.
- **A pull is a deployment, for both apps at once.** The symlink model gives
  instant propagation, which is the point of the model, but it also means an
  in-progress commit on the pulled ref reaches students the instant the
  deploy clone updates. This is exactly why STAGE tracks `main` while PROD
  sits on a release tag, rather than both tracking the same branch.
- **Environment state is not part of a promoted revision.** Two paths are
  environment state, not repository content, so checking out a new tag on
  PROD does not create either of them — each new environment (a new web node,
  a rebuilt cluster) needs both created independently:
  - `/scratch/apptainerImages`, owned `root:ondemand-admins-1025174` mode
    `0775`, matching the EFS root. Without it every session silently takes
    the slower EFS path — the launcher logs this, but nothing else surfaces
    it.
  - Each in-scope course's shared folder (the parent of that course's
    `environment_root`).

Confirm deployed files, ownership, and app visibility — `scripts/smoke-test-checklist.md`,
**OOD and access** group — before smoke testing the rest.

### Taking one sub-app out of service

Disabling a single course's sub-app for a maintenance window is a deliberate,
temporary edit to `ood/<app>-ai/local/<course>.yml.erb` **made in place on the
PROD deploy clone**, reverted with:

```bash
git checkout -- ood/<app>-ai/local/<course>.yml.erb
```

Because the symlink model makes the working tree live, this takes effect
immediately and needs no tag, commit, or pull — routing a thirty-minute
disable through a release cycle would be heavy enough that the step gets
skipped in practice, which is worse than a briefly dirty worktree. A dirty
worktree during an announced maintenance window is therefore expected; one
still dirty afterward is a defect the smoke checklist's **OOD and access**
group is meant to catch (see item 7 there).

To take a whole parent app out of service instead of a single course, remove
its symlink from `/var/www/ood/apps/sys/` — this is instant and reversible,
but it affects every course on that app, not just one.
