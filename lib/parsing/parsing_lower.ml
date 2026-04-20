open Asttypes
open Parsetree

exception Error of string

let failf loc fmt =
  Printf.ksprintf
    (fun message ->
      raise
        (Error
           (Printf.sprintf "%s at %s" message
              (Loc.to_string (Loc.of_location loc)))))
    fmt

let loc_of (loc : Location.t) = Loc.of_location loc

type constant_view =
  | Const_integer of string * char option
  | Const_float of string * char option
  | Const_string of string * Location.t * string option
  | Const_char of char

let constant_view (constant : constant) =
  let repr = Obj.repr constant in
  let desc =
    (* OCaml 5.4 wraps constants in a record with pconst_desc/pconst_loc,
       while earlier compilers expose the descriptor variant directly. *)
    if Obj.is_block repr && Obj.tag repr = 0 && Obj.size repr = 2 then
      let maybe_loc = Obj.field repr 1 in
      if
        Obj.is_block maybe_loc
        && Obj.tag maybe_loc = 0
        && Obj.size maybe_loc >= 3
      then Obj.field repr 0
      else repr
    else repr
  in
  match (Obj.tag desc, Obj.size desc) with
  | 0, 2 ->
      Const_integer (Obj.obj (Obj.field desc 0), Obj.obj (Obj.field desc 1))
  | 1, 1 -> Const_char (Obj.obj (Obj.field desc 0))
  | 2, 3 ->
      Const_string
        ( Obj.obj (Obj.field desc 0),
          Obj.obj (Obj.field desc 1),
          Obj.obj (Obj.field desc 2) )
  | 3, 2 -> Const_float (Obj.obj (Obj.field desc 0), Obj.obj (Obj.field desc 1))
  | _ -> failwith "unsupported Parsetree.constant representation"

let is_horizontal_space = function ' ' | '\t' -> true | _ -> false
let is_line_break = function '\n' | '\r' -> true | _ -> false

type rewrite_state =
  | Code of bool
  | String
  | Comment of int
  | Quoted_string of string

let starts_with_keyword source pos keyword =
  let len = String.length source in
  let kw_len = String.length keyword in
  pos + kw_len <= len
  && String.sub source pos kw_len = keyword
  && (pos + kw_len = len
     ||
     match source.[pos + kw_len] with
     | c when is_horizontal_space c || is_line_break c -> true
     | _ -> false)

let is_quoted_string_delimiter_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false

let quoted_string_opener source pos =
  let len = String.length source in
  if pos >= len || source.[pos] <> '{' then None
  else
    let rec loop idx =
      if idx >= len then None
      else
        match source.[idx] with
        | '|' -> Some (String.sub source (pos + 1) (idx - pos - 1), idx + 1)
        | c when is_quoted_string_delimiter_char c -> loop (idx + 1)
        | _ -> None
    in
    loop (pos + 1)

let quoted_string_closes source pos delimiter =
  let len = String.length source in
  let delimiter_len = String.length delimiter in
  pos + delimiter_len + 1 < len
  && source.[pos] = '|'
  && String.sub source (pos + 1) delimiter_len = delimiter
  && source.[pos + delimiter_len + 1] = '}'

