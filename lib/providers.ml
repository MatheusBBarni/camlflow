let find = function
  | Provider.Codex -> Providers_codex.adapter
  | Provider.Opencode -> Providers_opencode.adapter
