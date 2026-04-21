# How To Use Waverunner

This file is meant to be read by either a human or an AI coding agent. Its main job is to help an AI agent fill in `config.json` correctly and create any missing prompt artifacts the wave needs.

## Goal

Set up Waverunner for the current project without adding one-off orchestration logic to the core product repo.

The AI agent should:

1. Read `config.json` in this installed Waverunner directory.
2. Understand the project task list provided by the human.
3. Update `config.json` so the wave matches those tasks.
4. Create any missing referenced artifacts such as:
   - `master_prompt.md`
   - techspec markdown files
   - prompt markdown files
5. Keep those artifacts in sensible project-owned locations.
6. Avoid inventing extra orchestration code inside the product repo unless it is directly needed for the actual project work.

## Config Rules

`config.json` is read by `run.sh` from this installed directory.

Top-level fields:

- `cli`: `claude` or `codex`
- `project_root`: root path of the core project
- `git_dir`: git repository root, usually the same as `project_root`
- `master_prompt_path`: project-wide prompt file used for every execution
- `output_base`: base directory for wave outputs, usually `./output`
- `max_parallel`: maximum allowed size of any parallel batch; default is `3`
- `claude_max_turns`: optional for `claude`; defaults to `300`
- `executions`: ordered list of execution entries

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

That entry runs nothing. It only breaks batches.

## Scheduling Rules

- Consecutive `parallel: "yes"` entries form one parallel batch.
- `parallel: "no"` runs alone.
- If more tasks are needed than `max_parallel` allows in one batch, insert `{ "parallel": "no" }` entries manually.
- Keep tasks parallel only when they are safe to run independently.

## Artifact Guidance

The AI agent may create missing files referenced by `config.json`.

Recommended pattern:

- put stable project-wide rules in `master_prompt.md`
- put one task per techspec file when work should be isolated
- use `prompt_path` for longer execution instructions
- use inline `prompt` only for short nudges

The runner does not require these files to live inside the Waverunner install directory. They can live anywhere in the core project, as long as the paths in `config.json` are correct.

## Suggested Agent Workflow

1. Read this file.
2. Read the installed `config.json`.
3. Inspect the core project structure and existing specs/prompts.
4. Convert the human’s requested tasks into a wave plan.
5. Create any missing prompt/spec artifacts.
6. Update `config.json`.
7. Run `./run.sh --check` or `./run.sh --dry-run` from the installed Waverunner directory if asked.

## Suggested Prompt For The Core Project AI Agent

Use this as a starting point and adapt it to the project:

```text
Refer to <path-to-waverunner>/howtouse.md and set up Waverunner for this project. Update the installed config.json to match the tasks I give you, create any missing prompt/spec/master-prompt artifacts the config needs, keep the orchestration inside Waverunner rather than the core repo, and then show me the resulting wave plan.
```
