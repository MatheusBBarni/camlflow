let string_of_kind = function
  | Runtime.Context.Bound_agent -> "bound-agent"
  | Runtime.Context.Bound_skill -> "bound-skill"
  | Runtime.Context.Local_prompt_skill -> "local-prompt-skill"
  | Runtime.Context.Inline_agent -> "inline-agent"

let role_label = function
  | Runtime.Context.Bound_agent | Runtime.Context.Inline_agent -> "agent"
  | Runtime.Context.Bound_skill | Runtime.Context.Local_prompt_skill -> "skill"

let rec string_of_typ = function
  | Ir.TString -> "string"
  | Ir.TInt -> "int"
  | Ir.TBool -> "bool"
  | Ir.TFloat -> "float"
  | Ir.TUnit -> "unit"
  | Ir.TList inner -> Printf.sprintf "%s list" (string_of_typ inner)
  | Ir.TOption inner -> Printf.sprintf "%s option" (string_of_typ inner)
  | Ir.TTuple items -> String.concat " * " (List.map string_of_typ items)
  | Ir.TRecord name | Ir.TVariant name -> Syntax.Ast.string_of_qname name
  | Ir.TFunc (params, result) ->
      let params =
        List.map
          (fun (param : Ir.param_type) ->
            match param.Ir.param_label with
            | None -> string_of_typ param.Ir.param_typ
            | Some label -> Printf.sprintf "%s:%s" label (string_of_typ param.Ir.param_typ))
          params
      in
      String.concat " -> " (params @ [ string_of_typ result ])

type rendered = {
  prompt : string;
  requested_model : string option;
  unsupported_settings : string list;
}

let metadata_json definition =
  `Assoc
    (List.map
       (fun (name, literal) -> (name, Ir.literal_to_yojson literal))
       definition.Ir.define_metadata)

let format_path = function None -> "(not set)" | Some path -> path

let lines_of_invocation invocation output_schema =
  let kind = string_of_kind invocation.Runtime.Context.invocation_kind in
  let role = role_label invocation.Runtime.Context.invocation_kind in
  let base_lines =
    [
      Printf.sprintf "You are executing a CamlFlow %s step." role;
      (match invocation.Runtime.Context.invocation_kind with
      | Runtime.Context.Bound_agent ->
          "This is a bound agent with no inline prompt text. Infer intent from the agent name and typed input."
      | Runtime.Context.Bound_skill ->
          "This is a bound skill with no local prompt markdown. Behave like a narrow, tool-like operation."
      | Runtime.Context.Local_prompt_skill ->
          "This is a local prompt-backed skill. Follow the provided SKILL.md instructions closely."
      | Runtime.Context.Inline_agent ->
          "This is an inline agent definition. Follow the provided system prompt and metadata closely.");
      "Return only JSON that matches the required schema exactly.";
      "Do not wrap the JSON in markdown fences and do not add commentary.";
      "";
      "Invocation:";
      Printf.sprintf "- kind: %s" kind;
      Printf.sprintf "- role: %s" role;
      Printf.sprintf "- name: %s" invocation.Runtime.Context.invocation_name;
      Printf.sprintf "- working_directory: %s"
        (format_path invocation.Runtime.Context.invocation_working_directory);
      Printf.sprintf "- skills_directory: %s"
        (format_path invocation.Runtime.Context.invocation_skills_directory);
      Printf.sprintf "- declared_return_type: %s"
        (string_of_typ invocation.Runtime.Context.invocation_return_type);
      "";
      "Input JSON:";
      Yojson.Safe.pretty_to_string invocation.Runtime.Context.invocation_input;
      "";
      "Output JSON Schema:";
      Yojson.Safe.pretty_to_string output_schema;
    ]
  in
  match invocation.Runtime.Context.invocation_kind with
  | Runtime.Context.Local_prompt_skill ->
      base_lines
      @ [ ""; "Local skill specification (SKILL.md):" ]
      @ (match invocation.Runtime.Context.invocation_markdown with
        | Some markdown -> [ markdown ]
        | None -> [ "(missing SKILL.md content)" ])
  | Runtime.Context.Inline_agent ->
      let definition =
        match invocation.Runtime.Context.invocation_definition with
        | Some definition -> definition
        | None ->
            {
              Ir.define_model = None;
              define_temperature = None;
              define_system_prompt = None;
              define_metadata = [];
              define_loc = Loc.none;
            }
      in
      base_lines
      @ [
          "";
          Printf.sprintf "Inline agent declared model: %s"
            (match definition.Ir.define_model with
            | Some model -> model
            | None -> "(not set)");
          Printf.sprintf "Inline agent declared temperature: %s"
            (match definition.Ir.define_temperature with
            | Some temperature -> string_of_float temperature
            | None -> "(not set)");
          "Inline agent system prompt:";
          (match definition.Ir.define_system_prompt with
          | Some prompt -> prompt
          | None -> "(not set)");
          "Inline agent metadata (JSON):";
          Yojson.Safe.pretty_to_string (metadata_json definition);
        ]
  | Runtime.Context.Bound_agent | Runtime.Context.Bound_skill -> base_lines

let render ~invocation ~output_schema =
  let requested_model, unsupported_settings =
    match invocation.Runtime.Context.invocation_definition with
    | Some definition ->
        ( definition.Ir.define_model,
          (match definition.Ir.define_temperature with
          | Some _ -> [ "temperature" ]
          | None -> []) )
    | None -> (None, [])
  in
  Ok
    {
      prompt = String.concat "\n" (lines_of_invocation invocation output_schema);
      requested_model;
      unsupported_settings;
    }
