module StringSet = Set.Make (String)

let ( let* ) = Result.bind

let schema_uri = "https://json-schema.org/draft/2020-12/schema"
let type_key = Syntax.Ast.string_of_qname

let assoc fields = `Assoc fields
let string value = `String value
let bool value = `Bool value
let int value = `Int value
let list values = `List values

let string_list values = list (List.map string values)

let merge_assoc_fields extra = function
  | `Assoc fields -> Ok (`Assoc (extra @ fields))
  | _ -> Error "internal schema error: expected object schema"

let object_schema properties required =
  assoc
    [
      ("type", string "object");
      ("properties", assoc properties);
      ("required", string_list required);
      ("additionalProperties", bool false);
    ]

let tuple_schema items =
  assoc
    [
      ("type", string "array");
      ("prefixItems", list items);
      ("items", bool false);
      ("minItems", int (List.length items));
      ("maxItems", int (List.length items));
    ]

type state = {
  types : Value.type_index;
  mutable defs : (string * Yojson.Safe.t) list;
  mutable in_progress : StringSet.t;
}

let add_definition state name schema =
  state.defs <- (name, schema) :: List.remove_assoc name state.defs

let ref_schema name = assoc [ ("$ref", string ("#/$defs/" ^ name)) ]

let all_results results =
  let rec aux acc = function
    | [] -> Ok (List.rev acc)
    | Ok value :: rest -> aux (value :: acc) rest
    | Error error :: _ -> Error error
  in
  aux [] results

let constructor_schema ctor_name payload =
  match payload with
  | [] -> object_schema [ ("tag", assoc [ ("const", string ctor_name) ]) ] [ "tag" ]
  | [ value ] ->
      object_schema
        [
          ("tag", assoc [ ("const", string ctor_name) ]);
          ("value", value);
        ]
        [ "tag"; "value" ]
  | values ->
      object_schema
        [
          ("tag", assoc [ ("const", string ctor_name) ]);
          ("values", tuple_schema values);
        ]
        [ "tag"; "values" ]

let option_schema inner =
  assoc
    [
      ("oneOf", list [ constructor_schema "None" []; constructor_schema "Some" [ inner ] ]);
    ]

let variant_schema ctors = assoc [ ("oneOf", list ctors) ]

let rec schema_for_type state typ =
  match typ with
  | Ir.TString -> Ok (assoc [ ("type", string "string") ])
  | Ir.TInt -> Ok (assoc [ ("type", string "integer") ])
  | Ir.TBool -> Ok (assoc [ ("type", string "boolean") ])
  | Ir.TFloat -> Ok (assoc [ ("type", string "number") ])
  | Ir.TUnit -> Ok (assoc [ ("type", string "null") ])
  | Ir.TList inner ->
      let* inner = schema_for_type state inner in
      Ok (assoc [ ("type", string "array"); ("items", inner) ])
  | Ir.TOption inner ->
      let* inner = schema_for_type state inner in
      Ok (option_schema inner)
  | Ir.TTuple items ->
      let* items = all_results (List.map (schema_for_type state) items) in
      Ok (tuple_schema items)
  | Ir.TRecord name | Ir.TVariant name ->
      let* () = ensure_named_definition state name in
      Ok (ref_schema (type_key name))
  | Ir.TFunc _ -> Error "cannot generate JSON Schema for function type"

and ensure_named_definition state name =
  let key = type_key name in
  if List.mem_assoc key state.defs || StringSet.mem key state.in_progress then Ok ()
  else (
    state.in_progress <- StringSet.add key state.in_progress;
    let result =
      let* decl = Value.find_type state.types name in
      match decl.Ir.type_kind with
      | Ir.Alias inner -> schema_for_type state inner
      | Ir.Record fields ->
          let* properties =
            all_results
              (List.map
                 (fun field ->
                   let* schema = schema_for_type state field.Ir.field_typ in
                   Ok (field.Ir.field_name, schema))
                 fields)
          in
          Ok
            (object_schema properties
               (List.map (fun field -> field.Ir.field_name) fields))
      | Ir.Variant ctors ->
          let* ctors =
            all_results
              (List.map
                 (fun ctor ->
                   let* payload =
                     all_results (List.map (schema_for_type state) ctor.Ir.ctor_args)
                   in
                   Ok (constructor_schema ctor.Ir.ctor_name payload))
                 ctors)
          in
          Ok (variant_schema ctors)
    in
    state.in_progress <- StringSet.remove key state.in_progress;
    match result with
    | Ok schema ->
        add_definition state key schema;
        Ok ()
    | Error _ as error -> error)

let of_type ~types typ =
  let state = { types; defs = []; in_progress = StringSet.empty } in
  let* root = schema_for_type state typ in
  let defs = List.sort (fun (lhs, _) (rhs, _) -> String.compare lhs rhs) state.defs in
  let extra_fields =
    match defs with
    | [] -> [ ("$schema", string schema_uri) ]
    | defs ->
        [
          ("$schema", string schema_uri);
          ("$defs", assoc defs);
        ]
  in
  merge_assoc_fields extra_fields root

let unwrap_schema_root = function
  | `Assoc fields ->
      let defs =
        match List.assoc_opt "$defs" fields with Some (`Assoc defs) -> defs | _ -> []
      in
      let inner_fields =
        List.filter
          (fun (name, _) -> name <> "$schema" && name <> "$defs")
          fields
      in
      Ok (`Assoc inner_fields, defs)
  | _ -> Error "provider schema must be a JSON object"

let wrapped_response_schema schema =
  let* inner_schema, defs = unwrap_schema_root schema in
  Ok
    (`Assoc
      (([
          ("$schema", `String schema_uri);
          ("type", `String "object");
          ("properties", `Assoc [ ("result", inner_schema) ]);
          ("required", `List [ `String "result" ]);
          ("additionalProperties", `Bool false);
        ])
      @ match defs with [] -> [] | defs -> [ ("$defs", `Assoc defs) ]))

let unwrap_wrapped_response_json = function
  | `Assoc fields ->
      let result_values, extra_fields =
        List.fold_left
          (fun (results, extras) (name, value) ->
            if String.equal name "result" then (value :: results, extras)
            else (results, name :: extras))
          ([], []) fields
      in
      let result_values = List.rev result_values in
      let extra_fields =
        extra_fields |> List.sort_uniq String.compare
      in
      (match (result_values, extra_fields) with
      | [ result ], [] -> Ok result
      | [], _ | _ :: _ :: _, _ ->
          Error "model response wrapper must contain exactly one result field"
      | [ _ ], extra_fields ->
          Error
            (Printf.sprintf
               "model response wrapper must not contain extra field(s): %s"
               (String.concat ", " extra_fields)))
  | _ -> Error "model response wrapper must be a JSON object"
