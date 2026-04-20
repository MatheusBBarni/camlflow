type qname = Syntax.Ast.qname

type literal = Syntax.Ast.literal =
  | LString of string
  | LInt of int
  | LBool of bool
  | LFloat of float
  | LUnit

type typ =
  | TString
  | TInt
  | TBool
  | TFloat
  | TUnit
  | TList of typ
  | TOption of typ
  | TTuple of typ list
  | TRecord of qname
  | TVariant of qname
  | TFunc of param_type list * typ

and param_type = { param_label : string option; param_typ : typ }

type record_field = { field_name : string; field_typ : typ; field_loc : Loc.t }

type variant_ctor = {
  ctor_name : string;
  ctor_args : typ list;
  ctor_loc : Loc.t;
}

type type_decl_kind =
  | Alias of typ
  | Record of record_field list
  | Variant of variant_ctor list

type type_decl = {
  type_name : qname;
  type_kind : type_decl_kind;
  type_loc : Loc.t;
}

type param = {
  param_name : string;
  param_label : string option;
  param_typ : typ;
  param_loc : Loc.t;
}

type pattern = { pattern_loc : Loc.t; pattern_desc : pattern_desc }

and pattern_desc =
  | PWildcard
  | PVar of string
  | PLiteral of literal
  | PTuple of pattern list
  | PRecord of (string * pattern) list
  | PConstruct of qname * pattern list

type expr = { expr_loc : Loc.t; expr_desc : expr_desc }

and expr_desc =
  | ELiteral of literal
  | EVar of qname
  | ETuple of expr list
  | ERecord of (string * expr) list
  | EField of expr * string
  | EConstruct of qname * expr list
  | ELet of binding * expr
  | ELetStar of let_star * expr
  | EIf of expr * expr * expr
  | EMatch of expr * case list
  | EApply of expr * argument list
  | ELambda of param list * expr

and argument = { arg_label : string option; arg_value : expr; arg_loc : Loc.t }

and let_star = {
  let_star_name : string;
  let_star_value : expr;
  let_star_loc : Loc.t;
}

and case = { case_pattern : pattern; case_body : expr; case_loc : Loc.t }

and binding = {
  binding_name : string;
  binding_params : param list;
  binding_type : typ;
  binding_body : expr;
  binding_recursive : bool;
  binding_loc : Loc.t;
}

type callable_kind = Agent | Skill

type agent_definition = {
  define_model : string option;
  define_temperature : float option;
  define_system_prompt : string option;
  define_metadata : (string * literal) list;
  define_loc : Loc.t;
}

type callable_body = Bind_target of string | Inline_agent of agent_definition

type callable_decl = {
  callable_name : string;
  callable_params : param_type list;
  callable_return_type : typ;
  callable_body : callable_body;
  callable_kind : callable_kind;
  callable_loc : Loc.t;
}

type decl =
  | TypeDecl of type_decl
  | LetDecl of binding
  | AgentDecl of callable_decl
  | SkillDecl of callable_decl
  | OpenDecl of qname * Loc.t

type module_ = {
  module_name : qname;
  module_path : string;
  module_decls : decl list;
  module_loc : Loc.t;
}

type program = { root_module : qname; modules : module_ list }

let ir_version = "0.1.0"
let ( let* ) = Result.bind

let all results =
  let rec aux acc = function
    | [] -> Ok (List.rev acc)
    | Ok value :: rest -> aux (value :: acc) rest
    | Error error :: _ -> Error error
  in
  aux [] results

let string_of_yojson = function
  | `String value -> Ok value
  | _ -> Error "expected string"

let bool_of_yojson = function
  | `Bool value -> Ok value
  | _ -> Error "expected bool"

let required_json_object_field fields name =
  match List.assoc_opt name fields with
  | Some (`Assoc nested) -> Ok (`Assoc nested)
  | Some _ -> Error (Printf.sprintf "field %s must be an object" name)
  | None -> Error (Printf.sprintf "missing field %s" name)

