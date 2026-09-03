# Course Python environments

A course's kernel environment lives at `<environment_root>/default`, on the shared filesystem outside this repo. This repo holds the spec it is first built from. After that, teaching staff maintain it on request and it is expected to drift from the spec.

**A course environment is optional.** `environment_root` is an optional attribute of a course sub-app. A course whose image already carries every package it needs leaves the value empty. There is then nothing to provision, and nothing on this page to do. Its sessions register no course kernel, set no `python.defaultInterpreterPath`, and log no warning about the environment. Everything below applies to a course that sets `environment_root`.

`scripts/submit-provision-course-env.sh` refuses to provision a course whose sub-apps declare no `environment_root`. The prefix it builds there is a directory no session ever reads. Set `environment_root` in both of the course's sub-apps first.

## 1. Write the spec

`envs/<course>/` holds:

| File | Contents |
|---|---|
| `manager` | `micromamba` or `uv`, on one line |
| `python-version` | e.g. `3.13` |
| `environment.yml` | micromamba courses: the dependency list |
| `pyproject.toml`, `uv.lock` | uv courses: the project definition |

Include the files for one manager only. A spec directory carrying both `environment.yml` and `pyproject.toml` is rejected.

Kernel-side packages only. JupyterLab and its extensions live in the image.

When you leave a requested package out, or set a version ceiling, say why in the dependency file. That comment is the answer when the course asks again next term.

## 2. Provision

```bash
scripts/submit-provision-course-env.sh \
    --course cs1090a \
    --canvas-id 12345 \
    --image jupyter-codeserver-ai/jupyterlab-20260828T030141Z-4e73009.sif
```

This submits the provisioning job to a compute node and returns immediately. The job creates `<environment_root>/default`. Monitor the job with `squeue -u $(id -nu)`. The log goes to `$OOD_APPTAINER_SCRATCH_ROOT/provisioning/<course>/provision.log`.

Options:

| Flag | Meaning |
|---|---|
| `--course NAME` | required; must match a directory under `envs/` |
| `--canvas-id ID` | required; selects the course folder |
| `--image <family>/<artifact>` | required; a deployed image |
| `--rebuild` | delete and recreate an existing `default` |
| `--dry-run` | print the job script and stop |
| `--environment-root PATH` | override where the prefix goes |

Before submitting, it prints the course folder and environment root it derived from `--canvas-id`, then checks that both apps' sub-apps for the course agree with them. That check needs `jq`. It is skipped with a warning when `ruby` is missing or when you pass `--environment-root`.

The job log is at `$OOD_APPTAINER_SCRATCH_ROOT/provisioning/<course>/provision.log`.

Provisioning validates the prefix before recording anything: the interpreter runs and reports the expected version, `ipykernel` imports, one package from the spec imports, and every file is readable and traversable by others. Only then does it write `manager` and a copy of the spec beside the prefix. If those records are missing, the run failed.

## 3. Maintain a prefix

Use only the manager that created it. Mixing tools in one prefix cannot be undone, and changing manager means recreating the prefix rather than converting it.

Set `$COURSE_ENV` to the prefix itself, `<environment_root>/default` or `<environment_root>/staging`, never `<environment_root>`.

```bash
# micromamba -- snapshot first, outside the prefix
micromamba env export --prefix "$COURSE_ENV" > env-export-$(date +%F).yml
micromamba list --explicit --prefix "$COURSE_ENV" > explicit-$(date +%F).txt
"$COURSE_ENV/bin/python" -m pip freeze > pip-freeze-$(date +%F).txt

micromamba install --prefix "$COURSE_ENV" <package>
micromamba remove  --prefix "$COURSE_ENV" <package>
micromamba update  --prefix "$COURSE_ENV" <package>   # or --all
```

```bash
# uv -- from the course's project directory
export UV_PROJECT_ENVIRONMENT="$COURSE_ENV"
cp pyproject.toml pyproject-$(date +%F).toml && cp uv.lock uv-$(date +%F).lock

uv add <package>
uv remove <package>
uv lock --upgrade-package <package> && uv sync
uv lock --upgrade && uv sync
```

Everything in the prefix must stay readable and traversable by others, or kernels stop starting for the whole course. After installing under a restrictive umask, check with the same test provisioning uses:

```bash
find "$COURSE_ENV" ! -perm -o+rX
```

## 4. Test in staging first (optional)

The apps look for `default` and `staging` under the environment root, and nothing else. They never build, compare or promote either.

Provisioning only ever creates `default`, as a real directory. To switch between prefixes, replace it with a symlink yourself. The launcher resolves symlinks, as long as the target stays inside the course folder:

```bash
mv  <environment_root>/default <environment_root>/v1
ln -sfn v1 <environment_root>/default

# after testing <environment_root>/v2:
ln -sfn v2 <environment_root>/default
```

## Troubleshooting

**"environment prefix already exists".** Pass `--rebuild` to delete and recreate it. Without that flag, provisioning refuses rather than overwriting.

**"ambiguous ownership".** The spec directory carries files for both managers. Keep `environment.yml` or `pyproject.toml`, not both.

**"cannot import ipykernel", or a package from the spec fails to import.** The prefix built but cannot run a kernel. Fix the spec and re-run with `--rebuild`.

**"has entries not readable/traversable by others".** Provisioning reports this instead of fixing it, because it does not change the course folder's permission model. Correct the modes, then re-run.

**A sub-app disagrees with the derived paths.** The sub-app declares a different course folder or environment root than `--canvas-id` produced. Fix the sub-app, or pass `--environment-root` if the difference is deliberate.

**An update broke a live prefix.** Recreate it from the snapshot or from `envs/<course>/`, then test Python startup and the course's representative imports before students use it again.
