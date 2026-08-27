# ood-apptainer-apps

Apptainer-based Open OnDemand interactive apps with preinstalled AI coding
agents, for Harvard ATG. Two parent apps — JupyterLab and code-server — serve
per-course sub-apps.

**Design:** maintained by Harvard ATG outside this repository
**Implementation plans:** maintained by Harvard ATG outside this repository

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
| `ood/<app>-ai/` (`form.yml`, `submit.yml.erb`, sub-apps under `local/`) | Parent OOD app metadata and per-course sub-apps | forthcoming — Plan 3 |
| `images/` | Apptainer definition files and initial course environment specs | forthcoming — Plan 2 |
| `scripts/` | Build, provisioning, and maintenance scripts | present, growing — image build scripts arrive in Plan 2 |
| `tests/` | Verification suite | present |

This repository currently holds Plan 1: the shared containment logic, the
host-side launch scripts, the in-container launchers, and the test suite that
verifies the containment contract end to end against a stub image. The
Apptainer image definitions (`images/`) and the OOD-facing app metadata and
course sub-apps (`form.yml`, `submit.yml.erb`, `local/`) do not exist yet —
they land in Plans 2 and 3, per
the implementation plan maintained outside this repository.

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

Images used by tests are taken from `OOD_AI_TEST_IMAGE`, which may be a `.sif`
or an Apptainer sandbox directory. Where `/dev/fuse` is unavailable, the fixture
builds a sandbox directory automatically.

## After editing the shared library

```bash
bash scripts/sync-launch-lib.sh
bash tests/test-no-drift.sh
```

OOD stages only an app's `template/` directory, so the library must be vendored
into each app. The drift test fails the build if the copies diverge.
