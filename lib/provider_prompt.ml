module StringSet = Set.Make (String)

let ( let* ) = Result.bind

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
            | Some label ->
                Printf.sprintf "%s:%s" label (string_of_typ param.Ir.param_typ))
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
let indent depth = String.make (depth * 2) ' '
let bullet depth text = indent depth ^ "- " ^ text

let pretty_json_lines depth json =
  Yojson.Safe.pretty_to_string json
  |> String.split_on_char '\n'
  |> List.map (fun line -> indent depth ^ line)

let rec json_shape_label = function
  | Ir.TString -> "JSON string"
  | Ir.TInt -> "JSON integer"
  | Ir.TBool -> "JSON boolean"
  | Ir.TFloat -> "JSON number"
  | Ir.TUnit -> "JSON null"
  | Ir.TList inner -> Printf.sprintf "JSON array of %s" (string_of_typ inner)
  | Ir.TOption inner ->
      Printf.sprintf "tagged JSON option carrying %s" (string_of_typ inner)
  | Ir.TTuple items ->
      Printf.sprintf "fixed JSON array tuple (%s)"
        (String.concat ", " (List.map string_of_typ items))
  | Ir.TRecord name ->
      Printf.sprintf "JSON object matching record %s"
        (Syntax.Ast.string_of_qname name)
  | Ir.TVariant name ->
      Printf.sprintf "tagged JSON variant %s" (Syntax.Ast.string_of_qname name)
  | Ir.TFunc _ -> "function values are not JSON encodable"

let constructor_example_json types variant_name ctor =
  let* payload =
    Value.all (List.map (Value.default_value types) ctor.Ir.ctor_args)
  in
  Value.to_json types (Ir.TVariant variant_name)
    (Value.VVariant (ctor.Ir.ctor_name, payload))

let option_some_example_json types inner =
  let* value = Value.default_value types inner in
  Value.to_json types (Ir.TOption inner) (Value.VVariant ("Some", [ value ]))

let rec contract_detail_lines ~types ~seen depth typ =
  match typ with
  | Ir.TRecord name -> (
      let key = Syntax.Ast.string_of_qname name in
      if StringSet.mem key seen then []
      else
        let seen = StringSet.add key seen in
        match Value.find_type types name with
        | Error _ -> []
        | Ok decl -> (
            match decl.Ir.type_kind with
            | Ir.Record fields ->
                let field_lines =
                  List.concat_map
                    (fun field ->
                      let detail =
                        bullet (depth + 1)
                          (Printf.sprintf "%s: %s" field.Ir.field_name
                             (json_shape_label field.Ir.field_typ))
                      in
                      detail
                      :: contract_detail_lines ~types ~seen (depth + 2)
                           field.Ir.field_typ)
                    fields
                in
                bullet depth
                  (Printf.sprintf
                     "%s is encoded as a JSON object with required fields:" key)
                :: field_lines
            | Ir.Alias inner ->
                bullet depth
                  (Printf.sprintf "%s is an alias for %s" key
                     (string_of_typ inner))
                :: contract_detail_lines ~types ~seen (depth + 1) inner
            | Ir.Variant _ -> []))
  | Ir.TVariant name -> (
      let key = Syntax.Ast.string_of_qname name in
      if StringSet.mem key seen then []
      else
        let seen = StringSet.add key seen in
        match Value.find_type types name with
        | Error _ -> []
        | Ok decl -> (
            match decl.Ir.type_kind with
            | Ir.Variant ctors ->
                let ctor_lines =
                  List.concat_map
                    (fun ctor ->
                      let example =
                        match constructor_example_json types name ctor with
                        | Ok json -> Yojson.Safe.to_string json
                        | Error _ ->
                            Printf.sprintf {|{"tag":"%s"}|} ctor.Ir.ctor_name
                      in
                      bullet (depth + 1)
                        (Printf.sprintf "%s -> %s" ctor.Ir.ctor_name example)
                      :: List.concat_map
                           (contract_detail_lines ~types ~seen (depth + 2))
                           ctor.Ir.ctor_args)
                    ctors
                in
                bullet depth
                  (Printf.sprintf "%s is encoded as a tagged JSON variant:" key)
                :: ctor_lines
            | Ir.Alias inner ->
                bullet depth
                  (Printf.sprintf "%s is an alias for %s" key
                     (string_of_typ inner))
                :: contract_detail_lines ~types ~seen (depth + 1) inner
            | Ir.Record _ -> []))
  | Ir.TOption inner ->
      let none_json =
        Yojson.Safe.to_string (`Assoc [ ("tag", `String "None") ])
      in
      let some_json =
        match option_some_example_json types inner with
        | Ok json -> Yojson.Safe.to_string json
        | Error _ -> {|{"tag":"Some","value":...}|}
      in
      bullet depth
        (Printf.sprintf "%s uses tagged JSON constructors:" (string_of_typ typ))
      :: [
           bullet (depth + 1) (Printf.sprintf "None -> %s" none_json);
           bullet (depth + 1) (Printf.sprintf "Some -> %s" some_json);
         ]
      @ contract_detail_lines ~types ~seen (depth + 2) inner
  | Ir.TList inner -> contract_detail_lines ~types ~seen depth inner
  | Ir.TTuple items ->
      List.concat_map (contract_detail_lines ~types ~seen depth) items
  | Ir.TString | Ir.TInt | Ir.TBool | Ir.TFloat | Ir.TUnit | Ir.TFunc _ -> []