let required_field fields name parse =
  match List.assoc_opt name fields with
  | Some value -> parse value
  | None -> Error (Printf.sprintf "missing field %s" name)

let required_list_field fields name parse =
  match List.assoc_opt name fields with
  | Some (`List items) -> all (List.map parse items)
  | Some _ -> Error (Printf.sprintf "field %s must be a list" name)
  | None -> Error (Printf.sprintf "missing field %s" name)

let with_loc loc data = `Assoc [ ("loc", Loc.to_yojson loc); ("data", data) ]

let qname_to_yojson (name : qname) : Yojson.Safe.t =
  `String (Syntax.Ast.string_of_qname name)

let qname_of_yojson = function
  | `String value -> Ok (Syntax.Ast.qname_of_string value)
  | _ -> Error "expected string qualified name"

let literal_to_yojson = function
  | LString value ->
      `Assoc [ ("kind", `String "string"); ("value", `String value) ]
  | LInt value -> `Assoc [ ("kind", `String "int"); ("value", `Int value) ]
  | LBool value -> `Assoc [ ("kind", `String "bool"); ("value", `Bool value) ]
  | LFloat value ->
      `Assoc [ ("kind", `String "float"); ("value", `Float value) ]
  | LUnit -> `Assoc [ ("kind", `String "unit") ]

