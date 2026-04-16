type name = Codex

type reasoning = Low | Medium | High | Max

type sandbox = Read_only | Workspace_write | Danger_full_access

type config = {
  key : string;
  value : string;
}

type settings = {
  provider : name option;
  model : string option;
  reasoning : reasoning option;
  provider_profile : string option;
  provider_configs : config list;
  sandbox : sandbox;
  allow_write_dirs : string list;
  trace_provider : bool;
}

type adapter = {
  provider_name : name;
  preflight : working_directory:string -> settings:settings -> (unit, string) result;
  build_runtime_context :
    working_directory:string ->
    settings:settings ->
    Runtime.Context.t ->
    (Runtime.Context.t, string) result;
}

let default_sandbox = Workspace_write

let default_settings =
  {
    provider = None;
    model = None;
    reasoning = None;
    provider_profile = None;
    provider_configs = [];
    sandbox = default_sandbox;
    allow_write_dirs = [];
    trace_provider = false;
  }

let name_to_string = function Codex -> "codex"
let available_provider_names = [ name_to_string Codex ]

let name_of_string = function
  | "codex" -> Ok Codex
  | other ->
      Error
        (Printf.sprintf "unknown provider %s; expected one of: %s" other
           (String.concat ", " available_provider_names))

let reasoning_to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Max -> "max"

let reasoning_names = List.map reasoning_to_string [ Low; Medium; High; Max ]

let reasoning_of_string = function
  | "low" -> Ok Low
  | "medium" -> Ok Medium
  | "high" -> Ok High
  | "max" -> Ok Max
  | other ->
      Error
        (Printf.sprintf "unknown reasoning level %s; expected one of: %s" other
           (String.concat ", " reasoning_names))

let sandbox_to_string = function
  | Read_only -> "read-only"
  | Workspace_write -> "workspace-write"
  | Danger_full_access -> "danger-full-access"

let sandbox_names =
  List.map sandbox_to_string [ Read_only; Workspace_write; Danger_full_access ]

let sandbox_of_string = function
  | "read-only" -> Ok Read_only
  | "workspace-write" -> Ok Workspace_write
  | "danger-full-access" -> Ok Danger_full_access
  | other ->
      Error
        (Printf.sprintf "unknown sandbox %s; expected one of: %s" other
           (String.concat ", " sandbox_names))

let config_to_string config = config.key ^ "=" ^ config.value

let config_of_string text =
  match String.index_opt text '=' with
  | None -> Error "provider config must have the form key=value"
  | Some 0 -> Error "provider config key cannot be empty"
  | Some index ->
      let key = String.sub text 0 index in
      let value =
        String.sub text (index + 1) (String.length text - index - 1)
      in
      Ok { key; value }

let has_explicit_provider_inputs settings =
  settings.model <> None || settings.reasoning <> None
  || settings.provider_profile <> None
  || settings.provider_configs <> []
  || settings.sandbox <> default_sandbox
  || settings.allow_write_dirs <> [] || settings.trace_provider

let settings_are_default settings =
  settings.provider = None && not (has_explicit_provider_inputs settings)