let response_contract_lines invocation =
  let types = invocation.Runtime.Context.invocation_types in
  let return_type = invocation.Runtime.Context.invocation_return_type in
  let header_lines =
    [
      "Declared response contract:";
      Printf.sprintf "- The CamlFlow step output must have type %s."
        (string_of_typ return_type);
      "- Use the declared return type and JSON schema below for output shape.";
      "- The system prompt only defines task intent; it does not need to \
       restate the response structure.";
    ]
  in
  let example_lines =
    match Value.default_json types return_type with
    | Ok json ->
        [ "- Canonical JSON encoding example:" ] @ pretty_json_lines 1 json
    | Error _ -> []
  in
  header_lines @ example_lines
  @ contract_detail_lines ~types ~seen:StringSet.empty 1 return_type

let lines_of_invocation invocation output_schema =
  let kind = string_of_kind invocation.Runtime.Context.invocation_kind in
  let role = role_label invocation.Runtime.Context.invocation_kind in
  let base_lines =
    [
      Printf.sprintf "You are executing a CamlFlow %s step." role;
      (match invocation.Runtime.Context.invocation_kind with
      | Runtime.Context.Bound_agent ->
          "This is a bound agent with no inline prompt text. Infer intent from \
           the agent name and typed input."
      | Runtime.Context.Bound_skill ->
          "This is a bound skill with no local prompt markdown. Behave like a \
           narrow, tool-like operation."
      | Runtime.Context.Local_prompt_skill ->
          "This is a local prompt-backed skill. Follow the provided SKILL.md \
           instructions closely."
      | Runtime.Context.Inline_agent ->
          "This is an inline agent definition. Follow the provided system \
           prompt and metadata closely.");
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
    ]
    @ response_contract_lines invocation
    @ [ ""; "Output JSON Schema:"; Yojson.Safe.pretty_to_string output_schema ]
  in
  match invocation.Runtime.Context.invocation_kind with
  | Runtime.Context.Local_prompt_skill -> (
      base_lines
      @ [ ""; "Local skill specification (SKILL.md):" ]
      @
      match invocation.Runtime.Context.invocation_markdown with
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
          match definition.Ir.define_temperature with
          | Some _ -> [ "temperature" ]
          | None -> [] )
    | None -> (None, [])
  in
  Ok
    {
      prompt = String.concat "\n" (lines_of_invocation invocation output_schema);
      requested_model;
      unsupported_settings;
    }
