# CI/CD Pipeline — Databricks Asset Bundle + dbt Core

## Overview

This repository implements a production-grade CI/CD pipeline for deploying a **Databricks Asset Bundle (DAB)** containing dbt Core jobs across three environments: `dev`, `stg`, and `prod`.

### Technologies

| Layer | Technology | Role |
|-------|-----------|------|
| Source control | **GitHub** | Hosts all project code and pipeline definitions |
| CI/CD orchestration | **Azure DevOps Pipelines** | Runs validation and deployment pipelines |
| Branch protection | **GitHub Rulesets** | Blocks merges until all ADO checks pass |
| Data transformation | **dbt Core** | SQL transformations orchestrated by Databricks |
| SQL linting | **sqlfluff** | Enforces SQL style and formatting conventions on every PR |
| Job orchestration | **Databricks Asset Bundle** | Defines and deploys Databricks job definitions |
| Execution | **Databricks Jobs** | Runs dbt tasks on schedule after deploy |

### How they work together

GitHub hosts the code and enforces branch protection via Rulesets — but the actual status checks that block or allow a merge come from **Azure DevOps**. When a PR is opened, ADO pipelines run automatically and report their results back to GitHub. The Ruleset only allows the merge when all required ADO checks are green.

On merge, ADO deploys the Databricks bundle to the target workspace. Databricks then runs the dbt jobs on their configured schedule — the pipeline never executes dbt models directly.

```
Developer → (GitHub PR) → ADO runs checks → GitHub Ruleset gates merge → (Merge) → ADO deploys bundle → Databricks runs dbt on schedule
```

---

---

## Repository Structure

```
repo/
├── pipelines/                        # Azure DevOps pipeline definitions
│   ├── ci-pipeline.yml               # CI: runs on every pull request
│   ├── cd-pipeline.yml               # CD: runs on merge to dev, stg or main
│   └── check_source_branch.yml       # CI: Branch protection: enforces PR source
├── dab/                              # Databricks Asset Bundle
│   ├── databricks.yml                # Bundle config + environment targets
│   └── resources/
│       └── jobs.yml                  # Job definitions
├── dbt/                              # dbt Core project
│   ├── dbt_project.yml
│   ├── profiles_template.yml         # Template for local development — rename to profiles.yml locally
│   ├── packages.yml
│   ├── .sqlfluff                     # sqlfluff config for local dev/test - Generated at runtime in CI
│   ├── seeds/
│   │   └── locales.csv               # Sample seed table
│   └── models/
```

---

## Environments

This pipeline uses three environments. There is no additional QA environment.

| Environment | Databricks workspace | Branch | Catalog |
|-------------|---------------------|--------|---------|
| `dev` | DEV workspace | `dev` | `team_loan360_dev` |
| `stg` | STG workspace | `stg` | `team_loan360_qa` |
| `prod` | PROD workspace | `main` | `team_loan360_prod` |

---

## Branching Strategy

```
feature/* ──► dev ──► stg ──► main
```

| Branch | Purpose |
|--------|---------|
| `feature/*` | Individual development work |
| `dev` | Integration branch — maps to DEV workspace |
| `stg` | Pre-production branch — maps to STG workspace |
| `main` | Production branch — maps to PROD workspace |

PR source restrictions enforced by branch protection:
- PRs to `stg` must come from `dev`
- PRs to `main` must come from `stg` or `hotfix/*`
- Direct PRs from feature branches to `stg` or `main` are blocked

### Developer Rules (Mandatory)

These rules apply to every developer on every branch, every time:

1. **Always pull from `main` before branching** — start with the freshest production code.
   > If `main` received a hotfix and you branched from a stale local copy, you are building on top of code that no longer reflects production — guaranteed conflicts later.

2. **Feature branches must be short-lived** — max 1-2 days; break larger work into smaller chunks.
   > The longer a branch lives, the more `dev` moves on without it. Long-lived branches mean large diffs, painful merges, and slow reviews.