let rewrite_custom_declarations (source : string) : string =
  let len = String.length source in
  let buffer = Buffer.create (len + 32) in
  let rec loop pos state =
    if pos >= len then Buffer.contents buffer
    else
      match state with
      | Code true ->
          let ch = source.[pos] in
          if is_horizontal_space ch then (
            Buffer.add_char buffer ch;
            loop (pos + 1) (Code true))
          else if starts_with_keyword source pos "agent" then (
            Buffer.add_string buffer "let[@camlflow.agent]";
            loop (pos + 5) (Code false))
          else if starts_with_keyword source pos "skill" then (
            Buffer.add_string buffer "let[@camlflow.skill]";
            loop (pos + 5) (Code false))
          else code_char pos
      | Code false -> code_char pos
      | String ->
          let ch = source.[pos] in
          if ch = '\\' && pos + 1 < len then (
            Buffer.add_substring buffer source pos 2;
            loop (pos + 2) String)
          else (
            Buffer.add_char buffer ch;
            loop (pos + 1) (if ch = '"' then Code false else String))
      | Comment depth ->
          if pos + 1 < len && source.[pos] = '(' && source.[pos + 1] = '*' then (
            Buffer.add_string buffer "(*";
            loop (pos + 2) (Comment (depth + 1)))
          else if pos + 1 < len && source.[pos] = '*' && source.[pos + 1] = ')'
          then (
            Buffer.add_string buffer "*)";
            loop (pos + 2)
              (if depth = 1 then Code false else Comment (depth - 1)))
          else (
            Buffer.add_char buffer source.[pos];
            loop (pos + 1) (Comment depth))
      | Quoted_string delimiter ->
          let closing_len = String.length delimiter + 2 in
          if quoted_string_closes source pos delimiter then (
            Buffer.add_substring buffer source pos closing_len;
            loop (pos + closing_len) (Code false))
          else (
            Buffer.add_char buffer source.[pos];
            loop (pos + 1) (Quoted_string delimiter))
  and code_char pos =
    if pos + 1 < len && source.[pos] = '(' && source.[pos + 1] = '*' then (
      Buffer.add_string buffer "(*";
      loop (pos + 2) (Comment 1))
    else
      match quoted_string_opener source pos with
      | Some (delimiter, next_pos) ->
          Buffer.add_substring buffer source pos (next_pos - pos);
          loop next_pos (Quoted_string delimiter)
      | None ->
          let ch = source.[pos] in
          Buffer.add_char buffer ch;
          if ch = '"' then loop (pos + 1) String
          else if is_line_break ch then loop (pos + 1) (Code true)
          else loop (pos + 1) (Code false)
  in
  loop 0 (Code true)

let label_to_option = function
  | Nolabel -> None
  | Labelled label -> Some label
  | Optional label -> Some label

let reject_optional_arg loc =
  failf loc "optional arguments are unsupported in CamlFlow MVP"

let fail_at_loc (loc : Loc.t) fmt =
  Printf.ksprintf
    (fun message ->
      raise (Error (Printf.sprintf "%s at %s" message (Loc.to_string loc))))
    fmt

let literal_of_constant loc (constant : constant) =
  match constant_view constant with
  | Const_integer (value, _) -> Syntax.Ast.LInt (int_of_string value)
  | Const_float (value, _) -> Syntax.Ast.LFloat (float_of_string value)
  | Const_string (value, _, _) -> Syntax.Ast.LString value
  | Const_char _ -> failf loc "char literals are unsupported"

let lower_unlabeled_tuple_item loc lower_item = function
  | None, item -> lower_item item
  | Some _, _ -> failf loc "labeled tuples are unsupported"

let last_ident loc lid =
  match Syntax.Ast.qname_of_longident lid with
  | [] -> failf loc "invalid longident"
  | parts -> List.hd (List.rev parts)

let tuple_component_type loc item =
  let repr = Obj.repr item in
  let is_labeled_tuple_component =
    Obj.is_block repr
    && Obj.tag repr = 0
    && Obj.size repr = 2
    &&
    let first = Obj.field repr 0 in
    let second = Obj.field repr 1 in
    (Obj.is_int first
    || (Obj.is_block first && Obj.tag first = 0 && Obj.size first = 1))
    && Obj.is_block second
  in
  if is_labeled_tuple_component then
    let label = Obj.field repr 0 in
    if Obj.is_int label then Obj.obj (Obj.field repr 1)
    else failf loc "labeled tuple types are unsupported"
  else Obj.obj repr