let literal_of_yojson = function
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String "string") -> (
          match List.assoc_opt "value" fields with
          | Some (`String value) -> Ok (LString value)
          | _ -> Error "expected string literal value")
      | Some (`String "int") -> (
          match List.assoc_opt "value" fields with
          | Some (`Int value) -> Ok (LInt value)
          | _ -> Error "expected int literal value")
      | Some (`String "bool") -> (
          match List.assoc_opt "value" fields with
          | Some (`Bool value) -> Ok (LBool value)
          | _ -> Error "expected bool literal value")
      | Some (`String "float") -> (
          match List.assoc_opt "value" fields with
          | Some (`Float value) -> Ok (LFloat value)
          | Some (`Int value) -> Ok (LFloat (float_of_int value))
          | _ -> Error "expected float literal value")
      | Some (`String "unit") -> Ok LUnit
      | _ -> Error "unknown literal kind")
  | _ -> Error "expected literal JSON object"

let rec typ_to_yojson = function
  | TString -> `Assoc [ ("kind", `String "string") ]
  | TInt -> `Assoc [ ("kind", `String "int") ]
  | TBool -> `Assoc [ ("kind", `String "bool") ]
  | TFloat -> `Assoc [ ("kind", `String "float") ]
  | TUnit -> `Assoc [ ("kind", `String "unit") ]
  | TList inner ->
      `Assoc [ ("kind", `String "list"); ("inner", typ_to_yojson inner) ]
  | TOption inner ->
      `Assoc [ ("kind", `String "option"); ("inner", typ_to_yojson inner) ]
  | TTuple items ->
      `Assoc
        [
          ("kind", `String "tuple");
          ("items", `List (List.map typ_to_yojson items));
        ]
  | TRecord name ->
      `Assoc [ ("kind", `String "record"); ("name", qname_to_yojson name) ]
  | TVariant name ->
      `Assoc [ ("kind", `String "variant"); ("name", qname_to_yojson name) ]
  | TFunc (params, result) ->
      `Assoc
        [
          ("kind", `String "func");
          ("params", `List (List.map param_type_to_yojson params));
          ("result", typ_to_yojson result);
        ]

and typ_of_yojson = function
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String "string") -> Ok TString
      | Some (`String "int") -> Ok TInt
      | Some (`String "bool") -> Ok TBool
      | Some (`String "float") -> Ok TFloat
      | Some (`String "unit") -> Ok TUnit
      | Some (`String "list") ->
          let* inner = required_field fields "inner" typ_of_yojson in
          Ok (TList inner)
      | Some (`String "option") ->
          let* inner = required_field fields "inner" typ_of_yojson in
          Ok (TOption inner)
      | Some (`String "tuple") ->
          let* items = required_list_field fields "items" typ_of_yojson in
          Ok (TTuple items)
      | Some (`String "record") ->
          let* name = required_field fields "name" qname_of_yojson in
          Ok (TRecord name)
      | Some (`String "variant") ->
          let* name = required_field fields "name" qname_of_yojson in
          Ok (TVariant name)
      | Some (`String "func") ->
          let* params =
            required_list_field fields "params" param_type_of_yojson
          in
          let* result = required_field fields "result" typ_of_yojson in
          Ok (TFunc (params, result))
      | _ -> Error "unknown type kind")
  | _ -> Error "expected type JSON object"

and param_type_to_yojson (param : param_type) : Yojson.Safe.t =
  `Assoc
    [
      ( "label",
        match param.param_label with
        | None -> `Null
        | Some label -> `String label );
      ("typ", typ_to_yojson param.param_typ);
    ]

and param_type_of_yojson = function
  | `Assoc fields ->
      let label =
        match List.assoc_opt "label" fields with
        | Some (`String value) -> Ok (Some value)
        | Some `Null | None -> Ok None
        | _ -> Error "expected null or string param label"
      in
      let* param_label = label in
      let* param_typ = required_field fields "typ" typ_of_yojson in
      Ok { param_label; param_typ }
  | _ -> Error "expected param type JSON object"

let param_to_yojson (param : param) : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String param.param_name);
      ( "label",
        match param.param_label with
        | None -> `Null
        | Some value -> `String value );
      ("typ", typ_to_yojson param.param_typ);
      ("loc", Loc.to_yojson param.param_loc);
    ]

let param_of_yojson = function
  | `Assoc fields ->
      let* param_name = required_field fields "name" string_of_yojson in
      let param_label =
        match List.assoc_opt "label" fields with
        | Some (`String value) -> Ok (Some value)
        | Some `Null | None -> Ok None
        | _ -> Error "expected null or string param label"
      in
      let* param_label = param_label in
      let* param_typ = required_field fields "typ" typ_of_yojson in
      let* param_loc = required_field fields "loc" Loc.of_yojson in
      Ok { param_name; param_label; param_typ; param_loc }
  | _ -> Error "expected param JSON object"

let record_field_to_yojson (field : record_field) : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String field.field_name);
      ("typ", typ_to_yojson field.field_typ);
      ("loc", Loc.to_yojson field.field_loc);
    ]

let record_field_of_yojson = function
  | `Assoc fields ->
      let* field_name = required_field fields "name" string_of_yojson in
      let* field_typ = required_field fields "typ" typ_of_yojson in
      let* field_loc = required_field fields "loc" Loc.of_yojson in
      Ok { field_name; field_typ; field_loc }
  | _ -> Error "expected record field JSON object"

let variant_ctor_to_yojson (ctor : variant_ctor) : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String ctor.ctor_name);
      ("args", `List (List.map typ_to_yojson ctor.ctor_args));
      ("loc", Loc.to_yojson ctor.ctor_loc);
    ]

let variant_ctor_of_yojson = function
  | `Assoc fields ->
      let* ctor_name = required_field fields "name" string_of_yojson in
      let* ctor_args = required_list_field fields "args" typ_of_yojson in
      let* ctor_loc = required_field fields "loc" Loc.of_yojson in
      Ok { ctor_name; ctor_args; ctor_loc }
  | _ -> Error "expected variant ctor JSON object"

let type_decl_kind_to_yojson = function
  | Alias typ ->
      `Assoc [ ("kind", `String "alias"); ("typ", typ_to_yojson typ) ]
  | Record fields ->
      `Assoc
        [
          ("kind", `String "record");
          ("fields", `List (List.map record_field_to_yojson fields));
        ]
  | Variant ctors ->
      `Assoc
        [
          ("kind", `String "variant");
          ("ctors", `List (List.map variant_ctor_to_yojson ctors));
        ]

let type_decl_kind_of_yojson = function
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String "alias") ->
          let* typ = required_field fields "typ" typ_of_yojson in
          Ok (Alias typ)
      | Some (`String "record") ->
          let* items =
            required_list_field fields "fields" record_field_of_yojson
          in
          Ok (Record items)
      | Some (`String "variant") ->
          let* items =
            required_list_field fields "ctors" variant_ctor_of_yojson
          in
          Ok (Variant items)
      | _ -> Error "unknown type declaration kind")
  | _ -> Error "expected type declaration kind JSON object"

let type_decl_to_yojson (decl : type_decl) : Yojson.Safe.t =
  `Assoc
    [
      ("name", qname_to_yojson decl.type_name);
      ("kind", type_decl_kind_to_yojson decl.type_kind);
      ("loc", Loc.to_yojson decl.type_loc);
    ]

let type_decl_of_yojson = function
  | `Assoc fields ->
      let* type_name = required_field fields "name" qname_of_yojson in
      let* type_kind = required_field fields "kind" type_decl_kind_of_yojson in
      let* type_loc = required_field fields "loc" Loc.of_yojson in
      Ok { type_name; type_kind; type_loc }
  | _ -> Error "expected type declaration JSON object"

let rec pattern_to_yojson (pattern : pattern) : Yojson.Safe.t =
  let body =
    match pattern.pattern_desc with
    | PWildcard -> `Assoc [ ("kind", `String "wildcard") ]
    | PVar name -> `Assoc [ ("kind", `String "var"); ("name", `String name) ]
    | PLiteral lit ->
        `Assoc [ ("kind", `String "literal"); ("value", literal_to_yojson lit) ]
    | PTuple items ->
        `Assoc
          [
            ("kind", `String "tuple");
            ("items", `List (List.map pattern_to_yojson items));
          ]
    | PRecord fields ->
        `Assoc
          [
            ("kind", `String "record");
            ( "fields",
              `List
                (List.map
                   (fun (name, item) ->
                     `Assoc
                       [
                         ("name", `String name);
                         ("pattern", pattern_to_yojson item);
                       ])
                   fields) );
          ]
    | PConstruct (name, args) ->
        `Assoc
          [
            ("kind", `String "construct");
            ("name", qname_to_yojson name);
            ("args", `List (List.map pattern_to_yojson args));
          ]
  in
  with_loc pattern.pattern_loc body

and pattern_of_yojson = function
  | `Assoc fields ->
      let* pattern_loc = required_field fields "loc" Loc.of_yojson in
      let* data = required_json_object_field fields "data" in
      let* pattern_desc = pattern_desc_of_yojson data in
      Ok { pattern_loc; pattern_desc }
  | _ -> Error "expected pattern JSON object"

and pattern_desc_of_yojson = function
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String "wildcard") -> Ok PWildcard
      | Some (`String "var") ->
          let* name = required_field fields "name" string_of_yojson in
          Ok (PVar name)
      | Some (`String "literal") ->
          let* lit = required_field fields "value" literal_of_yojson in
          Ok (PLiteral lit)
      | Some (`String "tuple") ->
          let* items = required_list_field fields "items" pattern_of_yojson in
          Ok (PTuple items)
      | Some (`String "record") ->
          let* fields =
            required_list_field fields "fields" (function
              | `Assoc item_fields ->
                  let* name =
                    required_field item_fields "name" string_of_yojson
                  in
                  let* pattern =
                    required_field item_fields "pattern" pattern_of_yojson
                  in
                  Ok (name, pattern)
              | _ -> Error "expected record pattern field object")
          in
          Ok (PRecord fields)
      | Some (`String "construct") ->
          let* name = required_field fields "name" qname_of_yojson in
          let* args = required_list_field fields "args" pattern_of_yojson in
          Ok (PConstruct (name, args))
      | _ -> Error "unknown pattern kind")
  | _ -> Error "expected pattern body JSON object"

and expr_to_yojson (expr : expr) : Yojson.Safe.t =
  let body =
    match expr.expr_desc with
    | ELiteral lit ->
        `Assoc [ ("kind", `String "literal"); ("value", literal_to_yojson lit) ]
    | EVar name ->
        `Assoc [ ("kind", `String "var"); ("name", qname_to_yojson name) ]
    | ETuple items ->
        `Assoc
          [
            ("kind", `String "tuple");
            ("items", `List (List.map expr_to_yojson items));
          ]
    | ERecord fields ->
        `Assoc
          [
            ("kind", `String "record");
            ( "fields",
              `List
                (List.map
                   (fun (name, item) ->
                     `Assoc
                       [
                         ("name", `String name); ("value", expr_to_yojson item);
                       ])
                   fields) );
          ]
    | EField (target, field) ->
        `Assoc
          [
            ("kind", `String "field");
            ("target", expr_to_yojson target);
            ("field", `String field);
          ]
    | EConstruct (name, args) ->
        `Assoc
          [
            ("kind", `String "construct");
            ("name", qname_to_yojson name);
            ("args", `List (List.map expr_to_yojson args));
          ]
    | ELet (binding, body) ->
        `Assoc
          [
            ("kind", `String "let");
            ("binding", binding_to_yojson binding);
            ("body", expr_to_yojson body);
          ]
    | ELetStar (binding, body) ->
        `Assoc
          [
            ("kind", `String "let_star");
            ("binding", let_star_to_yojson binding);
            ("body", expr_to_yojson body);
          ]
    | EIf (cond, then_branch, else_branch) ->
        `Assoc
          [
            ("kind", `String "if");
            ("cond", expr_to_yojson cond);
            ("then", expr_to_yojson then_branch);
            ("else", expr_to_yojson else_branch);
          ]
    | EMatch (scrutinee, cases) ->
        `Assoc
          [
            ("kind", `String "match");
            ("scrutinee", expr_to_yojson scrutinee);
            ("cases", `List (List.map case_to_yojson cases));
          ]
    | EApply (fn, args) ->
        `Assoc
          [
            ("kind", `String "apply");
            ("fn", expr_to_yojson fn);
            ("args", `List (List.map argument_to_yojson args));
          ]
    | ELambda (params, body) ->
        `Assoc
          [
            ("kind", `String "lambda");
            ("params", `List (List.map param_to_yojson params));
            ("body", expr_to_yojson body);
          ]
  in
  with_loc expr.expr_loc body

and expr_of_yojson = function
  | `Assoc fields ->
      let* expr_loc = required_field fields "loc" Loc.of_yojson in
      let* data = required_json_object_field fields "data" in
      let* expr_desc = expr_desc_of_yojson data in
      Ok { expr_loc; expr_desc }
  | _ -> Error "expected expression JSON object"

and expr_desc_of_yojson = function
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String "literal") ->
          let* value = required_field fields "value" literal_of_yojson in
          Ok (ELiteral value)
      | Some (`String "var") ->
          let* name = required_field fields "name" qname_of_yojson in
          Ok (EVar name)
      | Some (`String "tuple") ->
          let* items = required_list_field fields "items" expr_of_yojson in
          Ok (ETuple items)
      | Some (`String "record") ->
          let* items =
            required_list_field fields "fields" (function
              | `Assoc item_fields ->
                  let* name =
                    required_field item_fields "name" string_of_yojson
                  in
                  let* value =
                    required_field item_fields "value" expr_of_yojson
                  in
                  Ok (name, value)
              | _ -> Error "expected record field object")
          in
          Ok (ERecord items)
      | Some (`String "field") ->
          let* target = required_field fields "target" expr_of_yojson in
          let* field = required_field fields "field" string_of_yojson in
          Ok (EField (target, field))
      | Some (`String "construct") ->
          let* name = required_field fields "name" qname_of_yojson in
          let* args = required_list_field fields "args" expr_of_yojson in
          Ok (EConstruct (name, args))
      | Some (`String "let") ->
          let* binding = required_field fields "binding" binding_of_yojson in
          let* body = required_field fields "body" expr_of_yojson in
          Ok (ELet (binding, body))
      | Some (`String "let_star") ->
          let* binding = required_field fields "binding" let_star_of_yojson in
          let* body = required_field fields "body" expr_of_yojson in
          Ok (ELetStar (binding, body))
      | Some (`String "if") ->
          let* cond = required_field fields "cond" expr_of_yojson in
          let* then_branch = required_field fields "then" expr_of_yojson in
          let* else_branch = required_field fields "else" expr_of_yojson in
          Ok (EIf (cond, then_branch, else_branch))
      | Some (`String "match") ->
          let* scrutinee = required_field fields "scrutinee" expr_of_yojson in
          let* cases = required_list_field fields "cases" case_of_yojson in
          Ok (EMatch (scrutinee, cases))
      | Some (`String "apply") ->
          let* fn = required_field fields "fn" expr_of_yojson in
          let* args = required_list_field fields "args" argument_of_yojson in
          Ok (EApply (fn, args))
      | Some (`String "lambda") ->
          let* params = required_list_field fields "params" param_of_yojson in
          let* body = required_field fields "body" expr_of_yojson in
          Ok (ELambda (params, body))
      | _ -> Error "unknown expression kind")
  | _ -> Error "expected expression body JSON object"

