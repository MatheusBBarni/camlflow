module StringMap = Map.Make (String)

let ( let* ) = Result.bind

type value_kind = User | Agent | Skill

type value_info = {
  value_typ : Ir.typ;
  value_kind : value_kind;
  value_loc : Loc.t;
}

type constructor_info = {
  ctor_parent : Ir.typ;
  ctor_args : Ir.typ list;
  ctor_loc : Loc.t;
}

type field_info = {
  field_parent : Ir.typ;
  field_typ : Ir.typ;
  field_loc : Loc.t;
}

type module_signature = {
  module_name : Syntax.Ast.qname;
  types : Ir.type_decl StringMap.t;
  values : value_info StringMap.t;
  constructors : constructor_info list StringMap.t;
  fields : field_info list StringMap.t;
}

type t = {
  modules : module_signature StringMap.t;
  current_module : module_signature;
  opened : Syntax.Ast.qname list;
  locals : value_info StringMap.t;
}

let empty_signature module_name =
  { module_name; types = StringMap.empty; values = StringMap.empty; constructors = StringMap.empty; fields = StringMap.empty }

let module_key = Syntax.Ast.string_of_qname

let short_name name =
  match List.rev name with
  | head :: _ -> head
  | [] -> invalid_arg "empty qualified name"

let add_type_decl (signature : module_signature) (decl : Ir.type_decl) : module_signature =
  let type_key = short_name decl.Ir.type_name in
  let types = StringMap.add type_key decl signature.types in
  let constructors, fields =
    match decl.Ir.type_kind with
    | Ir.Alias _ -> (signature.constructors, signature.fields)
    | Ir.Record record_fields ->
        let field_parent = Ir.TRecord decl.Ir.type_name in
        let fields =
          List.fold_left
            (fun acc field ->
              let existing = match StringMap.find_opt field.Ir.field_name acc with Some items -> items | None -> [] in
              let item = { field_parent; field_typ = field.Ir.field_typ; field_loc = field.Ir.field_loc } in
              StringMap.add field.Ir.field_name (item :: existing) acc)
            signature.fields record_fields
        in
        (signature.constructors, fields)
    | Ir.Variant ctors ->
        let ctor_parent = Ir.TVariant decl.Ir.type_name in
        let constructors =
          List.fold_left
            (fun acc ctor ->
              let existing = match StringMap.find_opt ctor.Ir.ctor_name acc with Some items -> items | None -> [] in
              let item = { ctor_parent; ctor_args = ctor.Ir.ctor_args; ctor_loc = ctor.Ir.ctor_loc } in
              StringMap.add ctor.Ir.ctor_name (item :: existing) acc)
            signature.constructors ctors
        in
        (constructors, signature.fields)
  in
  { signature with types; constructors; fields }

let add_value (signature : module_signature) ~(name : string) (value : value_info) : module_signature =
  { signature with values = StringMap.add name value signature.values }

let current_value (env : t) name =
  match StringMap.find_opt name env.locals with
  | Some value -> Some value
  | None -> StringMap.find_opt name env.current_module.values

let lookup_module (env : t) (name : Syntax.Ast.qname) : (module_signature, string) result =
  if env.current_module.module_name = name then Ok env.current_module
  else
    let requested = short_name name in
    if String.equal (short_name env.current_module.module_name) requested then
      Ok env.current_module
    else
      match StringMap.find_opt (module_key name) env.modules with
      | Some signature -> Ok signature
      | None ->
          let candidates =
            env.modules |> StringMap.bindings
            |> List.filter_map (fun (_key, signature) ->
                   if String.equal (short_name signature.module_name) requested then
                     Some signature
                   else None)
          in
          (match candidates with
          | [ signature ] -> Ok signature
          | [] -> Error (Printf.sprintf "unknown module %s" (module_key name))
          | _ -> Error (Printf.sprintf "ambiguous module %s" (module_key name)))

let find_opened_modules (env : t) : module_signature list =
  List.filter_map (fun name -> StringMap.find_opt (module_key name) env.modules) env.opened

