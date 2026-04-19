type kind = Runtime.Context.invocation_kind

type t = {
  kind : kind;
  name : string;
  input_json : Yojson.Safe.t;
  declared_return_type : string;
  output_schema : Yojson.Safe.t;
  working_directory : string option;
  skills_directory : string option;
  skill_markdown : string option;
  inline_definition : Ir.agent_definition option;
  rendered_prompt : string;
  requested_model : string option;
  unsupported_settings : string list;
  step_index : int option;
  run_id : string option;
}

let ( let* ) = Result.bind

let kind_to_string = function
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
            | Some label ->
                Printf.sprintf "%s:%s" label (string_of_typ param.Ir.param_typ))
          params
      in
      String.concat " -> " (params @ [ string_of_typ result ])

let null_or to_json = function None -> `Null | Some value -> to_json value
let string_option = null_or (fun value -> `String value)
let int_option = null_or (fun value -> `Int value)

let of_invocation ?step_index ?run_id (invocation : Runtime.Context.invocation)
    =
  let* output_schema =
    Provider_schema.of_type ~types:invocation.Runtime.Context.invocation_types
      invocation.Runtime.Context.invocation_return_type
  in
  let* rendered = Provider_prompt.render ~invocation ~output_schema in
  Ok
    {
      kind = invocation.invocation_kind;
      name = invocation.invocation_name;
      input_json = invocation.invocation_input;
      declared_return_type = string_of_typ invocation.invocation_return_type;
      output_schema;
      working_directory = invocation.invocation_working_directory;
      skills_directory = invocation.invocation_skills_directory;
      skill_markdown = invocation.invocation_markdown;
      inline_definition = invocation.invocation_definition;
      rendered_prompt = rendered.Provider_prompt.prompt;
      requested_model = rendered.Provider_prompt.requested_model;
      unsupported_settings = rendered.Provider_prompt.unsupported_settings;
      step_index;
      run_id;
    }

let to_yojson (request : t) : Yojson.Safe.t =
  `Assoc
    [
      ("kind", `String (kind_to_string request.kind));
      ("role", `String (role_label request.kind));
      ("name", `String request.name);
      ("input", request.input_json);
      ("declaredReturnType", `String request.declared_return_type);
      ("outputSchema", request.output_schema);
      ("workingDirectory", string_option request.working_directory);
      ("skillsDirectory", string_option request.skills_directory);
      ("skillMarkdown", string_option request.skill_markdown);
      ( "inlineDefinition",
        null_or Ir.agent_definition_to_yojson request.inline_definition );
      ("renderedPrompt", `String request.rendered_prompt);
      ("requestedModel", string_option request.requested_model);
      ( "unsupportedSettings",
        `List
          (List.map (fun value -> `String value) request.unsupported_settings)
      );
      ("step", int_option request.step_index);
      ("runId", string_option request.run_id);
    ]
