# Waverunner

Waverunner lets you hand one project a list of AI tasks, then automatically spin them out into isolated git worktrees, run them in parallel or sequence, and keep the prompts, logs, outputs, and state organized for review. If you already use AI coding agents but do not want every core repo reinventing its own one-off orchestration scripts, Waverunner extracts that infrastructure into a reusable runner so your product repos stay focused on product work instead of worktree plumbing.

Unlike worktree managers that focus on interactive session control, Waverunner is a lightweight, config-driven execution unit: define the wave once, reuse it across projects, reduce redundant setup, and stop rebuilding the same custom runner logic inside repos where it is not part of the actual product.

## Why Use It

- Run multiple Claude or Codex tasks from one config file.
- Isolate every execution in its own git worktree.
- Mix parallel batches with explicit sequential barriers.
- Keep an audit trail of assembled prompts, logs, outputs, and worktree state.
- Install a self-contained runner into a project without tying day-to-day use to this source repo.

## What It Installs

Run `install.sh` from this repo once, then operate from the installed target directory.

```text
<target>/
├── run.sh
├── config.json
├── output/        # auto-created on first real run
├── logs/          # auto-created on first real run
└── state.json     # auto-created on first real run
```

Waverunner does not create or manage `specs/`, `prompts/`, `master_prompt.md`, or example execution files. Your prompt and techspec files stay fully user-owned and can live anywhere in the project.

## Requirements

- Bash 3.2+
- `jq`
- `git`
- One supported AI CLI installed and already authenticated:
  - `claude`
  - `codex`

If `jq` or `git` is missing, both `install.sh` and `run.sh` exit with code `2` and print a one-line install hint.

## Install

From the source repo:

```bash
./install.sh
```

The installer prompts for:

1. Project root path
2. Install target path
3. Whether to append the install dir to `<project_root>/.gitignore`
4. CLI choice: `claude` or `codex`
5. Git dir, or blank to reuse project root

Behavior to know:

- The installer keeps asking until the project root exists.
- The install target defaults to `<project_root>/waverunner`.
- If the install target already exists, the installer can remove it or let you choose another path.
- If the install target lives under the project root, the installer can append `/<relative-target>/` to the project `.gitignore` without duplicating the entry.
- The generated `config.json` contains one baked-in example execution.

Upgrade an existing installed runner:

```bash
./install.sh --upgrade /path/to/installed/waverunner
```

Current upgrade behavior overwrites only `run.sh`.

## Configure

`run.sh` always reads `config.json` from its own directory. All relative paths inside `config.json` are resolved from that installed directory.

You do not need to fill in the JSON by hand. In practice, many teams ask their AI coding agent to generate or update `config.json` for the wave they want to run.

Example:

```json
{
  "cli": "claude",
  "project_root": "/var/www/my_project",
  "git_dir": "/var/www/my_project",
  "master_prompt_path": "/var/www/my_project/master_prompt.md",
  "output_base": "./output",
  "executions": [
    {
      "techspec_path": "/var/www/my_project/specs/SPEC-01.md",
      "prompt_path": "/var/www/my_project/prompts/SPEC-01.md",
      "parallel": "yes",
      "model": "claude-sonnet-4-6",
      "effort": "high"
    },
    {
      "techspec_path": "/var/www/my_project/specs/SPEC-02.md",
      "prompt": "Focus on failure cases first.",
      "parallel": "yes",
      "model": "claude-sonnet-4-6",
      "effort": "high"
    },
    { "parallel": "no" },
    {
      "techspec_path": "/var/www/my_project/specs/SPEC-03.md",
      "prompt_path": "/var/www/my_project/prompts/SPEC-03.md",
      "parallel": "no",
      "model": "claude-sonnet-4-6",
      "effort": "high"
    }
  ]
}
```

Top-level fields:

- `cli`: `claude` or `codex`
- `project_root`: validated sanity reference for the target project
- `git_dir`: repo root used for `git worktree`
- `master_prompt_path`: project-wide prompt file
- `output_base`: base directory for per-execution outputs
- `executions`: ordered execution list

Per-execution fields:

- `techspec_path`: required for non-barrier entries
- `prompt` or `prompt_path`: at least one required
- `parallel`: required, `yes` or `no`
- `model`: required
- `effort`: required for `claude`, ignored for `codex`

Barrier entry:

```json
{ "parallel": "no" }
```

That entry runs nothing. It only flushes the current parallel batch.

## Run

Inspect the resolved plan first:

```bash
./run.sh --dry-run
```

Launch the wave:

```bash
./run.sh
```

Before any execution starts, `run.sh` validates:

- `config.json` exists and is valid JSON
- required top-level fields are present
- `project_root`, `git_dir`, and `master_prompt_path` resolve correctly
- every referenced `techspec_path` and `prompt_path` exists
- `output_base` can be created or written

Dry-run output shows the batch plan, including:

- resolved `exec_id`
- model
- effort for `claude`
- prompt source type
- absolute techspec path
- planned worktree path
- resolved output directory

Real execution:

- creates `logs/<wave_ts>/`
- creates `output/<exec_id>/`
- creates or reuses git worktrees under `<git_dir>/.worktrees/`
- updates `state.json`
- prints `DONE` or `FAILED` per execution
- exits `1` if any execution failed

## Execution Flow

```mermaid
flowchart TD
    A[Edit config.json] --> B[./run.sh --dry-run]
    B --> C[Validate config and all referenced paths]
    C --> D[Build execution batches]
    D --> E[Resolve or create worktrees]
    E --> F[Assemble prompt files]
    F --> G[Run Claude or Codex]
    G --> H[Write logs, output, and state]
    H --> I{More batches?}
    I -->|Yes| E
    I -->|No| J[Print summary and exit]
```

Batching rules:

- Consecutive `parallel: "yes"` entries run together in one batch.
- `parallel: "no"` runs alone.
- `{ "parallel": "no" }` acts as a barrier between parallel waves.
- Later batches still run even if an earlier execution failed.
- Final process exit code is `1` if any execution failed.

## Prompt and Output Model

For each execution, Waverunner writes:

- `logs/<wave_ts>/<exec_id>.prompt.md`
- `logs/<wave_ts>/<exec_id>.log`
- `output/<exec_id>/`

Prompt shape:

```markdown
<contents of master_prompt_path>

---

<inline prompt, if present>

<prompt_path contents, if present>

---

## Techspec
Read your techspec at: <absolute techspec path>

## Output directory
Write all deliverables to: <absolute output path>/
```

The techspec is referenced by absolute path, not inlined into the prompt.

## Worktree Model

Each non-empty execution gets an `exec_id` in this form:

```text
<NN>_<sanitized_techspec_basename>
```

Example:

```text
01_SPEC-03_autocorr
```

For each execution, `run.sh` either:

- reuses a tracked worktree from `state.json` if it still exists, or
- creates a new worktree at `<git_dir>/.worktrees/<exec_id>`

The branch name matches the worktree name. If a matching path already exists outside tracked state, Waverunner appends a timestamp suffix and retries.

## Who This Is For

- Teams or solo operators running repeatable spec-driven AI tasks against one repo
- People who want cheap orchestration without building a queueing system
- Workflows where prompt auditability and worktree isolation matter
- Projects that already organize work around techspecs, task prompts, and output directories

## When Not To Use It

- You need DAG scheduling, retries, budgets, or centralized coordination
- You want a live UI, dashboards, or multi-user job control
- You only run one-off interactive AI CLI sessions
- You do not want persistent worktrees to accumulate over time

## Current Limitations

- No retries
- No DAG scheduling
- No automatic worktree cleanup
- No live viewer for parallel runs
- No CLI version detection

For day-to-day operating guidance, see [RUNBOOK.md](./RUNBOOK.md).
