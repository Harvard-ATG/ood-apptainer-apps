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

| Path | Contents |
|---|---|
| `ood/lib/launch-common.sh` | Canonical shared containment logic. **Edit here.** |
| `ood/<app>-ai/template/lib/launch-common.sh` | Vendored copy staged by OOD. Generated — do not edit. |
| `ood/<app>-ai/` | Parent OOD app: form, submit, templates, sub-apps under `local/` |
| `images/` | Apptainer definition files and initial course environment specs |
| `scripts/` | Build, provisioning, and maintenance scripts |
| `tests/` | Verification suite |

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
