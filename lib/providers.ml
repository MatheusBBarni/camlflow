let codex_not_implemented =
  Error "provider codex integration not implemented yet"

let codex : Provider.adapter =
  {
    provider_name = Provider.Codex;
    preflight = (fun ~working_directory:_ ~settings:_ -> codex_not_implemented);
    build_runtime_context =
      (fun ~working_directory:_ ~settings:_ _context -> codex_not_implemented);
  }

let find = function Provider.Codex -> codex