3. **Never commit directly to `dev`, `stg`, or `main`** — always via Pull Request.
   > A direct push bypasses CI entirely — no `dbt compile`, no `sqlfluff`, no `bundle validate`. A broken model reaches `dev` with no checks, and the next developer to pull inherits the breakage.

4. **One feature = one PR** — no large PRs combining unrelated changes.
   > Large mixed PRs are impossible to review meaningfully. If something breaks in production, isolating the cause takes hours. Small PRs are faster to review, easier to revert, and safer to merge.

5. **Never merge a red PR** — all CI checks must be green before merging.
   > A failing check means a real problem was found. Merging red knowingly introduces a defect into `dev` that the next developer will waste time debugging.

6. **Delete your branch after merging** — click "Delete branch" in GitHub after every merged PR.
   > `feature/*` and `hotfix/*` branches are temporary — they should not outlive their PR. Keeping them around creates confusion about what is active and what is already merged. `dev`, `stg`, and `main` are permanent and should never be deleted.

**Starting a new feature (mandatory flow):**

```bash
git checkout main
git pull origin main
git checkout -b feature/my-feature
# ... work ...
# open PR → dev
```

### Hotfix Strategy

Hotfixes are the emergency exit for production incidents only — not a shortcut to skip the normal promotion flow.

**Flow:**
```
main ──► hotfix/critical-bug ──► main (PR, bypasses stg gate)
                                  │
                                  ├──► stg (manual PR — mandatory)
                                  │
                                  └──► dev (manual PR — mandatory)
```

**Rules:**
- Branch **from `main`**, never from `dev` — you want to fix exactly what is in prod.
  > `dev` may contain unreleased features. Branching from it would ship those to prod alongside the fix — unreviewed and unintended.
- Still requires a Pull Request and at least 1 approval.
- Only repo admins or tech leads can merge `hotfix/*` → `main`.
- Back-merge to `stg` and then `dev` is **mandatory** — open manual PRs immediately after the fix is deployed to prod.
  > Skipping this causes `stg` and `dev` to diverge from `main`. On the next promotion cycle, Git may produce conflicts or silently revert the hotfix.
- If conflicts arise during back-merge, the developer who opened the hotfix is responsible for resolving them.

**Starting a hotfix:**

```bash
git checkout main
git pull origin main
git checkout -b hotfix/critical-bug
# ... fix ...
# open PR → main
# after merge → open PR main → stg, then stg → dev
```

---

## Pipeline Behavior

### On Pull Request (`ci-pipeline.yml`)

The CI pipeline runs on **every PR regardless of which files changed**. This ensures the merge button is never left in a permanently blocked state when non-code files like the README are modified.

| PR target | `dbt compile` | `bundle validate` |
|-----------|--------------|-------------------|
| `dev` | ✅ against DEV warehouse | ✅ against dev target |
| `stg` | ✅ against STG warehouse | ✅ against stg target |
| `main` | ✅ against PROD warehouse | ✅ against prod target |

> `bundle validate` runs on all PR targets — including `dev`. A misconfigured `databricks.yml` or `jobs.yml` caught at PR time is far cheaper to fix than one that reaches `stg` after already being integrated into `dev`.

### On Merge (`cd-pipeline.yml`)

The CD pipeline only triggers when `dbt/**` or `dab/**` files are changed. A merge that only touches documentation will not trigger a deploy.

| Merged into | `bundle validate` | `bundle deploy` |
|-------------|-------------------|-----------------|
| `dev` | ✅ against DEV | ⏭️ skipped |
| `stg` | ✅ against STG | ✅ to stg (only if validate passes) |
| `main` | ✅ against PROD | ✅ to prod (only if validate passes) |

### Branch Protection (`check_source_branch.yml`)

Runs on every PR targeting `stg` or `main`. Fails immediately if the source branch does not match the expected branch, blocking the merge via GitHub Ruleset.

---

## Key Design Decisions

### Databricks is the dbt orchestrator
Databricks Jobs use **dbt task types** to execute the dbt project. The CI/CD pipeline only deploys job definitions — it never runs `dbt build` directly. Databricks handles dbt execution on its own schedule after deployment.

