# Runbook

## First Run

1. Install the runner:

```bash
./install.sh
```

2. Edit `config.json`.
3. Fill in `master_prompt.md`.
4. Put techspec markdown files in `specs/`.
5. Put task prompt markdown files in `prompts/`.
6. Inspect the plan:

```bash
./run.sh --dry-run
```

7. Launch the wave:

```bash
./run.sh
```

## Recommended Workflow

1. Keep `master_prompt.md` stable and project-wide.
2. Keep each execution prompt short and task-specific.
3. Use `parallel: "yes"` only for tasks that can safely run independently.
4. Insert `{ "parallel": "no" }` when you need a hard separation between two parallel waves.
5. Tail individual log files while a batch is running.

Example:

```bash
tail -f logs/20260418_143022/01_SPEC-01.log
```

## Building a Good Execution Entry

Example:

```json
{
  "techspec_path": "./specs/SPEC-07.md",
  "prompt_path": "./prompts/SPEC-07.md",
  "prompt": "Prioritize correctness over speed.",
  "parallel": "yes",
  "model": "claude-sonnet-4-6",
  "effort": "high"
}
```

Guidance:

- put durable project rules in `master_prompt.md`
- put execution-specific instructions in `prompt` or `prompt_path`
- use `prompt` for short one-off nudges
- use `prompt_path` for longer structured task instructions
- avoid duplicate techspec basenames unless you want timestamp-suffixed `exec_id`s

## Reading the Outputs

For each wave run:

- `logs/<wave_ts>/<exec_id>.prompt.md`: exact assembled prompt sent to the CLI
- `logs/<wave_ts>/<exec_id>.log`: stdout and stderr from the CLI
- `output/<exec_id>/`: deliverables written by the agent
- `state.json`: latest tracked worktree path and last status

Use the prompt file first when debugging agent behavior. It is the audit record of what the runner actually sent.

## Failure Handling

If one execution fails:

- the rest of the current wave still continues
- the final process exit code becomes `1`
- the failed execution is marked `failed` in `state.json`

Typical causes:

- bad `config.json`
- missing techspec or prompt file
- broken CLI authentication
- invalid `claude` or `codex` flags for the installed version
- worktree creation failure

Recovery steps:

1. Inspect the corresponding `logs/<wave_ts>/<exec_id>.log`.
2. Inspect `logs/<wave_ts>/<exec_id>.prompt.md`.
3. Fix the config, prompt, environment, or repo issue.
4. Re-run `./run.sh`.

## Worktree Hygiene

The runner intentionally does not remove worktrees.

Inspect active worktrees:

```bash
git -C /path/to/repo worktree list
```

Remove a stale worktree manually when you no longer need it:

```bash
git -C /path/to/repo worktree remove /path/to/repo/.worktrees/01_SPEC-01
```

If you also want to delete the branch:

```bash
git -C /path/to/repo branch -D 01_SPEC-01
```

Be careful: branch deletion is destructive.

## Upgrading

Refresh an installed runner:

```bash
./install.sh --upgrade /path/to/installed/wave-runner
```

Current upgrade behavior replaces only `run.sh`. It does not overwrite:

- `config.json`
- `master_prompt.md`
- `specs/`
- `prompts/`
- `logs/`
- `output/`
- `state.json`

## Operational Checks

Before a real run:

1. Confirm `jq`, `git`, and the selected AI CLI are installed.
2. Confirm the CLI is already authenticated.
3. Confirm `git_dir` points at the intended repository root.
4. Confirm `master_prompt.md` reflects current project constraints.
5. Confirm each execution writes to the intended output area.
6. Run `./run.sh --dry-run` and inspect the batch plan.

## Current Limitations

- no retries
- no verdict aggregation
- no DAG scheduling
- no worktree cleanup
- no live multipane viewer
- no automatic CLI version detection
