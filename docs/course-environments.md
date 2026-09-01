# Course Python environments

ATG provisions a course's Python prefix at `<environment_root>/default` from
the spec in `envs/<course>/`, and maintains it on request. Provisioning creates
the prefix and records the manager and source spec beside it. It writes no
documentation into the course shared folder, which every student on the course
can read.

## The spec

`envs/<course>/` holds:

| File | Contents |
|---|---|
| `manager` | `micromamba` or `uv`, on one line |
| `python-version` | e.g. `3.13` |
| `environment.yml` | micromamba courses: the dependency list |
| `pyproject.toml`, `uv.lock` | uv courses: the project definition |

It records the initial state; the live prefix is expected to drift from it.
Kernel-side packages only — JupyterLab and its extensions live in the image.

When a requested package is deliberately left out, or a version ceiling is
deliberately set, say why in the dependency file. That comment is the answer
when the course asks again next term.

`scripts/build-course-env.sh` submits the provisioning job.

## Maintaining a prefix

Use only the manager that created it: mixing tools in one prefix is not
recoverable, and changing manager means recreating the prefix rather than
converting it. `$COURSE_ENV` is `<environment_root>/default` or
`<environment_root>/staging`, never `<environment_root>` itself.

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

`staging` is optional: test changes there, then switch the `default` symlink
atomically. The apps look for those two names only, and never build, compare
or promote either.

If an update breaks a prefix, recreate it from the snapshot or from
`envs/<course>/`, then re-test Python startup and the course's representative
imports before students use it again.