### `bundle deploy` ≠ job execution
Running `databricks bundle deploy` updates the job definitions in the Databricks workspace. It does **not** trigger the jobs. Jobs run on their configured cron schedule.

### dbt compile on CI — no model materialization
`dbt compile` validates Jinja syntax and SQL structure. It requires a live warehouse connection but does **not** write anything to the catalog. A `ci_placeholder` value is passed for the `catalog` variable during CI since compile does not need a real catalog — only runtime execution does. 

### No paths filter on CI
The CI pipeline intentionally has no `paths` filter. If paths were filtered, a PR that only modifies the README would never trigger the required status checks, leaving the merge button permanently blocked. The CD pipeline does use a paths filter since a skipped deploy on a documentation change is acceptable.

### `profiles.yml` collaborative strategy
The `dbt/profiles.yml` file is committed to the repository as a template using environment variable references. Developers configure those variables locally to run dbt against their personal dev schema. At pipeline runtime, the CI pipeline overwrites `profiles.yml` with the actual credentials from the ADO Variable Group, pointing to the correct warehouse for the target branch.


### Bundle variables are injected at deploy time
`warehouse_id` and `git_url` are not hardcoded in `jobs.yml`. They are declared as variables in `databricks.yml` and passed via `--var` flags at runtime from the ADO Variable Group. This keeps environment-specific values out of the codebase.

### `catalog`, `schema` and `git_branch` are resolved per target
Each bundle target defines its own values for `catalog`, `schema` and `git_branch` directly in `databricks.yml`. The CLI resolves them automatically at runtime without needing `--var` flags.

| Target | `catalog` | `git_branch` |
|--------|-----------|-------------|
| `dev` | `team_loan360_dev` | `dev` |
| `stg` | `team_loan360_qa` | `stg` |
| `prod` | `team_loan360_prod` | `main` |

### `catalog` variable passed to dbt via `--vars`
Since dbt does not have direct access to Databricks bundle variables, the catalog is explicitly passed to each dbt command at runtime:

```
dbt compile --vars '{"catalog": "${var.catalog}"}'
dbt seed --vars '{"catalog": "${var.catalog}"}'
```

This ensures dbt uses the correct catalog per environment without hardcoding values in `dbt_project.yml`.

### sqlfluff — SQL linting on every PR
`sqlfluff lint` runs on every PR as part of the CI pipeline. It validates SQL style and formatting conventions — indentation, capitalization, spacing, and Jinja syntax — before any code reaches STG or PROD. This enforces a consistent code style across all developers without relying on manual code review for formatting issues.

Both `.sqlfluff` and `profiles.yml` are generated dynamically by the CI pipeline at runtime and are never committed to the repository. This keeps credentials and environment-specific configuration out of the codebase.

For local development, each developer creates these files manually following the instructions in the Local Development section. Both files should be added to `.gitignore` to prevent accidental commits.

The `catalog` variable is injected into sqlfluff via the dynamically generated `.sqlfluff` config using `ci_placeholder` as the value — sqlfluff needs it to resolve Jinja during compilation but never uses it to connect to any warehouse.
The pipelines use the `Linux` pool (self-hosted agent) instead of the default Microsoft-hosted `ubuntu-latest`. This is required because the Databricks workspaces have network access restrictions that block public Azure DevOps runner IPs. The self-hosted agent runs inside the corporate network and has direct access to all three workspaces.

### `run_as` — service principal (pending)
Job definitions currently omit `run_as`, defaulting to the deploying user. This will be replaced with a service principal before production rollout to avoid dependency on individual user accounts.

---

## Azure DevOps Setup

### Variable Group

Create a Variable Group in ADO under Pipelines → Library. Name it following the convention `dbt-databricks-cicd-<project-name>`, for Instance: `dbt-databricks-cicd-template`.

**Variables (non-sensitive):**

