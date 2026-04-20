let find = function
  | Provider.Codex -> Providers_codex.adapter
  | Provider.Opencode -> Providers_opencode.adapter
  | Provider.Claude_code -> Providers_claude_code.adapter
  | Provider.Claude_cli -> Providers_claude_cli.adapter