and argument_to_yojson (arg : argument) : Yojson.Safe.t =
  `Assoc
    [
      ( "label",
        match arg.arg_label with None -> `Null | Some value -> `String value );
      ("value", expr_to_yojson arg.arg_value);
      ("loc", Loc.to_yojson arg.arg_loc);
    ]

and argument_of_yojson = function
  | `Assoc fields ->
      let arg_label =
        match List.assoc_opt "label" fields with
        | Some (`String value) -> Ok (Some value)
        | Some `Null | None -> Ok None
        | _ -> Error "expected null or string arg label"
      in
      let* arg_label = arg_label in
      let* arg_value = required_field fields "value" expr_of_yojson in
      let* arg_loc = required_field fields "loc" Loc.of_yojson in
      Ok { arg_label; arg_value; arg_loc }
  | _ -> Error "expected argument JSON object"

and let_star_to_yojson (binding : let_star) : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String binding.let_star_name);
      ("value", expr_to_yojson binding.let_star_value);
      ("loc", Loc.to_yojson binding.let_star_loc);
    ]

and let_star_of_yojson = function
  | `Assoc fields ->
      let* let_star_name = required_field fields "name" string_of_yojson in
      let* let_star_value = required_field fields "value" expr_of_yojson in
      let* let_star_loc = required_field fields "loc" Loc.of_yojson in
      Ok { let_star_name; let_star_value; let_star_loc }
  | _ -> Error "expected let* binding JSON object"

and case_to_yojson (case : case) : Yojson.Safe.t =
  `Assoc
    [
      ("pattern", pattern_to_yojson case.case_pattern);
      ("body", expr_to_yojson case.case_body);
      ("loc", Loc.to_yojson case.case_loc);
    ]