| Variable | Description |
|----------|-------------|
| `DATABRICKS_HOST_DEV` | Bare hostname of the DEV workspace |
| `DATABRICKS_HOST_STG` | Bare hostname of the STG workspace |
| `DATABRICKS_HOST_PROD` | Bare hostname of the PROD workspace |
| `DATABRICKS_HTTP_PATH_DEV` | HTTP path of the DEV SQL warehouse |
| `DATABRICKS_HTTP_PATH_STG` | HTTP path of the STG SQL warehouse |
| `DATABRICKS_HTTP_PATH_PROD` | HTTP path of the PROD SQL warehouse |
| `WAREHOUSE_ID_DEV` | Warehouse ID for the DEV Databricks job |
| `WAREHOUSE_ID_STG` | Warehouse ID for the STG Databricks job |
| `WAREHOUSE_ID_PROD` | Warehouse ID for the PROD Databricks job |
| `GIT_URL` | Full HTTPS URL of the GitHub repository |

**Secrets (mark as secret in ADO):**

| Secret | Description |
|--------|-------------|
| `DATABRICKS_TOKEN_DEV` | Access token for DEV workspace |
| `DATABRICKS_TOKEN_STG` | Access token for STG workspace |
| `DATABRICKS_TOKEN_PROD` | Access token for PROD workspace |

### Pipelines to register in ADO

Register each pipeline in ADO pointing to the corresponding file in the repository:

| Pipeline name | File |
|---------------|------|
| `ci-pipeline` | `pipelines/ci-pipeline.yml` |
| `cd-pipeline` | `pipelines/cd-pipeline.yml` |
| `check-source-branch` | `pipelines/check_source_branch.yml` |

All pipelines use the `Linux` agent pool.

> **Important:** After registering each pipeline in ADO, you must explicitly grant it access to the Variable Group. Go to Pipelines → Library → your Variable Group → Pipeline permissions → add each pipeline. Without this step the pipeline will fail on its first run with a permission error.

---

## GitHub Ruleset Configuration

Branch protection is enforced through two mechanisms: an ADO pipeline that validates the source branch, and a GitHub Ruleset that blocks the merge button until all required checks pass.

### Bypass Strategy

Each Ruleset includes a **Repository Admin** bypass. This is intentional and serves a specific purpose per environment — it is not a backdoor for skipping process.

| Ruleset | Bypass | Purpose |
|---------|--------|---------|
| `protect-main` | Admin | Emergency escape valve — use only if pipeline infrastructure is down and a critical fix cannot wait |
| `protect-stg` | Admin | Allows Admin to back-merge `main → stg` after a hotfix without requiring approval |
| `protect-dev` | Admin | Allows Admin to back-merge `stg → dev` after a hotfix without requiring approval |

> The bypass should never be used to skip normal PR flow. Its only legitimate uses are hotfix back-merges and pipeline infrastructure failures.

### `main` — strictest (production)

```
Ruleset name:  protect-main
Target:        main

✅ Restrict deletions
✅ Restrict force pushes
✅ Require a pull request before merging
✅ Require status checks to pass
     → Source Branch Check
     → dbt compile
     → Bundle validate
```

### `stg` — pre-production

```
Ruleset name:  protect-stg
Target:        stg

✅ Restrict deletions
✅ Restrict force pushes
✅ Require a pull request before merging
✅ Require status checks to pass
     → Source Branch Check
     → dbt compile
     → Bundle validate
```

### `dev` — integration

```
Ruleset name:  protect-dev
Target:        dev

✅ Restrict deletions
✅ Restrict force pushes
```

No status checks or PR required — developers can push and merge freely to `dev`.

> **Important:** Status check names must match the `displayName` of the job in the ADO pipeline exactly. These checks only appear in the GitHub search box after the pipelines have run at least once against a PR targeting that branch.

---

## GitHub — Databricks Link

When a Databricks job uses `source: GIT`, Databricks needs Git credentials to clone the repository at runtime. This link must be configured per user in each workspace.

**Setup per workspace:**

Databricks workspace → User Settings → Linked accounts → Git integration → add GitHub with your username and a Personal Access Token with `repo` scope.

This must be done separately in DEV, STG and PROD workspaces.