let tuple_pattern_items loc (desc : pattern_desc) =
  let repr = Obj.repr desc in
  if Obj.is_block repr && Obj.tag repr = 4 then
    match Obj.size repr with
    | 1 -> Some (Obj.obj (Obj.field repr 0) : pattern list)
    | 2 -> (
        let closed_flag : closed_flag = Obj.obj (Obj.field repr 1) in
        let items : (string option * pattern) list =
          Obj.obj (Obj.field repr 0)
        in
        match closed_flag with
        | Open -> failf loc "open tuple patterns are unsupported"
        | Closed ->
            Some
              (List.map
                 (fun (label, item) ->
                   match label with
                   | None -> item
                   | Some _ ->
                       failf loc "labeled tuple patterns are unsupported")
                 items))
    | _ -> None
  else None

let rec lower_type (typ : core_type) : Syntax.Ast.type_expr =
  let type_loc = loc_of typ.ptyp_loc in
  let type_desc =
    match typ.ptyp_desc with
    | Ptyp_constr ({ txt = lid; _ }, args) ->
        Syntax.Ast.TEConstr
          (Syntax.Ast.qname_of_longident lid, List.map lower_type args)
    | Ptyp_tuple items ->
        Syntax.Ast.TETuple
          (List.map
             (fun item -> lower_type (tuple_component_type typ.ptyp_loc item))
             items)
    | Ptyp_arrow (label, lhs, rhs) ->
        let label =
          match label with
          | Nolabel -> None
          | Labelled value -> Some value
          | Optional _ -> reject_optional_arg typ.ptyp_loc
        in
        let param =
          {
            Syntax.Ast.param_type_loc = loc_of lhs.ptyp_loc;
            param_label = label;
            param_typ = lower_type lhs;
          }
        in
        Syntax.Ast.TEArrow (param, lower_type rhs)
    | _ -> failf typ.ptyp_loc "unsupported type expression"
  in
  { Syntax.Ast.type_loc; type_desc }

let rec lower_pattern (pattern : pattern) : Syntax.Ast.pattern =
  let pattern_loc = loc_of pattern.ppat_loc in
  let pattern_desc =
    match pattern.ppat_desc with
    | Ppat_any -> Syntax.Ast.PWildcard
    | Ppat_var { txt = name; _ } -> Syntax.Ast.PVar name
    | Ppat_constant constant ->
        Syntax.Ast.PLiteral (literal_of_constant pattern.ppat_loc constant)
    | Ppat_record (fields, Closed) ->
        Syntax.Ast.PRecord
          (List.map
             (fun ({ txt = lid; loc }, inner) ->
               (last_ident loc lid, lower_pattern inner))
             fields)
    | Ppat_record (_, Open) ->
        failf pattern.ppat_loc "open record patterns are unsupported"
    | Ppat_construct ({ txt = lid; _ }, payload) -> (
        let name = Syntax.Ast.qname_of_longident lid in
        let literal_pattern =
          match (name, payload) with
          | [ "true" ], None ->
              Some (Syntax.Ast.PLiteral (Syntax.Ast.LBool true))
          | [ "false" ], None ->
              Some (Syntax.Ast.PLiteral (Syntax.Ast.LBool false))
          | [ "()" ], None -> Some (Syntax.Ast.PLiteral Syntax.Ast.LUnit)
          | _ -> None
        in
        match literal_pattern with
        | Some literal -> literal
        | None ->
            let args =
              match payload with
              | None -> []
              | Some (existentials, inner) -> (
                  let () =
                    match existentials with
                    | [] -> ()
                    | _ ->
                        failf inner.ppat_loc
                          "existential constructor patterns are unsupported"
                  in
                  match tuple_pattern_items inner.ppat_loc inner.ppat_desc with
                  | Some items -> List.map lower_pattern items
                  | None -> [ lower_pattern inner ])
            in
            Syntax.Ast.PConstruct (name, args))
    | Ppat_constraint (inner, _) -> (lower_pattern inner).pattern_desc
    | _ -> (
        match tuple_pattern_items pattern.ppat_loc pattern.ppat_desc with
        | Some items -> Syntax.Ast.PTuple (List.map lower_pattern items)
        | None -> failf pattern.ppat_loc "unsupported pattern syntax")
  in
  { Syntax.Ast.pattern_loc; pattern_desc }

