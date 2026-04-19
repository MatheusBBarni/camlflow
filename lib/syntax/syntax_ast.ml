type qname = string list

type literal =
  | LString of string
  | LInt of int
  | LBool of bool
  | LFloat of float
  | LUnit

type type_expr = { type_loc : Loc.t; type_desc : type_expr_desc }

and type_expr_desc =
  | TEConstr of qname * type_expr list
  | TETuple of type_expr list
  | TEArrow of param_type * type_expr

and param_type = {
  param_type_loc : Loc.t;
  param_label : string option;
  param_typ : type_expr;
}

type record_field = {
  field_name : string;
  field_type : type_expr;
  field_loc : Loc.t;
}

type variant_ctor = {
  ctor_name : string;
  ctor_args : type_expr list;
  ctor_loc : Loc.t;
}

type type_decl_kind =
  | Type_alias of type_expr
  | Type_record of record_field list
  | Type_variant of variant_ctor list

type type_decl = {
  type_name : string;
  type_kind : type_decl_kind;
  type_decl_loc : Loc.t;
}

type param = {
  param_name : string;
  param_label : string option;
  param_annotation : type_expr option;
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

and expr = { expr_loc : Loc.t; expr_desc : expr_desc }

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
  binding_annotation : type_expr option;
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
  callable_return_type : type_expr;
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

let empty : program = { root_module = [ "Main" ]; modules = [] }

let qname_of_longident (lid : Longident.t) : qname =
  try Longident.flatten lid
  with Invalid_argument _ ->
    invalid_arg "applicative longidents are unsupported"

let string_of_qname (name : qname) : string = String.concat "." name

let qname_of_string (value : string) : qname =
  value |> String.split_on_char '.'
  |> List.filter (fun part -> String.length part > 0)
