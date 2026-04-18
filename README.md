# ai-wave-runner

Minimal Bash orchestrator for launching parallel or sequential AI CLI executions in isolated git worktrees.

Source repo layout:

```text
theexecutors/
├── install.sh
├── src/
│   └── run.sh
└── templates/
    ├── config.json.tpl
    ├── master_prompt.md.tpl
    └── execution_example.json
```

Installed layout:

```text
<target>/
├── run.sh
├── config.json
├── master_prompt.md
├── execution_example.json
├── specs/
├── prompts/
├── output/        # auto-created on first run
├── logs/          # auto-created on first run
└── state.json     # auto-created on first run
```

## Requirements

- Bash 3.2+
- `jq`
- `git`
- One supported AI CLI installed and authenticated:
  - `claude`
  - `codex`

If `jq` or `git` is missing, `install.sh` and `run.sh` exit with code `2` and print a one-line install hint.

## Install

Run from the source repo:

```bash
./install.sh
```

Interactive prompts:

1. Project root path
2. Install target path
3. CLI choice: `claude` or `codex`
4. Git dir, or blank to reuse project root

Installer behavior:

- Creates `<target>/specs` and `<target>/prompts`
- Copies `src/run.sh` to `<target>/run.sh`
- Renders `<target>/config.json`
- Copies `<target>/master_prompt.md`
- Copies `<target>/execution_example.json`

Upgrade in place:

```bash
./install.sh --upgrade /path/to/installed/wave-runner
```

Current `--upgrade` behavior overwrites only `run.sh`.

## Config

`run.sh` always reads `config.json` and `master_prompt.md` from its own directory.

Example:

```json
{
  "cli": "claude",
  "project_root": "/var/www/my_project",
  "git_dir": "/var/www/my_project",
  "master_prompt_path": "./master_prompt.md",
  "output_base": "./output",
  "executions": [
    {
      "techspec_path": "./specs/SPEC-01.md",
      "prompt_path": "./prompts/SPEC-01.md",
      "parallel": "yes",
      "model": "claude-sonnet-4-6",
      "effort": "high"
    },
    {
      "techspec_path": "./specs/SPEC-02.md",
      "prompt": "Focus on failure cases first.",
      "parallel": "no",
      "model": "claude-opus-4-7",
      "effort": "high"
    }
  ]
}
```

Top-level fields:

- `cli`: `claude` or `codex`
- `project_root`: sanity reference for the target repo
- `git_dir`: repo root used for `git worktree`
- `master_prompt_path`: relative to installed dir or absolute
- `output_base`: relative to installed dir or absolute
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

## Execution Model

Each non-empty execution gets an `exec_id`:

```text
<NN>_<sanitized_techspec_basename>
```

Example:

```text
01_SPEC-03_autocorr
```

Batching behavior:

- consecutive `parallel: "yes"` entries are grouped into one batch
- `parallel: "no"` runs alone
- `{ "parallel": "no" }` acts as a batch barrier
- if one task fails, later batches still run
- final exit code is `1` if any task failed

## Worktrees

For each execution, `run.sh` either reuses a tracked worktree from `state.json` or creates a new one under:

```text
<git_dir>/.worktrees/<exec_id>
```

Branch name matches the worktree name. If the intended path already exists outside tracked state, the runner appends a timestamp suffix and retries.

`state.json` is created automatically on first execution:

```json
{
  "executions": {
    "01_SPEC-01": {
      "worktree_path": "/repo/.worktrees/01_SPEC-01",
      "branch": "01_SPEC-01",
      "last_run_ts": "20260418_143022",
      "last_status": "done"
    }
  }
}
```

## Prompt Assembly

For each execution, the runner writes:

- `logs/<wave_ts>/<exec_id>.prompt.md`
- `logs/<wave_ts>/<exec_id>.log`

Prompt shape:

```markdown
<master_prompt.md>

---

<inline prompt, if present>

<prompt_path contents, if present>

---

## Techspec
Read your techspec at: <absolute techspec path>

## Output directory
Write all deliverables to: <absolute output path>/
```

The techspec is referenced by absolute path, not inlined.

## Run

Dry run:

```bash
./run.sh --dry-run
```

Execute:

```bash
./run.sh
```

Dry-run output includes:

- resolved `exec_id`
- model
- effort for `claude`
- prompt source type
- absolute techspec path
- intended worktree path
- resolved output directory

Normal execution:

- creates `logs/<timestamp>/`
- creates `output/<exec_id>/`
- updates `state.json`
- prints `DONE` or `FAILED` per execution
- prints a final summary

Exit codes:

- `0`: all executions succeeded
- `1`: one or more executions failed
- `2`: missing prereq or invalid config
- `130`: interrupted

## CLI Assumptions

Current dispatch in `run.sh` is:

```bash
claude -p --model "$MODEL" --effort "$EFFORT" --permission-mode auto
codex -q --full-auto -m "$MODEL"
```

These flags should be verified against the installed CLI versions in the target environment before relying on unattended runs. The runner assumes:

- `claude` accepts stdin for prompt input in `-p` mode
- `codex` accepts stdin for prompt input in `-q --full-auto` mode
- both CLIs are already authenticated

## Notes

- `project_root` is validated but agents run inside the resolved worktree path
- logs are written to files only, so parallel output does not interleave on stdout
- `specs/` and `prompts/` are conventions; absolute or alternate relative paths are allowed in `config.json`
- worktree cleanup is manual; this project does not remove old worktrees

For day-to-day usage, see [RUNBOOK.md](./RUNBOOK.md).
