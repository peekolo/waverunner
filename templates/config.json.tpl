{
  "cli": "{{CLI}}",
  "project_root": "{{PROJECT_ROOT}}",
  "git_dir": "{{GIT_DIR}}",
  "master_prompt_path": "{{PROJECT_ROOT}}/master_prompt.md",
  "output_base": "./output",
  "max_parallel": 3,
  "executions": [
    {
      "techspec_path": "{{PROJECT_ROOT}}/specs/SPEC-XX.md",
      "prompt_path": "{{PROJECT_ROOT}}/prompts/SPEC-XX.md",
      "parallel": "no",
{{EXAMPLE_MODEL_BLOCK}}
    }
  ]
}