and case_of_yojson = function
  | `Assoc fields ->
      let* case_pattern = required_field fields "pattern" pattern_of_yojson in
      let* case_body = required_field fields "body" expr_of_yojson in
      let* case_loc = required_field fields "loc" Loc.of_yojson in
      Ok { case_pattern; case_body; case_loc }
  | _ -> Error "expected case JSON object"

and binding_to_yojson (binding : binding) : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String binding.binding_name);
      ("params", `List (List.map param_to_yojson binding.binding_params));
      ("type", typ_to_yojson binding.binding_type);
      ("body", expr_to_yojson binding.binding_body);
      ("recursive", `Bool binding.binding_recursive);
      ("loc", Loc.to_yojson binding.binding_loc);
    ]

and binding_of_yojson = function
  | `Assoc fields ->
      let* binding_name = required_field fields "name" string_of_yojson in
      let* binding_params =
        required_list_field fields "params" param_of_yojson
      in
      let* binding_type = required_field fields "type" typ_of_yojson in
      let* binding_body = required_field fields "body" expr_of_yojson in
      let* binding_recursive =
        required_field fields "recursive" bool_of_yojson
      in
      let* binding_loc = required_field fields "loc" Loc.of_yojson in
      Ok
        {
          binding_name;
          binding_params;
          binding_type;
          binding_body;
          binding_recursive;
          binding_loc;
        }
  | _ -> Error "expected binding JSON object"

let callable_kind_to_yojson = function
  | Agent -> `String "agent"
  | Skill -> `String "skill"

let callable_kind_of_yojson = function
  | `String "agent" -> Ok Agent
  | `String "skill" -> Ok Skill
  | _ -> Error "expected callable kind"

let agent_definition_to_yojson (definition : agent_definition) : Yojson.Safe.t =
  `Assoc
    [
      ( "model",
        match definition.define_model with
        | None -> `Null
        | Some value -> `String value );
      ( "temperature",
        match definition.define_temperature with
        | None -> `Null
        | Some value -> `Float value );
      ( "system_prompt",
        match definition.define_system_prompt with
        | None -> `Null
        | Some value -> `String value );
      ( "metadata",
        `List
          (List.map
             (fun (name, value) ->
               `Assoc
                 [ ("name", `String name); ("value", literal_to_yojson value) ])
             definition.define_metadata) );
      ("loc", Loc.to_yojson definition.define_loc);
    ]