let unique_or_error kind name items =
  match items with
  | [] -> Error (Printf.sprintf "unbound %s %s" kind name)
  | [ item ] -> Ok item
  | _ -> Error (Printf.sprintf "ambiguous %s %s" kind name)

let lookup_value (env : t) (name : Syntax.Ast.qname) : (value_info, string) result =
  match List.rev name with
  | [] -> Error "empty value name"
  | short_name :: rev_mod ->
      let module_path = List.rev rev_mod in
      if module_path = [] then
        (match current_value env short_name with
        | Some value -> Ok value
        | None ->
            let candidates =
              find_opened_modules env
              |> List.filter_map (fun signature -> StringMap.find_opt short_name signature.values)
            in
            unique_or_error "value" short_name candidates)
      else
        let* signature = lookup_module env module_path in
        match StringMap.find_opt short_name signature.values with
        | Some value -> Ok value
        | None -> Error (Printf.sprintf "unbound value %s" (Syntax.Ast.string_of_qname name))

let lookup_type_decl (env : t) (name : Syntax.Ast.qname) : (Ir.type_decl, string) result =
  match List.rev name with
  | [] -> Error "empty type name"
  | short_name :: rev_mod ->
      let module_path = List.rev rev_mod in
      if module_path = [] then
        let local = StringMap.find_opt short_name env.current_module.types in
        (match local with
        | Some decl -> Ok decl
        | None ->
            let candidates =
              find_opened_modules env
              |> List.filter_map (fun signature -> StringMap.find_opt short_name signature.types)
            in
            unique_or_error "type" short_name candidates)
      else
        let* signature = lookup_module env module_path in
        match StringMap.find_opt short_name signature.types with
        | Some decl -> Ok decl
        | None -> Error (Printf.sprintf "unbound type %s" (Syntax.Ast.string_of_qname name))

let lookup_constructor (env : t) (name : Syntax.Ast.qname) : (constructor_info, string) result =
  match List.rev name with
  | [] -> Error "empty constructor name"
  | short_name :: rev_mod ->
      let module_path = List.rev rev_mod in
      if module_path = [] then
        let local =
          match StringMap.find_opt short_name env.current_module.constructors with
          | Some items -> items
          | None -> []
        in
        if local <> [] then unique_or_error "constructor" short_name local
        else
          let candidates =
            find_opened_modules env
            |> List.concat_map (fun signature ->
                   match StringMap.find_opt short_name signature.constructors with
                   | Some items -> items
                   | None -> [])
          in
          unique_or_error "constructor" short_name candidates
      else
        let* signature = lookup_module env module_path in
        let candidates =
          match StringMap.find_opt short_name signature.constructors with
          | Some items -> items
          | None -> []
        in
        unique_or_error "constructor" (Syntax.Ast.string_of_qname name) candidates

let lookup_field (env : t) (name : string) : (field_info, string) result =
  let local =
    match StringMap.find_opt name env.current_module.fields with Some items -> items | None -> []
  in
  if local <> [] then unique_or_error "field" name local
  else
    let candidates =
      find_opened_modules env
      |> List.concat_map (fun signature ->
             match StringMap.find_opt name signature.fields with Some items -> items | None -> [])
    in
    unique_or_error "field" name candidates

let with_local (env : t) (name : string) (value : value_info) : t =
  { env with locals = StringMap.add name value env.locals }

let with_locals (env : t) (values : (string * value_info) list) : t =
  let locals = List.fold_left (fun acc (name, value) -> StringMap.add name value acc) env.locals values in
  { env with locals }

let with_opened (env : t) (opened : Syntax.Ast.qname) : t = { env with opened = env.opened @ [ opened ] }

let create modules current_module =
  { modules; current_module; opened = []; locals = StringMap.empty }

let built_in_types = [ "string"; "int"; "bool"; "float"; "unit"; "list"; "option" ]

let is_builtin_type name = List.mem name built_in_types