**Current approach for development and POC:**

| Context | Approach |
|---------|---------|
| DEV / POC / testing | Manual GitHub link per user in each workspace |
| STG / PROD | Service principal configured at workspace level |

With a service principal, this link is configured once at the workspace level by an admin — all jobs using that principal inherit the GitHub credentials automatically, with no per-user setup required.

---

## Local Development

### dbt

The repository includes a `dbt/profiles_template.yml` file with placeholder values. To set up your local environment:

1. Copy `profiles_template.yml` and rename it to `profiles.yml` in the same `dbt/` folder
2. Replace the placeholder values with your real credentials and environment values
3. Run dbt commands passing the catalog explicitly:

```bash
dbt compile --vars '{"catalog": "team_loan360_dev"}'
dbt run --vars '{"catalog": "team_loan360_dev"}'
dbt seed --vars '{"catalog": "team_loan360_dev"}'
```

> `profiles.yml` is listed in `.gitignore` — it must never be committed to the repository with real credentials.

### Databricks bundle

Set the following environment variables before running any bundle command:

**Git Bash / macOS / Linux:**
```bash
export DATABRICKS_HOST="https://XXXXXX.azuredatabricks.net"
export DATABRICKS_TOKEN="XXXXXX"
export BUNDLE_VAR_warehouse_id="XXXXXX"
export BUNDLE_VAR_git_url="https://github.com/LD-DataEngineering/LD.Data.DbtDbx.Template.git"
```

**PowerShell (Windows):**
```powershell
$env:DATABRICKS_HOST = "https://XXXXXX.azuredatabricks.net"
$env:DATABRICKS_TOKEN = "XXXXXX"
$env:BUNDLE_VAR_warehouse_id = "XXXXXX"
$env:BUNDLE_VAR_git_url = "https://github.com/LD-DataEngineering/LD.Data.DbtDbx.Template.git"
```

Then run the bundle commands from the `dab/` folder:

```bash
cd dab
databricks bundle validate
databricks bundle deploy
```

### sqlfluff

To run SQL linting locally, create a `.sqlfluff` file in the `dbt/` folder with the following content:

```ini
[sqlfluff]
templater = dbt
dialect = databricks
runaway_limit = 10

[sqlfluff:templater:dbt]
project_dir = .
profiles_dir = .
devprofile = dbt_dbx_template
target = dev

[sqlfluff:templater:dbt:context]
catalog = team_loan360_dev
```

Replace `team_loan360_dev` with your actual DEV catalog. Then run:

**Git Bash / macOS / Linux:**
```bash
SQLFLUFF_CONTEXT_catalog=team_loan360_dev sqlfluff lint models/ --dialect databricks --templater dbt
```

**PowerShell (Windows):**
```powershell
$env:SQLFLUFF_CONTEXT_catalog = "team_loan360_dev"
sqlfluff lint models/ --dialect databricks --templater dbt
```

> `.sqlfluff` is listed in `.gitignore` — it must never be committed to the repository. Each developer creates it locally following this template.

---

## Test Cases

This section documents the expected behavior for every scenario in the CI/CD pipeline. Use it to verify the setup is working correctly after any change to pipelines, Rulesets, or branch configuration.

---

### Case 1 — PR from `feature/*` → `dev`

Open a PR from any feature branch to `dev`.

Expected:
- `ci-pipeline` triggers
- `dbt compile` runs against DEV warehouse
- `bundle validate` runs against DEV target
- `check_source_branch` does not trigger

---

### Case 2 — Merge to `dev`

Merge the PR from Case 1.

Expected:
- `cd-pipeline` triggers
- `bundle validate --target dev` runs
- `bundle deploy` is skipped — only runs on `stg` and `main`

---

### Case 3 — PR from `dev` → `stg`

Open a PR from `dev` to `stg`.

Expected:
- `ci-pipeline` triggers
- `dbt compile` runs against STG warehouse
- `bundle validate` runs against STG target
- `check_source_branch` triggers and passes — source is `dev`

---

### Case 4 — Merge to `stg`