let agent_definition_of_yojson = function
  | `Assoc fields ->
      let define_model =
        match List.assoc_opt "model" fields with
        | Some (`String value) -> Ok (Some value)
        | Some `Null | None -> Ok None
        | _ -> Error "expected string or null model"
      in
      let define_temperature =
        match List.assoc_opt "temperature" fields with
        | Some (`Float value) -> Ok (Some value)
        | Some (`Int value) -> Ok (Some (float_of_int value))
        | Some `Null | None -> Ok None
        | _ -> Error "expected float or null temperature"
      in
      let define_system_prompt =
        match List.assoc_opt "system_prompt" fields with
        | Some (`String value) -> Ok (Some value)
        | Some `Null | None -> Ok None
        | _ -> Error "expected string or null system prompt"
      in
      let* define_model = define_model in
      let* define_temperature = define_temperature in
      let* define_system_prompt = define_system_prompt in
      let* define_metadata =
        required_list_field fields "metadata" (function
          | `Assoc item_fields ->
              let* name = required_field item_fields "name" string_of_yojson in
              let* value =
                required_field item_fields "value" literal_of_yojson
              in
              Ok (name, value)
          | _ -> Error "expected metadata item object")
      in
      let* define_loc = required_field fields "loc" Loc.of_yojson in
      Ok
        {
          define_model;
          define_temperature;
          define_system_prompt;
          define_metadata;
          define_loc;
        }
  | _ -> Error "expected agent definition JSON object"

let callable_body_to_yojson = function
  | Bind_target target ->
      `Assoc [ ("kind", `String "bind"); ("target", `String target) ]
  | Inline_agent definition ->
      `Assoc
        [
          ("kind", `String "inline_agent");
          ("definition", agent_definition_to_yojson definition);
        ]

let callable_body_of_yojson = function
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String "bind") ->
          let* target = required_field fields "target" string_of_yojson in
          Ok (Bind_target target)
      | Some (`String "inline_agent") ->
          let* definition =
            required_field fields "definition" agent_definition_of_yojson
          in
          Ok (Inline_agent definition)
      | _ -> Error "unknown callable body kind")
  | _ -> Error "expected callable body JSON object"

let callable_decl_to_yojson (decl : callable_decl) : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String decl.callable_name);
      ("params", `List (List.map param_type_to_yojson decl.callable_params));
      ("return_type", typ_to_yojson decl.callable_return_type);
      ("body", callable_body_to_yojson decl.callable_body);
      ("callable_kind", callable_kind_to_yojson decl.callable_kind);
      ("loc", Loc.to_yojson decl.callable_loc);
    ]

