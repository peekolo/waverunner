# Runbook

## First Run

1. Install the runner:

```bash
./install.sh
```

If you accept the `.gitignore` prompt during install, the installer appends a comment plus the whole wave-runner directory path to `<project_root>/.gitignore`.

The installer also copies `howtouse.md` and prints a ready-to-paste prompt for your project AI agent.

2. Edit `config.json`.
3. Point `master_prompt_path` at your real project-wide prompt file.
4. Replace the baked-in example execution with your real execution list.
5. Point each execution at the real techspec and prompt files you want to use.
6. Set `max_parallel` if you want something other than the default of `3`.
7. Keep each parallel batch at or below `max_parallel` and insert `{ "parallel": "no" }` breaks manually when needed.
8. Inspect the plan:

```bash
./run.sh --dry-run
```

You can also validate the config and inspect tracked execution state without launching anything:

```bash
./run.sh --check
```

If a previous wave partially completed, resume it without rerunning already completed matching executions:

```bash
./run.sh --resume
```

9. Launch the wave:

```bash
./run.sh
```

The installed adapters currently run in these unattended modes:

- `claude`: `-p --allowedTools ... --max-turns 100 --output-format json --dangerously-skip-permissions`
- `codex`: `exec -a never -s workspace-write`

That means the wave should not pause for approval prompts. Claude currently uses the same dangerous-permissions pattern that already works in your other project, constrained by an explicit allowed-tools list.

## Recommended Workflow

1. Keep the file referenced by `master_prompt_path` stable and project-wide.
2. Keep each execution prompt short and task-specific.
3. Use `parallel: "yes"` only for tasks that can safely run independently.
4. Keep each parallel batch at `max_parallel` executions or fewer.
5. Insert `{ "parallel": "no" }` when you need a hard separation between two parallel waves.
6. Tail individual log files while a batch is running.

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

- put durable project rules in the file referenced by `master_prompt_path`
- put execution-specific instructions in `prompt` or `prompt_path`
- use `prompt` for short one-off nudges
- use `prompt_path` for longer structured task instructions
- duplicate techspec basenames are allowed; Waverunner now adds deterministic numeric suffixes to keep `exec_id`s stable across resume runs

## Reading the Outputs

For each wave run:

- `logs/<wave_ts>/<exec_id>.prompt.md`: exact assembled prompt sent to the CLI
- `logs/<wave_ts>/<exec_id>.log`: stdout and stderr from the CLI
- `output/<wave_ts>/<exec_id>/`: deliverables written by the agent
- `state.json`: latest tracked worktree path, status, exit code, failure class, and resume fingerprint, including `skipped` when fail-fast prevents later executions from launching

Use the prompt file first when debugging agent behavior. It is the audit record of what the runner actually sent.

`--resume` skips executions that are already `done` when their stored fingerprint still matches the current CLI/model/prompt/spec inputs. If those inputs change, the execution runs again.

## Failure Handling

If one execution fails:

- any tasks already running in the same parallel batch still continue
- later batches are not launched
- the final process exit code becomes `1`
- the failed execution is marked `failed` in `state.json`
- the runner prints a failure class such as `rate_limit`, `auth_error`, `network_error`, `permission_denied`, `dirty_worktree`, `worktree_error`, or `unknown`

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

If you only want to validate the wave and inspect current tracked state before rerunning, use:

```bash
./run.sh --check
```

If part of the previous wave already completed successfully and you want to continue from there, use:

```bash
./run.sh --resume
```

## Worktree Hygiene

The runner intentionally does not remove worktrees.

If a tracked worktree is reused on a later run, it must be clean. If it is dirty, Waverunner fails that execution and asks you to clean or remove the worktree manually before rerunning.

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
./install.sh --upgrade /path/to/installed/waverunner
```

Current upgrade behavior replaces:

- `run.sh`
- `howtouse.md`
- `adapters/<cli>.sh`

It does not overwrite:

- `config.json`
- `logs/`
- `output/`
- `state.json`

## Operational Checks

Before a real run:

1. Confirm `jq`, `git`, and the selected AI CLI are installed.
2. Confirm the CLI is already authenticated.
3. Confirm `git_dir` points at the intended repository root.
4. Confirm the file referenced by `master_prompt_path` reflects current project constraints.
5. Confirm no parallel batch exceeds `max_parallel`.
6. Confirm each execution writes to the intended output area.
7. Run `./run.sh --dry-run` and inspect the batch plan.

## Current Limitations

- no retries
- no verdict aggregation
- no DAG scheduling
- no worktree cleanup
- no live multipane viewer
- no automatic CLI version detection
- no automatic batch splitting when config exceeds `max_parallel`