let extract_name_and_annotation (pattern : pattern) :
    string * Syntax.Ast.type_expr option =
  match pattern.ppat_desc with
  | Ppat_var { txt = name; _ } -> (name, None)
  | Ppat_constraint ({ ppat_desc = Ppat_var { txt = name; _ }; _ }, typ) ->
      (name, Some (lower_type typ))
  | _ -> failf pattern.ppat_loc "binding patterns must be variables"

let value_binding_name_and_annotation (value_binding : value_binding) :
    string * Syntax.Ast.type_expr option =
  let name, pattern_annotation =
    extract_name_and_annotation value_binding.pvb_pat
  in
  let binding_annotation =
    match value_binding.pvb_constraint with
    | None -> pattern_annotation
    | Some (Pvc_constraint { locally_abstract_univars = []; typ }) ->
        Some (lower_type typ)
    | Some (Pvc_constraint { locally_abstract_univars = _ :: _; _ }) ->
        failf value_binding.pvb_loc
          "locally abstract type variables are unsupported"
    | Some (Pvc_coercion _) ->
        failf value_binding.pvb_loc "value coercions are unsupported"
  in
  (name, binding_annotation)

let lower_param ~param_loc label default pattern : Syntax.Ast.param =
  let () =
    match default with None -> () | Some _ -> reject_optional_arg param_loc
  in
  let param_name, param_annotation = extract_name_and_annotation pattern in
  let param_label =
    match label with
    | Nolabel -> None
    | Labelled value -> Some value
    | Optional _ -> reject_optional_arg param_loc
  in
  {
    Syntax.Ast.param_name;
    param_label;
    param_annotation;
    param_loc = loc_of param_loc;
  }

let lower_function_param (param : function_param) : Syntax.Ast.param =
  match param.pparam_desc with
  | Pparam_val (label, default, pattern) ->
      lower_param ~param_loc:param.pparam_loc label default pattern
  | Pparam_newtype _ ->
      failf param.pparam_loc "locally abstract type variables are unsupported"

let lower_type_constraint loc = function
  | None -> None
  | Some (Pconstraint typ) -> Some (lower_type typ)
  | Some (Pcoerce _) -> failf loc "value coercions are unsupported"

let split_fun_expr expr =
  match expr.pexp_desc with
  | Pexp_function (params, return_constraint, Pfunction_body body) ->
      let params = List.map lower_function_param params in
      let body, body_return_constraint =
        match body.pexp_desc with
        | Pexp_constraint (inner, typ) -> (inner, Some (lower_type typ))
        | _ -> (body, None)
      in
      let return_constraint =
        match lower_type_constraint expr.pexp_loc return_constraint with
        | Some return_constraint -> Some return_constraint
        | None -> body_return_constraint
      in
      (params, body, return_constraint)
  | Pexp_function (_, _, Pfunction_cases _) ->
      failf expr.pexp_loc "function shorthand is unsupported in CamlFlow MVP"
  | _ -> ([], expr, None)

let rebuild_function_annotation (params : Syntax.Ast.param list)
    (return_type : Syntax.Ast.type_expr) : Syntax.Ast.type_expr =
  List.fold_right
    (fun param acc ->
      let param_type =
        match param.Syntax.Ast.param_annotation with
        | Some annotation -> annotation
        | None ->
            fail_at_loc param.Syntax.Ast.param_loc
              "function parameters require type annotations when using a \
               return type annotation"
      in
      {
        Syntax.Ast.type_loc = param.Syntax.Ast.param_loc;
        type_desc =
          Syntax.Ast.TEArrow
            ( {
                param_type_loc = param.Syntax.Ast.param_loc;
                param_label = param.param_label;
                param_typ = param_type;
              },
              acc );
      })
    params return_type

