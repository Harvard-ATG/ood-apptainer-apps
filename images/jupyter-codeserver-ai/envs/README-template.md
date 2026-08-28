# Course Python environment: <COURSE>

This file is copied beside the environment prefixes at
`<environment_root>/README.md` when the environment is first provisioned. It is
the only record teaching staff normally see of which tool owns this
environment and how to maintain it — the source repository is not something
teaching staff clone or read.

## What owns `default`

`default` is a **<MANAGER: micromamba|uv>**-managed environment. Manage it only
with that tool. Do not run the other manager's install/update/remove commands
against this prefix, and do not mix tools within one prefix — changing manager
means recreating the prefix from scratch, not converting it in place.

Configured Python version: **<PYTHON_VERSION>** (for example, `3.13`).

## `staging`

`<environment_root>/staging` is **optional** and **staff-created**. It is not
set up by provisioning and nothing here requires it. If present, it is used
for testing package changes before promoting them into `default` (for
example, by atomically switching a `default` symlink). Creating, testing, and
promoting `staging` are entirely staff-owned operations; the apps only look
for the `default` and `staging` names, they never build, compare, or promote
either one.

## Adding, removing, and updating packages

Use the commands for the manager that owns this environment (see above).

**micromamba:**

```bash
# Add a package
micromamba install --prefix "$COURSE_ENV" <package>

# Remove a package
micromamba remove --prefix "$COURSE_ENV" <package>

# Update a package (or everything)
micromamba update --prefix "$COURSE_ENV" <package>
micromamba update --prefix "$COURSE_ENV" --all
```

**uv:**

```bash
# Run from the staff-managed uv project directory for this course, with:
export UV_PROJECT_ENVIRONMENT="$COURSE_ENV"

# Add a package
uv add <package>

# Remove a package
uv remove <package>

# Update a package (or everything)
uv lock --upgrade-package <package>
uv sync
uv lock --upgrade
uv sync
```

Where `$COURSE_ENV` is the resolved prefix you are changing —
`<environment_root>/default` or `<environment_root>/staging`, not
`<environment_root>` itself.

## Before you change anything: save reproducibility records

Save these records before making any change, so a broken update can be
recovered from without guesswork:

**micromamba:**

```bash
micromamba env export --prefix "$COURSE_ENV" > env-export-$(date +%F).yml
micromamba list --explicit --prefix "$COURSE_ENV" > explicit-$(date +%F).txt
"$COURSE_ENV/bin/python" -m pip freeze > pip-freeze-$(date +%F).txt
```

**uv:**

```bash
cp pyproject.toml pyproject-$(date +%F).toml
cp uv.lock uv-$(date +%F).lock
uv export > uv-export-$(date +%F).txt
```

Keep these records somewhere outside the environment prefix itself (for
example, alongside this README) so they survive a failed or partial update.

## Recovering from a failed update

If an update fails or leaves the environment broken:

1. Stop making further changes to the prefix.
2. Ask ATG to help recreate the prefix from the saved reproducibility records
   above, or, failing that, from the initial specification in the
   `ood-apptainer-apps` repository.
3. Re-test Python startup and the course's representative imports before
   re-enabling student access.

## Course-specific constraints

<!--
For most courses this section is empty. CS1090A carries one binding
constraint; keep it here verbatim for that course's copy of this file, and
remove this section entirely for courses without one.
-->

**CS1090A only:** `otter-grader` is pinned to `>=7,<8`. This upper bound is a
course requirement, not a suggestion — **consult ATG before installing an
otter-grader version 8 or later.** Crossing it without checking first can
break how the course's assignments are graded.