Merge the PR from Case 3.

Expected:
- `cd-pipeline` triggers
- `bundle validate --target stg` runs
- `bundle deploy --target stg` runs if validate passes

---

### Case 5 — PR from `stg` → `main`

Open a PR from `stg` to `main`.

Expected:
- `ci-pipeline` triggers
- `dbt compile` runs against PROD warehouse
- `bundle validate` runs against PROD target
- `check_source_branch` triggers and passes — source is `stg`

---

### Case 6 — Merge to `main`

Merge the PR from Case 5.

Expected:
- `cd-pipeline` triggers
- `bundle validate --target prod` runs
- `bundle deploy --target prod` runs if validate passes

---

### Case 7 — PR from `feature/*` → `stg` or `main`

Open a PR skipping the normal promotion flow — for example directly from a feature branch to `stg` or `main`.

Expected:
- `check_source_branch` triggers and fails — source branch is not allowed
- Merge is blocked by GitHub Ruleset

---

### Case 8 — PR from `hotfix/*` → `main`

Open a PR from a hotfix branch directly to `main`.

Expected:
- `ci-pipeline` triggers
- `dbt compile` runs against PROD warehouse
- `bundle validate` runs against PROD target
- `check_source_branch` triggers and passes — source is `hotfix/*`
- ADO logs show back-merge reminder warning

---

### Case 9 — PR without approval

Open a PR to `stg` or `main` and attempt to merge without any approval.

Expected:
- Merge button is blocked by GitHub Ruleset
- All CI checks may be green but merge is not allowed until 1 approval is received

---

### Case 10 — Author approves their own PR

Open a PR and approve it yourself as the author.

Expected:
- Merge is blocked — self-approval is not valid
- A second reviewer must approve before merge is allowed

---

## Onboarding a New Project

This section describes how a new team can replicate this CI/CD setup for a new project that has its own GitHub repository, Databricks Asset Bundle and dbt project.

### Prerequisites

Before starting, make sure you have:

- A GitHub repository with a `dab/` folder containing `databricks.yml` and job definitions, and a `dbt/` folder with a valid dbt project
- Access to Azure DevOps with permissions to create pipelines and variable groups
- Access to the Databricks DEV, STG and PROD workspaces
- A GitHub PAT token with `repo` and `admin:repo_hook` permissions configured as a service connection in ADO
- GitHub credentials linked in each Databricks workspace under User Settings → Git integration

### Step 1 — Prepare the GitHub repository

Create the following branch structure:

```
main   ← maps to PROD
stg    ← maps to STG
dev    ← maps to DEV
```

Copy the three pipeline files into a `pipelines/` folder at the root of the repo and update the Variable Group name in each pipeline file to match the new project.

### Step 2 — Create the ADO Variable Group

Create a Variable Group named `dbt-databricks-cicd-<project-name>` with all variables and secrets listed in the ADO Setup section above.

### Step 3 — Register the pipelines in ADO

For each of the three pipeline files, create a new pipeline in ADO pointing to the corresponding file. Grant each pipeline access to the Variable Group under Pipelines → Library → Pipeline permissions.

### Step 4 — Configure GitHub Ruleset

Configure three rulesets in GitHub — `protect-main`, `protect-stg` and `protect-dev` — as described in the GitHub Ruleset Configuration section.

### Step 5 — Run a smoke test

Follow the [Test Cases](#test-cases) section and execute each case in order. All cases must pass before considering the setup production-ready.

---

## Next Steps

### Service Principals
Replace personal access tokens with a service principal in both the Databricks job definitions (run_as) and the ADO Variable Group secrets. This eliminates dependency on individual user accounts, resolves the GitHub–Databricks link issue at the workspace level, and is required before promoting this pipeline to a production-grade setup.

### Dedicated ADO Pipelines Repository
Move the pipeline YAML files from this repository to a dedicated central repository. Each new project would reference the templates instead of copying them, ensuring consistency across projects and allowing centralized updates. ADO Pipeline Templates support cross-repository references from GitHub using the existing service connection — no additional infrastructure required.