let callable_decl_of_yojson = function
  | `Assoc fields ->
      let* callable_name = required_field fields "name" string_of_yojson in
      let* callable_params =
        required_list_field fields "params" param_type_of_yojson
      in
      let* callable_return_type =
        required_field fields "return_type" typ_of_yojson
      in
      let* callable_body =
        required_field fields "body" callable_body_of_yojson
      in
      let* callable_kind =
        required_field fields "callable_kind" callable_kind_of_yojson
      in
      let* callable_loc = required_field fields "loc" Loc.of_yojson in
      Ok
        {
          callable_name;
          callable_params;
          callable_return_type;
          callable_body;
          callable_kind;
          callable_loc;
        }
  | _ -> Error "expected callable declaration JSON object"

let decl_to_yojson = function
  | TypeDecl decl ->
      `Assoc [ ("kind", `String "type"); ("decl", type_decl_to_yojson decl) ]
  | LetDecl decl ->
      `Assoc [ ("kind", `String "let"); ("decl", binding_to_yojson decl) ]
  | AgentDecl decl ->
      `Assoc
        [ ("kind", `String "agent"); ("decl", callable_decl_to_yojson decl) ]
  | SkillDecl decl ->
      `Assoc
        [ ("kind", `String "skill"); ("decl", callable_decl_to_yojson decl) ]
  | OpenDecl (name, loc) ->
      `Assoc
        [
          ("kind", `String "open");
          ("name", qname_to_yojson name);
          ("loc", Loc.to_yojson loc);
        ]

let decl_of_yojson = function
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String "type") ->
          let* decl = required_field fields "decl" type_decl_of_yojson in
          Ok (TypeDecl decl)
      | Some (`String "let") ->
          let* decl = required_field fields "decl" binding_of_yojson in
          Ok (LetDecl decl)
      | Some (`String "agent") ->
          let* decl = required_field fields "decl" callable_decl_of_yojson in
          Ok (AgentDecl decl)
      | Some (`String "skill") ->
          let* decl = required_field fields "decl" callable_decl_of_yojson in
          Ok (SkillDecl decl)
      | Some (`String "open") ->
          let* name = required_field fields "name" qname_of_yojson in
          let* loc = required_field fields "loc" Loc.of_yojson in
          Ok (OpenDecl (name, loc))
      | _ -> Error "unknown declaration kind")
  | _ -> Error "expected declaration JSON object"

let module_to_yojson (module_ : module_) : Yojson.Safe.t =
  `Assoc
    [
      ("name", qname_to_yojson module_.module_name);
      ("path", `String module_.module_path);
      ("decls", `List (List.map decl_to_yojson module_.module_decls));
      ("loc", Loc.to_yojson module_.module_loc);
    ]

let module_of_yojson = function
  | `Assoc fields ->
      let* module_name = required_field fields "name" qname_of_yojson in
      let* module_path = required_field fields "path" string_of_yojson in
      let* module_decls = required_list_field fields "decls" decl_of_yojson in
      let* module_loc = required_field fields "loc" Loc.of_yojson in
      Ok { module_name; module_path; module_decls; module_loc }
  | _ -> Error "expected module JSON object"

let program_to_yojson (program : program) : Yojson.Safe.t =
  `Assoc
    [
      ("version", `String ir_version);
      ("root_module", qname_to_yojson program.root_module);
      ("modules", `List (List.map module_to_yojson program.modules));
    ]

let program_of_yojson = function
  | `Assoc fields ->
      let* () =
        match List.assoc_opt "version" fields with
        | None -> Ok ()
        | Some (`String version) when String.equal version ir_version -> Ok ()
        | Some (`String version) ->
            Error
              (Printf.sprintf "unsupported IR version %s; expected %s" version
                 ir_version)
        | Some _ -> Error "field version must be a string"
      in
      let* root_module = required_field fields "root_module" qname_of_yojson in
      let* modules = required_list_field fields "modules" module_of_yojson in
      Ok { root_module; modules }
  | _ -> Error "expected program JSON object"

let to_json_string ?(pretty = true) (program : program) : string =
  let json = program_to_yojson program in
  if pretty then Yojson.Safe.pretty_to_string json
  else Yojson.Safe.to_string json

let of_json_string (source : string) : (program, string) result =
  try program_of_yojson (Yojson.Safe.from_string source)
  with Yojson.Json_error message -> Error message