let rec lower_expr (expr : expression) : Syntax.Ast.expr =
  let expr_loc = loc_of expr.pexp_loc in
  let expr_desc =
    match expr.pexp_desc with
    | Pexp_constant constant ->
        Syntax.Ast.ELiteral (literal_of_constant expr.pexp_loc constant)
    | Pexp_ident { txt = lid; _ } ->
        Syntax.Ast.EVar (Syntax.Ast.qname_of_longident lid)
    | Pexp_tuple items ->
        Syntax.Ast.ETuple
          (List.map (lower_unlabeled_tuple_item expr.pexp_loc lower_expr) items)
    | Pexp_record (fields, None) ->
        Syntax.Ast.ERecord
          (List.map
             (fun ({ txt = lid; loc }, value) ->
               (last_ident loc lid, lower_expr value))
             fields)
    | Pexp_record (_, Some _) ->
        failf expr.pexp_loc "record update syntax is unsupported"
    | Pexp_field (target, { txt = lid; loc }) ->
        Syntax.Ast.EField (lower_expr target, last_ident loc lid)
    | Pexp_construct ({ txt = lid; _ }, payload) -> (
        let name = Syntax.Ast.qname_of_longident lid in
        let args =
          match payload with
          | None -> []
          | Some { pexp_desc = Pexp_tuple items; _ } ->
              List.map
                (lower_unlabeled_tuple_item expr.pexp_loc lower_expr)
                items
          | Some inner -> [ lower_expr inner ]
        in
        let bool_or_unit =
          match name with
          | [ "true" ] -> Some (Syntax.Ast.ELiteral (Syntax.Ast.LBool true))
          | [ "false" ] -> Some (Syntax.Ast.ELiteral (Syntax.Ast.LBool false))
          | [ "()" ] -> Some (Syntax.Ast.ELiteral Syntax.Ast.LUnit)
          | _ -> None
        in
        match bool_or_unit with
        | Some literal -> literal
        | None -> Syntax.Ast.EConstruct (name, args))
    | Pexp_ifthenelse (cond, then_branch, Some else_branch) ->
        Syntax.Ast.EIf
          (lower_expr cond, lower_expr then_branch, lower_expr else_branch)
    | Pexp_ifthenelse (_, _, None) ->
        failf expr.pexp_loc "if expressions must have an else branch"
    | Pexp_while _ ->
        failf expr.pexp_loc
          "while loops are unsupported in CamlFlow MVP; use recursion for now"
    | Pexp_for _ ->
        failf expr.pexp_loc
          "for loops are unsupported in CamlFlow MVP; use recursion for now"
    | Pexp_match (scrutinee, cases) ->
        Syntax.Ast.EMatch (lower_expr scrutinee, List.map lower_case cases)
    | Pexp_let (rec_flag, bindings, body) ->
        let body_expr = lower_expr body in
        let nested =
          List.fold_right
            (fun value_binding acc ->
              let binding = lower_value_binding rec_flag value_binding in
              {
                Syntax.Ast.expr_loc = binding.Syntax.Ast.binding_loc;
                expr_desc = Syntax.Ast.ELet (binding, acc);
              })
            bindings body_expr
        in
        nested.Syntax.Ast.expr_desc
    | Pexp_apply (fn, args) ->
        let lower_arg (label, value) =
          let arg_label =
            match label with
            | Nolabel -> None
            | Labelled name -> Some name
            | Optional _ -> reject_optional_arg value.pexp_loc
          in
          {
            Syntax.Ast.arg_label;
            arg_value = lower_expr value;
            arg_loc = loc_of value.pexp_loc;
          }
        in
        Syntax.Ast.EApply (lower_expr fn, List.map lower_arg args)
    | Pexp_letop { let_ = binding; ands = []; body } ->
        if binding.pbop_op.txt <> "let*" then
          failf binding.pbop_loc "only let* is supported"
        else
          let let_star_name, _ = extract_name_and_annotation binding.pbop_pat in
          Syntax.Ast.ELetStar
            ( {
                Syntax.Ast.let_star_name;
                let_star_value = lower_expr binding.pbop_exp;
                let_star_loc = loc_of binding.pbop_loc;
              },
              lower_expr body )
    | Pexp_letop { ands = _ :: _; _ } ->
        failf expr.pexp_loc "let* with and* is unsupported"
    | Pexp_function (_, _, Pfunction_body _) ->
        let params, body, _return_type = split_fun_expr expr in
        Syntax.Ast.ELambda (params, lower_expr body)
    | Pexp_function (_, _, Pfunction_cases _) ->
        failf expr.pexp_loc "function shorthand is unsupported in CamlFlow MVP"
    | Pexp_constraint (inner, _) -> (lower_expr inner).Syntax.Ast.expr_desc
    | _ -> failf expr.pexp_loc "unsupported expression syntax"
  in
  { Syntax.Ast.expr_loc; expr_desc }

