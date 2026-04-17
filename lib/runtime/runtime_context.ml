type named_handler =
  name:string ->
  input:Yojson.Safe.t ->
  return_type:Ir.typ ->
  types:Value.type_index ->
  (Yojson.Safe.t, string) result

type inline_agent_provider =
  name:string ->
  definition:Ir.agent_definition ->
  input:Yojson.Safe.t ->
  return_type:Ir.typ ->
  types:Value.type_index ->
  (Yojson.Safe.t, string) result

type prompt_skill_provider =
  name:string ->
  markdown:string ->
  input:Yojson.Safe.t ->
  return_type:Ir.typ ->
  types:Value.type_index ->
  (Yojson.Safe.t, string) result

type invocation_kind =
  | Bound_agent
  | Bound_skill
  | Local_prompt_skill
  | Inline_agent

type invocation = {
  invocation_kind : invocation_kind;
  invocation_name : string;
  invocation_input : Yojson.Safe.t;
  invocation_return_type : Ir.typ;
  invocation_types : Value.type_index;
  invocation_working_directory : string option;
  invocation_skills_directory : string option;
  invocation_markdown : string option;
  invocation_definition : Ir.agent_definition option;
}

type default_provider = invocation -> (Yojson.Safe.t, string) result

type effect_observer = invocation -> output:Yojson.Safe.t -> unit

type cancellation_check = unit -> (unit, string) result

type t = {
  working_directory : string option;
  skills_directory : string option;
  agent_handlers : (string * named_handler) list;
  skill_handlers : (string * named_handler) list;
  inline_agent_provider : inline_agent_provider;
  prompt_skill_provider : prompt_skill_provider;
  default_provider : default_provider;
  effect_observer : effect_observer;
  cancellation_check : cancellation_check;
}

let default_named_handler ~name:_ ~input:_ ~return_type ~types =
  Value.default_json types return_type

let default_inline_agent_provider ~name:_ ~definition:_ ~input:_ ~return_type ~types =
  Value.default_json types return_type

let default_prompt_skill_provider ~name:_ ~markdown:_ ~input:_ ~return_type ~types =
  Value.default_json types return_type

let default_provider invocation =
  Value.default_json invocation.invocation_types invocation.invocation_return_type

let ignore_effect _invocation ~output:_ = ()
let default_cancellation_check () = Ok ()

let empty =
  {
    working_directory = None;
    skills_directory = None;
    agent_handlers = [];
    skill_handlers = [];
    inline_agent_provider = default_inline_agent_provider;
    prompt_skill_provider = default_prompt_skill_provider;
    default_provider;
    effect_observer = ignore_effect;
    cancellation_check = default_cancellation_check;
  }

let with_working_directory context working_directory =
  { context with working_directory = Some working_directory }

let with_skills_directory context skills_directory =
  { context with skills_directory = Some skills_directory }

let with_agent_handler context name handler =
  { context with agent_handlers = (name, handler) :: context.agent_handlers }

let with_skill_handler context name handler =
  { context with skill_handlers = (name, handler) :: context.skill_handlers }

let with_inline_agent_provider context inline_agent_provider =
  { context with inline_agent_provider }

let with_prompt_skill_provider context prompt_skill_provider =
  { context with prompt_skill_provider }

let with_default_provider context default_provider =
  { context with default_provider }

let with_effect_observer context effect_observer =
  { context with effect_observer }

let with_cancellation_check context cancellation_check =
  { context with cancellation_check }

let find_agent_handler context name = List.assoc_opt name context.agent_handlers
let find_skill_handler context name = List.assoc_opt name context.skill_handlers
