module StringMap = Map.Make (String)

type t =
  | VString of string
  | VInt of int
  | VBool of bool
  | VFloat of float
  | VUnit
  | VList of t list
  | VTuple of t list
  | VRecord of (string * t) list
  | VVariant of string * t list

type type_index = Ir.type_decl StringMap.t

let ( let* ) = Result.bind
let type_key = Syntax.Ast.string_of_qname

let type_index_of_program (program : Ir.program) : type_index =
  List.fold_left
    (fun acc module_ ->
      List.fold_left
        (fun acc decl ->
          match decl with
          | Ir.TypeDecl decl ->
              StringMap.add (type_key decl.Ir.type_name) decl acc
          | _ -> acc)
        acc module_.Ir.module_decls)
    StringMap.empty program.Ir.modules

let find_type types name =
  match StringMap.find_opt (type_key name) types with
  | Some decl -> Ok decl
  | None -> Error (Printf.sprintf "unknown type %s" (type_key name))

let all results =
  let rec aux acc = function
    | [] -> Ok (List.rev acc)
    | Ok value :: rest -> aux (value :: acc) rest
    | Error error :: _ -> Error error
  in
  aux [] results

let rec default_value types = function
  | Ir.TString -> Ok (VString "")
  | Ir.TInt -> Ok (VInt 0)
  | Ir.TBool -> Ok (VBool false)
  | Ir.TFloat -> Ok (VFloat 0.0)
  | Ir.TUnit -> Ok VUnit
  | Ir.TList _ -> Ok (VList [])
  | Ir.TOption _ -> Ok (VVariant ("None", []))
  | Ir.TTuple items ->
      let* items = all (List.map (default_value types) items) in
      Ok (VTuple items)
  | Ir.TRecord name -> (
      let* decl = find_type types name in
      match decl.Ir.type_kind with
      | Ir.Record fields ->
          let* fields =
            all
              (List.map
                 (fun field ->
                   let* value = default_value types field.Ir.field_typ in
                   Ok (field.Ir.field_name, value))
                 fields)
          in
          Ok (VRecord fields)
      | _ -> Error (Printf.sprintf "%s is not a record type" (type_key name)))
  | Ir.TVariant name -> (
      let* decl = find_type types name in
      match decl.Ir.type_kind with
      | Ir.Variant (ctor :: _) ->
          let* values =
            all (List.map (default_value types) ctor.Ir.ctor_args)
          in
          Ok (VVariant (ctor.Ir.ctor_name, values))
      | Ir.Variant [] ->
          Error
            (Printf.sprintf "variant %s has no constructors" (type_key name))
      | _ -> Error (Printf.sprintf "%s is not a variant type" (type_key name)))
  | Ir.TFunc _ -> Error "cannot synthesize function values"