and lower_case (case : case) : Syntax.Ast.case =
  match case.pc_guard with
  | Some _ -> failf case.pc_lhs.ppat_loc "match guards are unsupported"
  | None ->
      {
        Syntax.Ast.case_pattern = lower_pattern case.pc_lhs;
        case_body = lower_expr case.pc_rhs;
        case_loc = loc_of case.pc_lhs.ppat_loc;
      }

and lower_value_binding rec_flag (value_binding : value_binding) :
    Syntax.Ast.binding =
  if value_binding.pvb_attributes <> [] then
    failf value_binding.pvb_loc "attributes are unsupported here"
  else
    let binding_name, binding_annotation =
      value_binding_name_and_annotation value_binding
    in
    let binding_recursive = rec_flag = Recursive in
    let binding_loc = loc_of value_binding.pvb_loc in
    match value_binding.pvb_expr.pexp_desc with
    | Pexp_function (_, _, Pfunction_body _) ->
        let binding_params, binding_body, return_type =
          split_fun_expr value_binding.pvb_expr
        in
        let binding_annotation =
          match (binding_annotation, return_type) with
          | Some annotation, _ -> Some annotation
          | None, Some return_type ->
              Some (rebuild_function_annotation binding_params return_type)
          | None, None -> None
        in
        {
          Syntax.Ast.binding_name;
          binding_params;
          binding_annotation;
          binding_body = lower_expr binding_body;
          binding_recursive;
          binding_loc;
        }
    | Pexp_function (_, _, Pfunction_cases _) ->
        failf value_binding.pvb_expr.pexp_loc
          "function shorthand is unsupported in CamlFlow MVP"
    | _ ->
        if binding_recursive then
          failf value_binding.pvb_loc
            "recursive non-function bindings are unsupported"
        else
          {
            Syntax.Ast.binding_name;
            binding_params = [];
            binding_annotation;
            binding_body = lower_expr value_binding.pvb_expr;
            binding_recursive;
            binding_loc;
          }

let attribute_kind attributes =
  let has name =
    List.exists
      (fun attribute -> String.equal attribute.attr_name.txt name)
      attributes
  in
  if has "camlflow.agent" then Some Syntax.Ast.Agent
  else if has "camlflow.skill" then Some Syntax.Ast.Skill
  else None

let rec split_arrow_type (typ : Syntax.Ast.type_expr) acc =
  match typ.type_desc with
  | Syntax.Ast.TEArrow (param, rest) -> split_arrow_type rest (param :: acc)
  | _ -> (List.rev acc, typ)

let lower_literal_expr expr =
  match lower_expr expr with
  | { Syntax.Ast.expr_desc = Syntax.Ast.ELiteral literal; _ } -> literal
  | _ -> failf expr.pexp_loc "expected literal expression"

let ident_qname (expr : expression) =
  match expr.pexp_desc with
  | Pexp_ident { txt = lid; _ } -> Some (Syntax.Ast.qname_of_longident lid)
  | _ -> None