let rec to_json types typ value =
  match (typ, value) with
  | Ir.TString, VString text -> Ok (`String text)
  | Ir.TInt, VInt number -> Ok (`Int number)
  | Ir.TBool, VBool value -> Ok (`Bool value)
  | Ir.TFloat, VFloat value -> Ok (`Float value)
  | Ir.TUnit, VUnit -> Ok `Null
  | Ir.TList inner, VList items ->
      let* items = all (List.map (to_json types inner) items) in
      Ok (`List items)
  | Ir.TTuple types_list, VTuple values ->
      if List.length types_list <> List.length values then
        Error "tuple arity mismatch"
      else
        let* items = all (List.map2 (to_json types) types_list values) in
        Ok (`List items)
  | Ir.TRecord name, VRecord fields -> (
      let* decl = find_type types name in
      match decl.Ir.type_kind with
      | Ir.Record expected_fields ->
          let* encoded =
            all
              (List.map
                 (fun field ->
                   match List.assoc_opt field.Ir.field_name fields with
                   | Some value ->
                       let* json = to_json types field.Ir.field_typ value in
                       Ok (field.Ir.field_name, json)
                   | None ->
                       Error
                         (Printf.sprintf "missing record field %s"
                            field.Ir.field_name))
                 expected_fields)
          in
          Ok (`Assoc encoded)
      | _ -> Error (Printf.sprintf "%s is not a record type" (type_key name)))
  | Ir.TOption inner, VVariant ("None", []) ->
      Ok (`Assoc [ ("tag", `String "None") ])
  | Ir.TOption inner, VVariant ("Some", [ value ]) ->
      let* json = to_json types inner value in
      Ok (`Assoc [ ("tag", `String "Some"); ("value", json) ])
  | Ir.TOption _, VVariant _ -> Error "invalid option value"
  | Ir.TVariant name, VVariant (ctor_name, values) -> (
      let* decl = find_type types name in
      match decl.Ir.type_kind with
      | Ir.Variant ctors -> (
          let* ctor =
            match
              List.find_opt
                (fun ctor -> String.equal ctor.Ir.ctor_name ctor_name)
                ctors
            with
            | Some ctor -> Ok ctor
            | None -> Error (Printf.sprintf "unknown constructor %s" ctor_name)
          in
          if List.length ctor.Ir.ctor_args <> List.length values then
            Error "constructor arity mismatch"
          else
            let* payload =
              all (List.map2 (to_json types) ctor.Ir.ctor_args values)
            in
            match payload with
            | [] -> Ok (`Assoc [ ("tag", `String ctor_name) ])
            | [ value ] ->
                Ok (`Assoc [ ("tag", `String ctor_name); ("value", value) ])
            | values ->
                Ok
                  (`Assoc
                     [ ("tag", `String ctor_name); ("values", `List values) ]))
      | _ -> Error (Printf.sprintf "%s is not a variant type" (type_key name)))
  | _ -> Error "value does not match declared type"

let rec of_json types typ json =
  match (typ, json) with
  | Ir.TString, `String text -> Ok (VString text)
  | Ir.TInt, `Int number -> Ok (VInt number)
  | Ir.TBool, `Bool value -> Ok (VBool value)
  | Ir.TFloat, `Float value -> Ok (VFloat value)
  | Ir.TFloat, `Int value -> Ok (VFloat (float_of_int value))
  | Ir.TUnit, `Null -> Ok VUnit
  | Ir.TList inner, `List items ->
      let* items = all (List.map (of_json types inner) items) in
      Ok (VList items)
  | Ir.TTuple types_list, `List items ->
      if List.length types_list <> List.length items then
        Error "tuple JSON arity mismatch"
      else
        let* values = all (List.map2 (of_json types) types_list items) in
        Ok (VTuple values)
  | Ir.TRecord name, `Assoc fields -> (
      let* decl = find_type types name in
      match decl.Ir.type_kind with
      | Ir.Record expected_fields ->
          let* values =
            all
              (List.map
                 (fun field ->
                   match List.assoc_opt field.Ir.field_name fields with
                   | Some json ->
                       let* value = of_json types field.Ir.field_typ json in
                       Ok (field.Ir.field_name, value)
                   | None ->
                       Error
                         (Printf.sprintf "missing JSON field %s"
                            field.Ir.field_name))
                 expected_fields)
          in
          Ok (VRecord values)
      | _ -> Error (Printf.sprintf "%s is not a record type" (type_key name)))
  | Ir.TOption inner, `Assoc fields -> (
      let tag = List.assoc_opt "tag" fields in
      match tag with
      | Some (`String "None") -> Ok (VVariant ("None", []))
      | Some (`String "Some") ->
          let* json =
            match List.assoc_opt "value" fields with
            | Some json -> Ok json
            | None -> Error "Some requires a value field"
          in
          let* value = of_json types inner json in
          Ok (VVariant ("Some", [ value ]))
      | _ -> Error "invalid option JSON encoding")
  | Ir.TVariant name, `Assoc fields -> (
      let* ctor_name =
        match List.assoc_opt "tag" fields with
        | Some (`String tag) -> Ok tag
        | _ -> Error "variant JSON requires a tag field"
      in
      let* decl = find_type types name in
      match decl.Ir.type_kind with
      | Ir.Variant ctors ->
          let* ctor =
            match
              List.find_opt
                (fun ctor -> String.equal ctor.Ir.ctor_name ctor_name)
                ctors
            with
            | Some ctor -> Ok ctor
            | None -> Error (Printf.sprintf "unknown constructor %s" ctor_name)
          in
          let payload_jsons =
            match
              ( ctor.Ir.ctor_args,
                List.assoc_opt "value" fields,
                List.assoc_opt "values" fields )
            with
            | [], _, _ -> Ok []
            | [ _ ], Some json, _ -> Ok [ json ]
            | _ :: _ :: _, _, Some (`List values) -> Ok values
            | [ _ ], None, _ -> Error "constructor payload missing value field"
            | _ :: _ :: _, _, _ ->
                Error "constructor payload missing values field"
          in
          let* payload_jsons = payload_jsons in
          if List.length payload_jsons <> List.length ctor.Ir.ctor_args then
            Error "constructor payload arity mismatch"
          else
            let* payload =
              all (List.map2 (of_json types) ctor.Ir.ctor_args payload_jsons)
            in
            Ok (VVariant (ctor_name, payload))
      | _ -> Error (Printf.sprintf "%s is not a variant type" (type_key name)))
  | _ -> Error "JSON value does not match declared type"

let default_json types typ =
  let* value = default_value types typ in
  to_json types typ value