let string_literal (expr : expression) =
  match expr.pexp_desc with
  | Pexp_constant constant -> (
      match constant_view constant with
      | Const_string (value, _, _) -> Some value
      | _ -> None)
  | _ -> None

let lower_callable_body kind expr =
  match expr.pexp_desc with
  | Pexp_apply (fn, [ (Nolabel, arg) ]) -> (
      match (ident_qname fn, string_literal arg, kind) with
      | Some [ "Agent"; "bind" ], Some name, Syntax.Ast.Agent
      | Some [ "Skill"; "bind" ], Some name, Syntax.Ast.Skill ->
          Syntax.Ast.Bind_target name
      | Some [ "Agent"; "define" ], _, Syntax.Ast.Agent ->
          failf expr.pexp_loc "Agent.define requires labeled arguments"
      | _ ->
          failf expr.pexp_loc "%s declarations must use %s"
            (match kind with Syntax.Ast.Agent -> "agent" | Skill -> "skill")
            (match kind with
            | Syntax.Ast.Agent -> "Agent.bind or Agent.define"
            | Skill -> "Skill.bind"))
  | Pexp_apply (fn, args) -> (
      match (ident_qname fn, kind) with
      | Some [ "Agent"; "define" ], Syntax.Ast.Agent ->
          let model = ref None in
          let temperature = ref None in
          let system_prompt = ref None in
          let metadata = ref [] in
          List.iter
            (fun (label, value) ->
              match label with
              | Labelled "model" -> (
                  match lower_literal_expr value with
                  | Syntax.Ast.LString text -> model := Some text
                  | _ -> failf value.pexp_loc "model must be a string literal")
              | Labelled "temperature" -> (
                  match lower_literal_expr value with
                  | Syntax.Ast.LFloat number -> temperature := Some number
                  | Syntax.Ast.LInt number ->
                      temperature := Some (float_of_int number)
                  | _ ->
                      failf value.pexp_loc "temperature must be a float literal"
                  )
              | Labelled "system_prompt" -> (
                  match lower_literal_expr value with
                  | Syntax.Ast.LString text -> system_prompt := Some text
                  | _ ->
                      failf value.pexp_loc
                        "system_prompt must be a string literal")
              | Labelled name ->
                  metadata := (name, lower_literal_expr value) :: !metadata
              | Nolabel ->
                  failf value.pexp_loc
                    "Agent.define only accepts labeled arguments"
              | Optional _ -> reject_optional_arg value.pexp_loc)
            args;
          Syntax.Ast.Inline_agent
            {
              define_model = !model;
              define_temperature = !temperature;
              define_system_prompt = !system_prompt;
              define_metadata = List.rev !metadata;
              define_loc = loc_of expr.pexp_loc;
            }
      | _ ->
          failf expr.pexp_loc "%s declarations must use %s"
            (match kind with Syntax.Ast.Agent -> "agent" | Skill -> "skill")
            (match kind with
            | Syntax.Ast.Agent -> "Agent.bind or Agent.define"
            | Skill -> "Skill.bind"))
  | _ ->
      failf expr.pexp_loc "%s declarations must be simple bind or define calls"
        (match kind with Syntax.Ast.Agent -> "agent" | Skill -> "skill")

let lower_callable kind (value_binding : value_binding) :
    Syntax.Ast.callable_decl =
  let callable_name, callable_annotation =
    value_binding_name_and_annotation value_binding
  in
  let callable_annotation =
    match callable_annotation with
    | Some annotation -> annotation
    | None ->
        failf value_binding.pvb_pat.ppat_loc
          "%s declarations require a type annotation"
          (match kind with Syntax.Ast.Agent -> "agent" | Skill -> "skill")
  in
  let callable_params, callable_return_type =
    split_arrow_type callable_annotation []
  in
  {
    Syntax.Ast.callable_name;
    callable_params;
    callable_return_type;
    callable_body = lower_callable_body kind value_binding.pvb_expr;
    callable_kind = kind;
    callable_loc = loc_of value_binding.pvb_loc;
  }

let lower_type_decl (decl : type_declaration) : Syntax.Ast.type_decl =
  if decl.ptype_params <> [] then
    failf decl.ptype_loc "parametric types are unsupported"
  else if decl.ptype_cstrs <> [] then
    failf decl.ptype_loc "type constraints are unsupported"
  else if decl.ptype_private = Private then
    failf decl.ptype_loc "private types are unsupported"
  else
    let type_name = decl.ptype_name.txt in
    let type_kind =
      match (decl.ptype_kind, decl.ptype_manifest) with
      | Ptype_abstract, Some manifest ->
          Syntax.Ast.Type_alias (lower_type manifest)
      | Ptype_abstract, None ->
          failf decl.ptype_loc "abstract types are unsupported"
      | Ptype_record fields, None ->
          Syntax.Ast.Type_record
            (List.map
               (fun field ->
                 if field.pld_mutable = Mutable then
                   failf field.pld_loc "mutable fields are unsupported";
                 {
                   Syntax.Ast.field_name = field.pld_name.txt;
                   field_type = lower_type field.pld_type;
                   field_loc = loc_of field.pld_loc;
                 })
               fields)
      | Ptype_variant ctors, None ->
          Syntax.Ast.Type_variant
            (List.map
               (fun ctor ->
                 let ctor_args =
                   match ctor.pcd_args with
                   | Pcstr_tuple args -> List.map lower_type args
                   | Pcstr_record _ ->
                       failf ctor.pcd_loc
                         "record constructor payloads are unsupported"
                 in
                 {
                   Syntax.Ast.ctor_name = ctor.pcd_name.txt;
                   ctor_args;
                   ctor_loc = loc_of ctor.pcd_loc;
                 })
               ctors)
      | Ptype_open, _ -> failf decl.ptype_loc "open types are unsupported"
      | (Ptype_record _ | Ptype_variant _), Some _ ->
          failf decl.ptype_loc "manifest record/variant types are unsupported"
    in
    { Syntax.Ast.type_name; type_kind; type_decl_loc = loc_of decl.ptype_loc }

let lower_structure_item (item : structure_item) : Syntax.Ast.decl list =
  match item.pstr_desc with
  | Pstr_type (_rec_flag, decls) ->
      List.map (fun decl -> Syntax.Ast.TypeDecl (lower_type_decl decl)) decls
  | Pstr_open open_description ->
      let opened =
        match open_description.popen_expr.pmod_desc with
        | Pmod_ident { txt = lid; _ } -> Syntax.Ast.qname_of_longident lid
        | _ ->
            failf open_description.popen_loc
              "only module identifier opens are supported"
      in
      [ Syntax.Ast.OpenDecl (opened, loc_of item.pstr_loc) ]
  | Pstr_value (rec_flag, bindings) ->
      List.map
        (fun value_binding ->
          match attribute_kind value_binding.pvb_attributes with
          | Some kind -> (
              match kind with
              | Syntax.Ast.Agent ->
                  Syntax.Ast.AgentDecl
                    (lower_callable Syntax.Ast.Agent value_binding)
              | Skill ->
                  Syntax.Ast.SkillDecl
                    (lower_callable Syntax.Ast.Skill value_binding))
          | None ->
              Syntax.Ast.LetDecl (lower_value_binding rec_flag value_binding))
        bindings
  | _ -> failf item.pstr_loc "unsupported top-level declaration"

let lower_module ~module_name ~path (structure : structure) : Syntax.Ast.module_
    =
  let module_decls = List.concat_map lower_structure_item structure in
  let module_loc =
    match structure with
    | [] -> Loc.none
    | first :: rest ->
        let last = List.fold_left (fun _ item -> item) first rest in
        let start = Loc.of_location first.pstr_loc in
        let stop = Loc.of_location last.pstr_loc in
        { start with end_pos = stop.end_pos }
  in
  { Syntax.Ast.module_name; module_path = path; module_decls; module_loc }
