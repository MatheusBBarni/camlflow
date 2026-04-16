module Env = Typing_env
module Loader = Project_loader
module StringMap = Map.Make (String)

type typed_program = Ir.program

type error = string

type inferred = {
  inferred_type : Ir.typ;
  effectful : bool;
  callable_kind : Env.value_kind option;
}

type checked_pattern = {
  ir_pattern : Ir.pattern;
  bindings : (string * Env.value_info) list;
  normal_pattern : normal_pattern;
}

and normal_pattern =
  | NWild
  | NConst of Ir.literal
  | NCtor of ctor_spec * normal_pattern list

and ctor_spec = {
  ctor_id : string;
  ctor_arg_types : Ir.typ list;
}

type compile_state = {
  ast_modules : Syntax.Ast.module_ StringMap.t;
  mutable compiled_modules : Ir.module_ StringMap.t;
  mutable compiled_signatures : Env.module_signature StringMap.t;
  mutable visiting : string list;
}

let ( let* ) = Result.bind

let type_error loc fmt =
  Printf.ksprintf (fun message -> Error (Printf.sprintf "%s at %s" message (Loc.to_string loc))) fmt

let qname_key = Syntax.Ast.string_of_qname

let short_name qname =
  match List.rev qname with
  | head :: _ -> head
  | [] -> invalid_arg "empty qualified name"

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
        params
        |> List.map (fun (param : Ir.param_type) ->
               match param.Ir.param_label with
               | None -> string_of_typ param.Ir.param_typ
               | Some label -> Printf.sprintf "%s:%s" label (string_of_typ param.Ir.param_typ))
      in
      String.concat " -> " (params @ [ string_of_typ result ])

let rec equal_typ left right =
  match (left, right) with
  | Ir.TString, Ir.TString
  | Ir.TInt, Ir.TInt
  | Ir.TBool, Ir.TBool
  | Ir.TFloat, Ir.TFloat
  | Ir.TUnit, Ir.TUnit -> true
  | Ir.TList lhs, Ir.TList rhs | Ir.TOption lhs, Ir.TOption rhs -> equal_typ lhs rhs
  | Ir.TTuple lhs, Ir.TTuple rhs ->
      List.length lhs = List.length rhs && List.for_all2 equal_typ lhs rhs
  | Ir.TRecord lhs, Ir.TRecord rhs | Ir.TVariant lhs, Ir.TVariant rhs -> lhs = rhs
  | Ir.TFunc (lhs_params, lhs_result), Ir.TFunc (rhs_params, rhs_result) ->
      List.length lhs_params = List.length rhs_params
      && List.for_all2
           (fun (lhs : Ir.param_type) (rhs : Ir.param_type) ->
             lhs.Ir.param_label = rhs.Ir.param_label && equal_typ lhs.Ir.param_typ rhs.Ir.param_typ)
           lhs_params rhs_params
      && equal_typ lhs_result rhs_result
  | _ -> false

let ensure_type expected actual loc =
  if equal_typ expected actual then Ok ()
  else
    type_error loc "type mismatch: expected %s but got %s" (string_of_typ expected) (string_of_typ actual)

let all results =
  let rec aux acc = function
    | [] -> Ok (List.rev acc)
    | Ok value :: rest -> aux (value :: acc) rest
    | Error error :: _ -> Error error
  in
  aux [] results

let is_builtin_name = function
  | "+" | "-" | "*" | "/" | "mod"
  | "+." | "-." | "*." | "/."
  | "=" | "<>" | "<" | "<=" | ">" | ">="
  | "&&" | "||" | "not" | "^" -> true
  | _ -> false

let primitive_equality_type = function
  | Ir.TInt | Ir.TBool | Ir.TString | Ir.TFloat | Ir.TUnit -> true
  | Ir.TList _ | Ir.TOption _ | Ir.TTuple _ | Ir.TRecord _ | Ir.TVariant _ | Ir.TFunc _ -> false

let primitive_order_type = function
  | Ir.TInt | Ir.TString | Ir.TFloat -> true
  | Ir.TBool | Ir.TUnit | Ir.TList _ | Ir.TOption _ | Ir.TTuple _ | Ir.TRecord _ | Ir.TVariant _ | Ir.TFunc _ -> false

let ensure_builtin_allowed predicate kind typ loc =
  if predicate typ then Ok ()
  else type_error loc "%s does not support values of type %s" kind (string_of_typ typ)

let make_builtin_fn loc name = { Ir.expr_loc = loc; expr_desc = Ir.EVar [ name ] }

let builtin_value_info name loc =
  let open Ir in
  let binary left right result =
    TFunc ([ { param_label = None; param_typ = left }; { param_label = None; param_typ = right } ], result)
  in
  let unary input result = TFunc ([ { param_label = None; param_typ = input } ], result) in
  let value_typ =
    match name with
    | "+" | "-" | "*" | "/" | "mod" -> Some (binary TInt TInt TInt)
    | "+." | "-." | "*." | "/." -> Some (binary TFloat TFloat TFloat)
    | "=" | "<>" | "<" | "<=" | ">" | ">=" -> Some (binary TInt TInt TBool)
    | "&&" | "||" -> Some (binary TBool TBool TBool)
    | "not" -> Some (unary TBool TBool)
    | "^" -> Some (binary TString TString TString)
    | _ -> None
  in
  Option.map (fun value_typ -> { Env.value_typ; value_kind = Env.User; value_loc = loc }) value_typ

let rec resolve_type (env : Env.t) (typ : Syntax.Ast.type_expr) : (Ir.typ, string) result =
  match typ.Syntax.Ast.type_desc with
  | Syntax.Ast.TEConstr (name, args) ->
      let* args = all (List.map (resolve_type env) args) in
      let name_string = Syntax.Ast.string_of_qname name in
      (match (name, args) with
      | [ "string" ], [] -> Ok Ir.TString
      | [ "int" ], [] -> Ok Ir.TInt
      | [ "bool" ], [] -> Ok Ir.TBool
      | [ "float" ], [] -> Ok Ir.TFloat
      | [ "unit" ], [] -> Ok Ir.TUnit
      | [ "list" ], [ inner ] -> Ok (Ir.TList inner)
      | [ "option" ], [ inner ] -> Ok (Ir.TOption inner)
      | _ ->
          let* decl = Env.lookup_type_decl env name in
          match decl.Ir.type_kind with
          | Ir.Alias inner -> Ok inner
          | Ir.Record _ ->
              if args <> [] then type_error typ.type_loc "record type %s does not take type arguments" name_string
              else Ok (Ir.TRecord decl.Ir.type_name)
          | Ir.Variant _ ->
              if args <> [] then type_error typ.type_loc "variant type %s does not take type arguments" name_string
              else Ok (Ir.TVariant decl.Ir.type_name))
  | Syntax.Ast.TETuple items ->
      let* items = all (List.map (resolve_type env) items) in
      Ok (Ir.TTuple items)
  | Syntax.Ast.TEArrow (param, result) ->
      let* param_typ = resolve_type env param.Syntax.Ast.param_typ in
      let* result = resolve_type env result in
      let param = { Ir.param_label = param.Syntax.Ast.param_label; param_typ } in
      (match result with
      | Ir.TFunc (params, final_result) -> Ok (Ir.TFunc (param :: params, final_result))
      | _ -> Ok (Ir.TFunc ([ param ], result)))

let resolve_param env (param : Syntax.Ast.param) : (Ir.param, string) result =
  match param.Syntax.Ast.param_annotation with
  | None -> type_error param.Syntax.Ast.param_loc "function parameters require type annotations"
  | Some annotation ->
      let* param_typ = resolve_type env annotation in
      Ok
        {
          Ir.param_name = param.Syntax.Ast.param_name;
          param_label = param.Syntax.Ast.param_label;
          param_typ;
          param_loc = param.Syntax.Ast.param_loc;
        }

let rec type_decl_fields env type_name =
  let* decl = Env.lookup_type_decl env type_name in
  match decl.Ir.type_kind with
  | Ir.Record fields -> Ok fields
  | _ -> Error (Printf.sprintf "%s is not a record type" (Syntax.Ast.string_of_qname type_name))

let rec type_decl_ctors env type_name =
  let* decl = Env.lookup_type_decl env type_name in
  match decl.Ir.type_kind with
  | Ir.Variant ctors -> Ok ctors
  | _ -> Error (Printf.sprintf "%s is not a variant type" (Syntax.Ast.string_of_qname type_name))

let ctor_id_of_type typ name =
  match typ with
  | Ir.TOption _ -> "option:" ^ name
  | Ir.TList _ -> "list:" ^ name
  | Ir.TBool -> "bool:" ^ name
  | Ir.TUnit -> "unit:" ^ name
  | Ir.TTuple _ -> "tuple:" ^ name
  | Ir.TRecord qname -> "record:" ^ Syntax.Ast.string_of_qname qname
  | Ir.TVariant qname -> "variant:" ^ Syntax.Ast.string_of_qname qname ^ ":" ^ name
  | Ir.TString | Ir.TInt | Ir.TFloat | Ir.TFunc _ -> name

let constructors_of_type env typ =
  let open Ir in
  match typ with
  | TBool ->
      Ok [ { ctor_id = ctor_id_of_type typ "true"; ctor_arg_types = [] }; { ctor_id = ctor_id_of_type typ "false"; ctor_arg_types = [] } ]
  | TUnit -> Ok [ { ctor_id = ctor_id_of_type typ "()"; ctor_arg_types = [] } ]
  | TOption inner ->
      Ok [ { ctor_id = ctor_id_of_type typ "None"; ctor_arg_types = [] }; { ctor_id = ctor_id_of_type typ "Some"; ctor_arg_types = [ inner ] } ]
  | TList inner ->
      Ok [ { ctor_id = ctor_id_of_type typ "[]"; ctor_arg_types = [] }; { ctor_id = ctor_id_of_type typ "::"; ctor_arg_types = [ inner; typ ] } ]
  | TTuple items -> Ok [ { ctor_id = ctor_id_of_type typ "tuple"; ctor_arg_types = items } ]
  | TRecord name ->
      let* fields = type_decl_fields env name in
      Ok [ { ctor_id = ctor_id_of_type typ "record"; ctor_arg_types = List.map (fun field -> field.Ir.field_typ) fields } ]
  | TVariant name ->
      let* ctors = type_decl_ctors env name in
      Ok (List.map (fun ctor -> { ctor_id = ctor_id_of_type typ ctor.Ir.ctor_name; ctor_arg_types = ctor.Ir.ctor_args }) ctors)
  | TString | TInt | TFloat | TFunc _ -> Ok []

let is_finite_type env typ =
  let* ctors = constructors_of_type env typ in
  Ok (ctors <> [])

let literal_type loc = function
  | Ir.LString _ -> Ok Ir.TString
  | Ir.LInt _ -> Ok Ir.TInt
  | Ir.LBool _ -> Ok Ir.TBool
  | Ir.LFloat _ -> Ok Ir.TFloat
  | Ir.LUnit -> Ok Ir.TUnit

let literal_ctor typ literal =
  match (typ, literal) with
  | Ir.TBool, Ir.LBool true -> Some { ctor_id = ctor_id_of_type typ "true"; ctor_arg_types = [] }
  | Ir.TBool, Ir.LBool false -> Some { ctor_id = ctor_id_of_type typ "false"; ctor_arg_types = [] }
  | Ir.TUnit, Ir.LUnit -> Some { ctor_id = ctor_id_of_type typ "()"; ctor_arg_types = [] }
  | _ -> None

let merge_bindings left right loc =
  let names = List.map fst left in
  let duplicates = List.filter (fun (name, _) -> List.mem name names) right in
  match duplicates with
  | [] -> Ok (left @ right)
  | (name, _) :: _ -> type_error loc "duplicate binding %s in pattern" name

let reorder_record_fields loc expected_fields actual_fields =
  let lookup name = List.assoc_opt name actual_fields in
  let missing = List.filter (fun field -> lookup field.Ir.field_name = None) expected_fields in
  let extra = List.filter (fun (name, _) -> not (List.exists (fun field -> String.equal field.Ir.field_name name) expected_fields)) actual_fields in
  match (missing, extra) with
  | field :: _, _ -> type_error loc "missing record field %s in pattern or expression" field.Ir.field_name
  | [], (name, _) :: _ -> type_error loc "unknown record field %s" name
  | [], [] ->
      Ok (List.map (fun field -> (field.Ir.field_name, Option.get (lookup field.Ir.field_name))) expected_fields)

let rec check_pattern env expected_type (pattern : Syntax.Ast.pattern) : (checked_pattern, string) result =
  match pattern.Syntax.Ast.pattern_desc with
  | Syntax.Ast.PWildcard ->
      Ok { ir_pattern = { Ir.pattern_loc = pattern.pattern_loc; pattern_desc = Ir.PWildcard }; bindings = []; normal_pattern = NWild }
  | Syntax.Ast.PVar name ->
      let value = { Env.value_typ = expected_type; value_kind = Env.User; value_loc = pattern.pattern_loc } in
      Ok { ir_pattern = { Ir.pattern_loc = pattern.pattern_loc; pattern_desc = Ir.PVar name }; bindings = [ (name, value) ]; normal_pattern = NWild }
  | Syntax.Ast.PLiteral literal ->
      let* actual = literal_type pattern.pattern_loc literal in
      let* () = ensure_type expected_type actual pattern.pattern_loc in
      let normal_pattern = match literal_ctor expected_type literal with Some ctor -> NCtor (ctor, []) | None -> NConst literal in
      Ok { ir_pattern = { Ir.pattern_loc = pattern.pattern_loc; pattern_desc = Ir.PLiteral literal }; bindings = []; normal_pattern }
  | Syntax.Ast.PTuple items ->
      (match expected_type with
      | Ir.TTuple types when List.length items = List.length types ->
          let* checked = all (List.map2 (check_pattern env) types items) in
          let* bindings = List.fold_left (fun acc item -> let* acc = acc in merge_bindings acc item.bindings pattern.pattern_loc) (Ok []) checked in
          let ir_pattern = { Ir.pattern_loc = pattern.pattern_loc; pattern_desc = Ir.PTuple (List.map (fun item -> item.ir_pattern) checked) } in
          let normal_pattern = NCtor ({ ctor_id = ctor_id_of_type expected_type "tuple"; ctor_arg_types = types }, List.map (fun item -> item.normal_pattern) checked) in
          Ok { ir_pattern; bindings; normal_pattern }
      | Ir.TTuple _ -> type_error pattern.pattern_loc "tuple arity mismatch in pattern"
      | _ -> type_error pattern.pattern_loc "expected %s to be a tuple in pattern" (string_of_typ expected_type))
  | Syntax.Ast.PRecord fields ->
      (match expected_type with
      | Ir.TRecord name ->
          let* expected_fields = type_decl_fields env name in
          let* ordered = reorder_record_fields pattern.pattern_loc expected_fields fields in
          let* checked =
            all
              (List.map2
                 (fun field (_name, item) -> check_pattern env field.Ir.field_typ item)
                 expected_fields ordered)
          in
          let* bindings = List.fold_left (fun acc item -> let* acc = acc in merge_bindings acc item.bindings pattern.pattern_loc) (Ok []) checked in
          let ir_fields = List.map2 (fun field item -> (field.Ir.field_name, item.ir_pattern)) expected_fields checked in
          let ir_pattern = { Ir.pattern_loc = pattern.pattern_loc; pattern_desc = Ir.PRecord ir_fields } in
          let normal_pattern = NCtor ({ ctor_id = ctor_id_of_type expected_type "record"; ctor_arg_types = List.map (fun field -> field.Ir.field_typ) expected_fields }, List.map (fun item -> item.normal_pattern) checked) in
          Ok { ir_pattern; bindings; normal_pattern }
      | _ -> type_error pattern.pattern_loc "record pattern used with non-record type %s" (string_of_typ expected_type))
  | Syntax.Ast.PConstruct (name, args) ->
      let name_text = short_name name in
      (match expected_type with
      | Ir.TOption inner ->
          let ctor =
            match name_text with
            | "None" -> Some { ctor_id = ctor_id_of_type expected_type "None"; ctor_arg_types = [] }
            | "Some" -> Some { ctor_id = ctor_id_of_type expected_type "Some"; ctor_arg_types = [ inner ] }
            | _ -> None
          in
          (match ctor with
          | Some ctor ->
              let* checked_args = check_ctor_pattern_args env pattern.pattern_loc ctor args in
              let* bindings = flatten_bindings pattern.pattern_loc checked_args in
              Ok
                {
                  ir_pattern = { Ir.pattern_loc = pattern.pattern_loc; pattern_desc = Ir.PConstruct (name, List.map (fun item -> item.ir_pattern) checked_args) };
                  bindings;
                  normal_pattern = NCtor (ctor, List.map (fun item -> item.normal_pattern) checked_args);
                }
          | None -> type_error pattern.pattern_loc "constructor %s does not belong to %s" name_text (string_of_typ expected_type))      | Ir.TList inner ->
          let ctor =
            match name_text with
            | "[]" -> Some { ctor_id = ctor_id_of_type expected_type "[]"; ctor_arg_types = [] }
            | "::" -> Some { ctor_id = ctor_id_of_type expected_type "::"; ctor_arg_types = [ inner; expected_type ] }
            | _ -> None
          in
          (match ctor with
          | Some ctor ->
              let* checked_args = check_ctor_pattern_args env pattern.pattern_loc ctor args in
              let* bindings = flatten_bindings pattern.pattern_loc checked_args in
              Ok
                {
                  ir_pattern = { Ir.pattern_loc = pattern.pattern_loc; pattern_desc = Ir.PConstruct (name, List.map (fun item -> item.ir_pattern) checked_args) };
                  bindings;
                  normal_pattern = NCtor (ctor, List.map (fun item -> item.normal_pattern) checked_args);
                }
          | None -> type_error pattern.pattern_loc "constructor %s does not belong to %s" name_text (string_of_typ expected_type))      | Ir.TVariant _parent ->
          let* ctor_info = Env.lookup_constructor env name in
          let* () = ensure_type expected_type ctor_info.Env.ctor_parent pattern.pattern_loc in
          let ctor = { ctor_id = ctor_id_of_type expected_type name_text; ctor_arg_types = ctor_info.Env.ctor_args } in
          let* checked_args = check_ctor_pattern_args env pattern.pattern_loc ctor args in
          let* bindings = flatten_bindings pattern.pattern_loc checked_args in
          Ok
            {
              ir_pattern = { Ir.pattern_loc = pattern.pattern_loc; pattern_desc = Ir.PConstruct (name, List.map (fun item -> item.ir_pattern) checked_args) };
              bindings;
              normal_pattern = NCtor (ctor, List.map (fun item -> item.normal_pattern) checked_args);
            }
      | _ -> type_error pattern.pattern_loc "constructor pattern %s does not match %s" name_text (string_of_typ expected_type))

and flatten_bindings loc checked =
  List.fold_left
    (fun acc item ->
      match acc with
      | Error _ as error -> error
      | Ok acc -> merge_bindings acc item.bindings loc)
    (Ok []) checked

and check_ctor_pattern_args env loc ctor args =
  if List.length args <> List.length ctor.ctor_arg_types then
    type_error loc "constructor expects %d arguments but got %d" (List.length ctor.ctor_arg_types) (List.length args)
  else all (List.map2 (check_pattern env) ctor.ctor_arg_types args)

let default_pattern args = List.map (fun _ -> NWild) args

let rec specialize_ctor_matrix ctor matrix =
  List.filter_map
    (function
      | NWild :: rest -> Some (default_pattern ctor.ctor_arg_types @ rest)
      | NCtor (head, args) :: rest when String.equal head.ctor_id ctor.ctor_id -> Some (args @ rest)
      | _ -> None)
    matrix

let default_matrix =
  List.filter_map (function NWild :: rest -> Some rest | _ -> None)

let rec useful env types matrix vector =
  match (types, vector) with
  | [], [] -> Ok (matrix = [])
  | typ :: rest_types, pattern :: rest_patterns -> (
      match pattern with
      | NWild ->
          let* finite = is_finite_type env typ in
          if finite then
            let* ctors = constructors_of_type env typ in
            let present =
              matrix
              |> List.filter_map (function NCtor (ctor, _) :: _ -> Some ctor.ctor_id | _ -> None)
              |> List.sort_uniq String.compare
            in
            if List.exists (fun ctor -> not (List.mem ctor.ctor_id present)) ctors then Ok true
            else
              let rec try_ctors = function
                | [] -> Ok false
                | ctor :: tail ->
                    let* is_useful = useful env (ctor.ctor_arg_types @ rest_types) (specialize_ctor_matrix ctor matrix) (default_pattern ctor.ctor_arg_types @ rest_patterns) in
                    if is_useful then Ok true else try_ctors tail
              in
              try_ctors ctors
          else useful env rest_types (default_matrix matrix) rest_patterns
      | NConst constant ->
          let* finite = is_finite_type env typ in
          (match literal_ctor typ constant with
          | Some ctor -> useful env (ctor.ctor_arg_types @ rest_types) (specialize_ctor_matrix ctor matrix) (rest_patterns)
          | None ->
              if finite then Error "internal error: finite literal should map to constructor"
              else
                let specialized =
                  List.filter_map
                    (function
                      | NWild :: rest -> Some rest
                      | NConst other :: rest when other = constant -> Some rest
                      | _ -> None)
                    matrix
                in
                useful env rest_types specialized rest_patterns)
      | NCtor (ctor, args) -> useful env (ctor.ctor_arg_types @ rest_types) (specialize_ctor_matrix ctor matrix) (args @ rest_patterns))
  | _ -> Ok false

let ensure_match_exhaustive env typ patterns loc =
  let matrix = List.map (fun pattern -> [ pattern ]) patterns in
  let* has_uncovered_case = useful env [ typ ] matrix [ NWild ] in
  if has_uncovered_case then type_error loc "non-exhaustive match" else Ok ()

let ensure_reachable env typ patterns loc =
  let rec loop seen = function
    | [] -> Ok ()
    | pattern :: rest ->
        let* is_useful = useful env [ typ ] seen [ pattern ] in
        if not is_useful then type_error loc "unreachable match case"
        else loop (seen @ [ [ pattern ] ]) rest
  in
  loop [] patterns

let rec infer_expr env ?expected ?(allow_effectful_call = false) (expr : Syntax.Ast.expr) :
    (Ir.expr * inferred, string) result =
  match expr.Syntax.Ast.expr_desc with
  | Syntax.Ast.ELiteral literal ->
      let* inferred_type = literal_type expr.expr_loc literal in
      let* () = match expected with None -> Ok () | Some expected -> ensure_type expected inferred_type expr.expr_loc in
      Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.ELiteral literal }, { inferred_type; effectful = false; callable_kind = None })
  | Syntax.Ast.EVar name ->
      let value_result =
        match name with
        | [ single ] -> (
            match builtin_value_info single expr.expr_loc with Some value -> Ok value | None -> Env.lookup_value env name)
        | _ -> Env.lookup_value env name
      in
      let* value = value_result in
      let* () = match expected with None -> Ok () | Some expected -> ensure_type expected value.Env.value_typ expr.expr_loc in
      Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.EVar name }, { inferred_type = value.Env.value_typ; effectful = false; callable_kind = Some value.Env.value_kind })
  | Syntax.Ast.ETuple items ->
      let* checked = all (List.map (infer_expr env) items) in
      let inferred_type = Ir.TTuple (List.map (fun (_, info) -> info.inferred_type) checked) in
      let* () = match expected with None -> Ok () | Some expected -> ensure_type expected inferred_type expr.expr_loc in
      Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.ETuple (List.map fst checked) }, { inferred_type; effectful = List.exists (fun (_, info) -> info.effectful) checked; callable_kind = None })
  | Syntax.Ast.ERecord fields -> infer_record env ?expected expr fields
  | Syntax.Ast.EField (target, field_name) ->
      let* target_ir, target_info = infer_expr env target in
      let* inferred_type =
        match target_info.inferred_type with
        | Ir.TRecord name ->
            let* fields = type_decl_fields env name in
            (match List.find_opt (fun field -> String.equal field.Ir.field_name field_name) fields with
            | Some field -> Ok field.Ir.field_typ
            | None -> type_error expr.expr_loc "record type %s has no field %s" (Syntax.Ast.string_of_qname name) field_name)
        | other ->
            type_error expr.expr_loc "field access requires a record value, got %s" (string_of_typ other)
      in
      let* () =
        match expected with
        | None -> Ok ()
        | Some expected -> ensure_type expected inferred_type expr.expr_loc
      in
      Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.EField (target_ir, field_name) }, { inferred_type; effectful = target_info.effectful; callable_kind = None })
  | Syntax.Ast.EConstruct (name, args) -> infer_construct env ?expected expr name args
  | Syntax.Ast.ELet (binding, body) -> infer_let env ?expected expr binding body
  | Syntax.Ast.ELetStar (binding, body) -> infer_let_star env ?expected expr binding body
  | Syntax.Ast.EIf (cond, then_branch, else_branch) ->
      let* cond_ir, cond_info = infer_expr env ~expected:Ir.TBool cond in
      let* then_ir, then_info = infer_expr env ?expected then_branch in
      let branch_expected = match expected with Some value -> Some value | None -> Some then_info.inferred_type in
      let* else_ir, else_info = infer_expr env ?expected:branch_expected else_branch in
      let inferred_type = match expected with Some value -> value | None -> then_info.inferred_type in
      let* () = ensure_type inferred_type else_info.inferred_type else_branch.expr_loc in
      Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.EIf (cond_ir, then_ir, else_ir) }, { inferred_type; effectful = cond_info.effectful || then_info.effectful || else_info.effectful; callable_kind = None })
  | Syntax.Ast.EMatch (scrutinee, cases) -> infer_match env ?expected expr scrutinee cases
  | Syntax.Ast.EApply (fn, args) ->
      infer_apply env ~allow_effectful_call ?expected expr fn args
  | Syntax.Ast.ELambda (params, body) -> infer_lambda env ?expected expr params body

and infer_record env ?expected expr fields =
  let parent_type =
    match expected with
    | Some (Ir.TRecord _ as record_type) -> Ok record_type
    | Some other -> type_error expr.expr_loc "expected record expression, got %s" (string_of_typ other)
    | None ->
        (match fields with
        | [] -> type_error expr.expr_loc "empty record literals are unsupported"
        | (field_name, _) :: _ ->
            let* field_info = Env.lookup_field env field_name in
            Ok field_info.Env.field_parent)
  in
  let* parent_type = parent_type in
  match parent_type with
  | Ir.TRecord name ->
      let* expected_fields = type_decl_fields env name in
      let* ordered = reorder_record_fields expr.expr_loc expected_fields fields in
      let* checked =
        all
          (List.map2
             (fun field (_name, value) -> infer_expr env ~expected:field.Ir.field_typ value)
             expected_fields ordered)
      in
      let ir_fields = List.map2 (fun field (value, _) -> (field.Ir.field_name, value)) expected_fields checked in
      Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.ERecord ir_fields }, { inferred_type = parent_type; effectful = List.exists (fun (_, info) -> info.effectful) checked; callable_kind = None })
  | _ -> type_error expr.expr_loc "expected record type"

and infer_construct env ?expected expr name args =
  let name_text = short_name name in
  match name_text with
  | "None" ->
      let option_type =
        match expected with
        | Some (Ir.TOption inner) -> Ok (Ir.TOption inner)
        | Some other -> type_error expr.expr_loc "None does not match %s" (string_of_typ other)
        | None -> type_error expr.expr_loc "cannot infer type of None without context"
      in
      let* inferred_type = option_type in
      if args <> [] then type_error expr.expr_loc "None does not take arguments"
      else Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.EConstruct (name, []) }, { inferred_type; effectful = false; callable_kind = None })
  | "Some" ->
      if List.length args <> 1 then type_error expr.expr_loc "Some expects one argument"
      else
        let expected_inner = match expected with Some (Ir.TOption inner) -> Some inner | _ -> None in
        let* arg_ir, arg_info = infer_expr env ?expected:expected_inner (List.hd args) in
        let inferred_type = Ir.TOption arg_info.inferred_type in
        let* () = match expected with None -> Ok () | Some expected -> ensure_type expected inferred_type expr.expr_loc in
        Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.EConstruct (name, [ arg_ir ]) }, { inferred_type; effectful = arg_info.effectful; callable_kind = None })
  | "[]" ->
      let list_type =
        match expected with
        | Some (Ir.TList inner) -> Ok (Ir.TList inner)
        | Some other -> type_error expr.expr_loc "[] does not match %s" (string_of_typ other)
        | None -> type_error expr.expr_loc "cannot infer type of [] without context"
      in
      let* inferred_type = list_type in
      if args <> [] then type_error expr.expr_loc "[] does not take arguments"
      else Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.EConstruct (name, []) }, { inferred_type; effectful = false; callable_kind = None })
  | "::" ->
      if List.length args <> 2 then type_error expr.expr_loc ":: expects two arguments"
      else
        let expected_inner = match expected with Some (Ir.TList inner) -> Some inner | _ -> None in
        let expected_tail = match expected with Some list_type -> Some list_type | None -> None in
        let* head_ir, head_info = infer_expr env ?expected:expected_inner (List.nth args 0) in
        let* tail_ir, tail_info = infer_expr env ?expected:expected_tail (List.nth args 1) in
        let* () = ensure_type (Ir.TList head_info.inferred_type) tail_info.inferred_type expr.expr_loc in
        let inferred_type = tail_info.inferred_type in
        Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.EConstruct (name, [ head_ir; tail_ir ]) }, { inferred_type; effectful = head_info.effectful || tail_info.effectful; callable_kind = None })
  | _ ->
      let* ctor_info = Env.lookup_constructor env name in
      let parent_type = ctor_info.Env.ctor_parent in
      let* () = match expected with None -> Ok () | Some expected -> ensure_type expected parent_type expr.expr_loc in
      if List.length args <> List.length ctor_info.Env.ctor_args then
        type_error expr.expr_loc "constructor %s expects %d arguments" name_text (List.length ctor_info.Env.ctor_args)
      else
        let* checked = all (List.map2 (fun arg typ -> infer_expr env ~expected:typ arg) args ctor_info.Env.ctor_args) in
        Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.EConstruct (name, List.map fst checked) }, { inferred_type = parent_type; effectful = List.exists (fun (_, info) -> info.effectful) checked; callable_kind = None })

and infer_builtin_apply env ?expected (expr : Syntax.Ast.expr) name args =
  let infer_unlabeled ?expected arg =
    if Option.is_some arg.Syntax.Ast.arg_label then
      type_error arg.arg_loc "builtin %s does not accept labeled arguments" name
    else
      let* arg_ir, arg_info = infer_expr env ?expected arg.arg_value in
      Ok ({ Ir.arg_label = None; arg_value = arg_ir; arg_loc = arg.arg_loc }, arg_info)
  in
  let finalize inferred_type checked_args =
    let* () =
      match expected with
      | None -> Ok ()
      | Some expected ->
          ensure_type expected inferred_type expr.Syntax.Ast.expr_loc
    in
    Ok
      ( { Ir.expr_loc = expr.Syntax.Ast.expr_loc;
          expr_desc =
            Ir.EApply
              ( make_builtin_fn expr.Syntax.Ast.expr_loc name,
                List.map fst checked_args ) },
        { inferred_type; effectful = false; callable_kind = None } )
  in
  match (name, args) with
  | "not", [ arg ] ->
      let* arg = infer_unlabeled ~expected:Ir.TBool arg in
      finalize Ir.TBool [ arg ]
  | ("+" | "-" | "*" | "/" | "mod"), [ lhs; rhs ] ->
      let* lhs = infer_unlabeled ~expected:Ir.TInt lhs in
      let* rhs = infer_unlabeled ~expected:Ir.TInt rhs in
      finalize Ir.TInt [ lhs; rhs ]
  | ("+." | "-." | "*." | "/."), [ lhs; rhs ] ->
      let* lhs = infer_unlabeled ~expected:Ir.TFloat lhs in
      let* rhs = infer_unlabeled ~expected:Ir.TFloat rhs in
      finalize Ir.TFloat [ lhs; rhs ]
  | ("&&" | "||"), [ lhs; rhs ] ->
      let* lhs = infer_unlabeled ~expected:Ir.TBool lhs in
      let* rhs = infer_unlabeled ~expected:Ir.TBool rhs in
      finalize Ir.TBool [ lhs; rhs ]
  | "^", [ lhs; rhs ] ->
      let* lhs = infer_unlabeled ~expected:Ir.TString lhs in
      let* rhs = infer_unlabeled ~expected:Ir.TString rhs in
      finalize Ir.TString [ lhs; rhs ]
  | ("=" | "<>"), [ lhs; rhs ] ->
      let* lhs_checked = infer_unlabeled lhs in
      let lhs_info = snd lhs_checked in
      let* () =
        ensure_builtin_allowed primitive_equality_type "equality"
          lhs_info.inferred_type lhs.arg_loc
      in
      let* rhs_checked = infer_unlabeled ~expected:lhs_info.inferred_type rhs in
      let rhs_info = snd rhs_checked in
      let* () =
        ensure_type lhs_info.inferred_type rhs_info.inferred_type rhs.arg_loc
      in
      finalize Ir.TBool [ lhs_checked; rhs_checked ]
  | ("<" | "<=" | ">" | ">="), [ lhs; rhs ] ->
      let* lhs_checked = infer_unlabeled lhs in
      let lhs_info = snd lhs_checked in
      let* () =
        ensure_builtin_allowed primitive_order_type "ordering"
          lhs_info.inferred_type lhs.arg_loc
      in
      let* rhs_checked = infer_unlabeled ~expected:lhs_info.inferred_type rhs in
      let rhs_info = snd rhs_checked in
      let* () =
        ensure_type lhs_info.inferred_type rhs_info.inferred_type rhs.arg_loc
      in
      finalize Ir.TBool [ lhs_checked; rhs_checked ]
  | _ -> type_error expr.expr_loc "invalid builtin application for %s" name

and infer_lambda env ?expected expr params body =
  let* params = all (List.map (resolve_param env) params) in
  let expected_result =
    match expected with
    | Some (Ir.TFunc (expected_params, result)) ->
        if List.length expected_params <> List.length params then type_error expr.expr_loc "lambda arity mismatch"
        else
          let* _validated =
            all
              (List.map2
                 (fun (expected : Ir.param_type) (param : Ir.param) ->
                   if expected.Ir.param_label <> param.Ir.param_label then
                     type_error param.Ir.param_loc "parameter label mismatch"
                   else ensure_type expected.Ir.param_typ param.Ir.param_typ param.Ir.param_loc)
                 expected_params params)
          in
          Ok (Some result)
    | Some other -> type_error expr.expr_loc "expected function type, got %s" (string_of_typ other)
    | None -> Ok None
  in
  let* expected_result = expected_result in
  let body_env =
    Env.with_locals env
      (List.map (fun (param : Ir.param) -> (param.Ir.param_name, { Env.value_typ = param.Ir.param_typ; value_kind = Env.User; value_loc = param.Ir.param_loc })) params)
  in
  let* body_ir, body_info = infer_expr body_env ?expected:expected_result body in
  let inferred_type = Ir.TFunc (List.map (fun (param : Ir.param) -> { Ir.param_label = param.Ir.param_label; param_typ = param.Ir.param_typ }) params, body_info.inferred_type) in
  Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.ELambda (params, body_ir) }, { inferred_type; effectful = false; callable_kind = Some Env.User })

and infer_apply env ?(allow_effectful_call = false) ?expected expr fn args =
  match fn.Syntax.Ast.expr_desc with
  | Syntax.Ast.EVar [ name ] when is_builtin_name name ->
      infer_builtin_apply env ?expected expr name args
  | _ ->
      let* fn_ir, fn_info = infer_expr env fn in
      match fn_info.inferred_type with
      | Ir.TFunc (params, result_type) ->
          if List.length args > List.length params then type_error expr.expr_loc "too many arguments in function application"
          else
            let matching, remaining =
              let rec split consumed params args =
                match (params, args) with
                | param :: params, arg :: args -> split ((param, arg) :: consumed) params args
                | params, [] -> (List.rev consumed, params)
                | [], _ -> assert false
              in
              split [] params args
            in
            let* checked_args =
              all
                (List.map
                   (fun ((param : Ir.param_type), arg) ->
                     if arg.Syntax.Ast.arg_label <> param.Ir.param_label then
                       type_error arg.arg_loc "argument label mismatch"
                     else
                       let* arg_ir, arg_info =
                         infer_expr env ~expected:param.Ir.param_typ arg.arg_value
                       in
                       Ok
                         ( { Ir.arg_label = arg.arg_label; arg_value = arg_ir; arg_loc = arg.arg_loc },
                           arg_info ))
                   matching)
            in
            let args_effectful = List.exists (fun (_, info) -> info.effectful) checked_args in
            let result =
              match (fn_info.callable_kind, remaining) with
              | Some (Env.Agent | Env.Skill), _ :: _ ->
                  type_error expr.expr_loc "agents and skills must be fully applied"
              | Some (Env.Agent | Env.Skill), [] when not allow_effectful_call ->
                  type_error expr.expr_loc
                    "effectful agent and skill calls must appear directly on the RHS of let*"
              | Some (Env.Agent | Env.Skill), [] -> Ok (result_type, true, None)
              | _, [] -> Ok (result_type, args_effectful || fn_info.effectful, None)
              | _, remaining ->
                  Ok (Ir.TFunc (remaining, result_type), args_effectful || fn_info.effectful, Some Env.User)
            in
            let* inferred_type, effectful, callable_kind = result in
            let* () =
              match expected with
              | None -> Ok ()
              | Some expected -> ensure_type expected inferred_type expr.expr_loc
            in
            Ok
              ( { Ir.expr_loc = expr.expr_loc; expr_desc = Ir.EApply (fn_ir, List.map fst checked_args) },
                { inferred_type; effectful; callable_kind } )
      | other ->
          type_error expr.expr_loc "cannot apply non-function value of type %s"
            (string_of_typ other)

and infer_match env ?expected expr scrutinee cases =
  let* scrutinee_ir, scrutinee_info = infer_expr env scrutinee in
  let* checked_cases =
    all
      (List.map
         (fun case ->
           let* checked_pattern = check_pattern env scrutinee_info.inferred_type case.Syntax.Ast.case_pattern in
           let env' = Env.with_locals env checked_pattern.bindings in
           let* body_ir, body_info = infer_expr env' ?expected case.Syntax.Ast.case_body in
           Ok
             ( { Ir.case_pattern = checked_pattern.ir_pattern; case_body = body_ir; case_loc = case.case_loc },
               body_info,
               checked_pattern.normal_pattern ))
         cases)
  in
  let* () = ensure_reachable env scrutinee_info.inferred_type (List.map (fun (_, _, pattern) -> pattern) checked_cases) expr.expr_loc in
  let* () = ensure_match_exhaustive env scrutinee_info.inferred_type (List.map (fun (_, _, pattern) -> pattern) checked_cases) expr.expr_loc in
  let result_type =
    match expected with
    | Some expected -> Ok expected
    | None ->
        (match checked_cases with
        | [] -> type_error expr.expr_loc "match expressions require at least one case"
        | (_, info, _) :: _ -> Ok info.inferred_type)
  in
  let* result_type = result_type in
  let* _validated = all (List.map (fun (_case, info, _) -> ensure_type result_type info.inferred_type expr.expr_loc) checked_cases) in
  Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.EMatch (scrutinee_ir, List.map (fun (case, _, _) -> case) checked_cases) }, { inferred_type = result_type; effectful = scrutinee_info.effectful || List.exists (fun (_case, info, _) -> info.effectful) checked_cases; callable_kind = None })

and infer_let env ?expected expr binding body =
  let* ir_binding, value_info, top_level_effect = check_binding env binding in
  let _ = top_level_effect in
  let env' = Env.with_local env binding.binding_name value_info in
  let* body_ir, body_info = infer_expr env' ?expected body in
  Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.ELet (ir_binding, body_ir) }, { inferred_type = body_info.inferred_type; effectful = body_info.effectful; callable_kind = body_info.callable_kind })

and infer_let_star env ?expected expr binding body =
  let* value_ir, value_info =
    infer_expr env ~allow_effectful_call:true binding.Syntax.Ast.let_star_value
  in
  if not value_info.effectful then type_error binding.let_star_loc "let* requires an effectful call on the right-hand side"
  else
    let env' =
      Env.with_local env binding.let_star_name
        { Env.value_typ = value_info.inferred_type; value_kind = Env.User; value_loc = binding.let_star_loc }
    in
    let* body_ir, body_info = infer_expr env' ?expected body in
    Ok ({ Ir.expr_loc = expr.expr_loc; expr_desc = Ir.ELetStar ({ Ir.let_star_name = binding.let_star_name; let_star_value = value_ir; let_star_loc = binding.let_star_loc }, body_ir) }, { inferred_type = body_info.inferred_type; effectful = true; callable_kind = None })

and check_binding env (binding : Syntax.Ast.binding) : (Ir.binding * Env.value_info * bool, string) result =
  let* binding_params = all (List.map (resolve_param env) binding.binding_params) in
  let declared_type =
    match binding.binding_annotation with
    | None -> Ok None
    | Some annotation ->
        let* value = resolve_type env annotation in
        Ok (Some value)
  in
  let* declared_type = declared_type in
  let validate_declared_params declared_params actual_params =
    if List.length declared_params <> List.length actual_params then
      type_error binding.binding_loc "function annotation arity mismatch"
    else
      let* _validated =
        all
          (List.map2
             (fun (declared : Ir.param_type) (actual : Ir.param) ->
               if declared.Ir.param_label <> actual.Ir.param_label then
                 type_error actual.Ir.param_loc "parameter label mismatch"
               else ensure_type declared.Ir.param_typ actual.Ir.param_typ actual.Ir.param_loc)
             declared_params actual_params)
      in
      Ok ()
  in
  let param_locals =
    List.map
      (fun (param : Ir.param) ->
        (param.Ir.param_name, { Env.value_typ = param.Ir.param_typ; value_kind = Env.User; value_loc = param.Ir.param_loc }))
      binding_params
  in
  let* body_env, expected_result =
    match (binding.binding_recursive, binding_params, declared_type) with
    | true, [], _ -> type_error binding.binding_loc "recursive values must be functions"
    | true, _ :: _, None -> type_error binding.binding_loc "recursive functions require an explicit type annotation"
    | true, _ :: _, Some (Ir.TFunc (declared_params, result)) ->
        let* () = validate_declared_params declared_params binding_params in
        let func_type = Ir.TFunc (declared_params, result) in
        let self_info = { Env.value_typ = func_type; value_kind = Env.User; value_loc = binding.binding_loc } in
        let body_env = Env.with_local env binding.binding_name self_info |> fun env -> Env.with_locals env param_locals in
        Ok (body_env, Some result)
    | true, _ :: _, Some other ->
        type_error binding.binding_loc "recursive annotation must be a function type, got %s" (string_of_typ other)
    | false, params, Some (Ir.TFunc (declared_params, result)) when params <> [] ->
        let* () = validate_declared_params declared_params params in
        Ok (Env.with_locals env param_locals, Some result)
    | false, [], Some other -> Ok (env, Some other)
    | false, _ :: _, Some other ->
        type_error binding.binding_loc "expected function annotation, got %s" (string_of_typ other)
    | false, _params, None -> Ok (Env.with_locals env param_locals, None)
  in
  let* body_ir, body_info = infer_expr body_env ?expected:expected_result binding.binding_body in
  let binding_type =
    match binding_params with
    | [] -> body_info.inferred_type
    | _ ->
        Ir.TFunc (List.map (fun (param : Ir.param) -> { Ir.param_label = param.Ir.param_label; param_typ = param.Ir.param_typ }) binding_params, body_info.inferred_type)
  in
  let* () =
    match declared_type with
    | None -> Ok ()
    | Some declared -> ensure_type declared binding_type binding.binding_loc
  in
  let ir_binding =
    {
      Ir.binding_name = binding.binding_name;
      binding_params;
      binding_type;
      binding_body = body_ir;
      binding_recursive = binding.binding_recursive;
      binding_loc = binding.binding_loc;
    }
  in
  Ok (ir_binding, { Env.value_typ = binding_type; value_kind = Env.User; value_loc = binding.binding_loc }, body_info.effectful)

let resolve_param_type env (param : Syntax.Ast.param_type) =
  let* param_typ = resolve_type env param.param_typ in
  Ok { Ir.param_label = param.param_label; param_typ }

let check_callable env (callable : Syntax.Ast.callable_decl) : (Ir.callable_decl * Env.value_info, string) result =
  let* callable_params = all (List.map (resolve_param_type env) callable.callable_params) in
  let* callable_return_type = resolve_type env callable.callable_return_type in
  let callable_body =
    match callable.callable_body with
    | Syntax.Ast.Bind_target target -> Ok (Ir.Bind_target target)
    | Syntax.Ast.Inline_agent definition ->
        Ok
          (Ir.Inline_agent
             {
               Ir.define_model = definition.define_model;
               define_temperature = definition.define_temperature;
               define_system_prompt = definition.define_system_prompt;
               define_metadata = definition.define_metadata;
               define_loc = definition.define_loc;
             })
  in
  let* callable_body = callable_body in
  let callable_kind = match callable.callable_kind with Syntax.Ast.Agent -> Ir.Agent | Skill -> Ir.Skill in
  let ir_callable =
    {
      Ir.callable_name = callable.callable_name;
      callable_params;
      callable_return_type;
      callable_body;
      callable_kind;
      callable_loc = callable.callable_loc;
    }
  in
  let value_kind = match callable.callable_kind with Syntax.Ast.Agent -> Env.Agent | Skill -> Env.Skill in
  let value_typ = Ir.TFunc (callable_params, callable_return_type) in
  Ok (ir_callable, { Env.value_typ = value_typ; value_kind; value_loc = callable.callable_loc })

let qualify_type_decl module_name (decl : Syntax.Ast.type_decl) : Ir.type_decl =
  let type_name = module_name @ [ decl.type_name ] in
  { Ir.type_name; type_kind = Ir.Alias Ir.TUnit; type_loc = decl.type_decl_loc }

let check_type_decl env module_name (decl : Syntax.Ast.type_decl) : (Ir.type_decl, string) result =
  let type_name = module_name @ [ decl.type_name ] in
  let* type_kind =
    match decl.type_kind with
    | Syntax.Ast.Type_alias typ ->
        let* typ = resolve_type env typ in
        Ok (Ir.Alias typ)
    | Syntax.Ast.Type_record fields ->
        let* fields =
          all
            (List.map
               (fun (field : Syntax.Ast.record_field) ->
                 let* field_typ = resolve_type env field.Syntax.Ast.field_type in
                 Ok { Ir.field_name = field.field_name; field_typ; field_loc = field.field_loc })
               fields)
        in
        Ok (Ir.Record fields)
    | Syntax.Ast.Type_variant ctors ->
        let* ctors =
          all
            (List.map
               (fun (ctor : Syntax.Ast.variant_ctor) ->
                 let* ctor_args = all (List.map (resolve_type env) ctor.Syntax.Ast.ctor_args) in
                 Ok { Ir.ctor_name = ctor.ctor_name; ctor_args; ctor_loc = ctor.ctor_loc })
               ctors)
        in
        Ok (Ir.Variant ctors)
  in
  Ok { Ir.type_name; type_kind; type_loc = decl.type_decl_loc }

let update_env_current env signature = { env with Env.current_module = signature }

let rec compile_module (state : compile_state) (module_name : Syntax.Ast.qname) : (Ir.module_, string) result =
  let key = qname_key module_name in
  match StringMap.find_opt key state.compiled_modules with
  | Some module_ -> Ok module_
  | None ->
      if List.mem key state.visiting then Error (Printf.sprintf "cyclic dependency involving module %s" key)
      else
        let* ast_module =
          match StringMap.find_opt key state.ast_modules with
          | Some module_ -> Ok module_
          | None -> Error (Printf.sprintf "missing AST for module %s" key)
        in
        state.visiting <- key :: state.visiting;
        let* () =
          List.fold_left
            (fun acc dependency ->
              let* () = acc in
              let* _ = compile_module state dependency in
              Ok ())
            (Ok ()) (Project_loader.module_dependencies ast_module)
        in
        let compiled_modules = state.compiled_signatures in
        let current_signature = Env.empty_signature module_name in
        let env = Env.create compiled_modules current_signature in
        let* module_decls, final_signature = check_module_decls env module_name ast_module.module_decls [] in
        let ir_module = { Ir.module_name = module_name; module_path = ast_module.module_path; module_decls = List.rev module_decls; module_loc = ast_module.module_loc } in
        state.compiled_modules <- StringMap.add key ir_module state.compiled_modules;
        state.compiled_signatures <- StringMap.add key final_signature state.compiled_signatures;
        state.visiting <- List.filter (fun item -> not (String.equal item key)) state.visiting;
        Ok ir_module

and check_module_decls env module_name decls acc =
  match decls with
  | [] -> Ok (acc, env.Env.current_module)
  | decl :: rest -> (
      match decl with
      | Syntax.Ast.OpenDecl (opened, loc) ->
          let* _ = Env.lookup_module env opened in
          let env = Env.with_opened env opened in
          check_module_decls env module_name rest (Ir.OpenDecl (opened, loc) :: acc)
      | Syntax.Ast.TypeDecl decl ->
          let* ir_decl = check_type_decl env module_name decl in
          let current_module = Env.add_type_decl env.Env.current_module ir_decl in
          let env = update_env_current env current_module in
          check_module_decls env module_name rest (Ir.TypeDecl ir_decl :: acc)
      | Syntax.Ast.LetDecl binding ->
          let* ir_binding, value_info, effectful = check_binding env binding in
          if binding.binding_params = [] && effectful then type_error binding.binding_loc "top-level effectful bindings are not allowed"
          else
            let current_module = Env.add_value env.Env.current_module ~name:binding.binding_name value_info in
            let env = update_env_current env current_module in
            check_module_decls env module_name rest (Ir.LetDecl ir_binding :: acc)
      | Syntax.Ast.AgentDecl callable ->
          let* ir_callable, value_info = check_callable env callable in
          let current_module = Env.add_value env.Env.current_module ~name:callable.callable_name value_info in
          let env = update_env_current env current_module in
          check_module_decls env module_name rest (Ir.AgentDecl ir_callable :: acc)
      | Syntax.Ast.SkillDecl callable ->
          let* ir_callable, value_info = check_callable env callable in
          let current_module = Env.add_value env.Env.current_module ~name:callable.callable_name value_info in
          let env = update_env_current env current_module in
          check_module_decls env module_name rest (Ir.SkillDecl ir_callable :: acc))

let build_state (program : Syntax.Ast.program) =
  let ast_modules =
    List.fold_left (fun acc module_ -> StringMap.add (qname_key module_.Syntax.Ast.module_name) module_ acc) StringMap.empty program.Syntax.Ast.modules
  in
  { ast_modules; compiled_modules = StringMap.empty; compiled_signatures = StringMap.empty; visiting = [] }

let check ?env:_ (program : Syntax.Ast.program) : (typed_program, error) result =
  let state = build_state program in
  let non_root_modules =
    List.filter
      (fun module_ ->
        qname_key module_.Syntax.Ast.module_name <> qname_key program.root_module)
      program.Syntax.Ast.modules
  in
  let* _ =
    all
      (List.map
         (fun module_ -> compile_module state module_.Syntax.Ast.module_name)
         non_root_modules)
  in
  let* _ = compile_module state program.root_module in
  let modules = state.compiled_modules |> StringMap.bindings |> List.map snd in
  Ok { Ir.root_module = program.root_module; modules }

let check_file ?(include_paths = []) (path : string) : (typed_program, error) result =
  let* base_program = Loader.load ~include_paths ~root_path:path in
  let root_dir = Filename.dirname path in
  let scan_dirs =
    root_dir
    :: List.map
         (fun dir -> if Filename.is_relative dir then Filename.concat root_dir dir else dir)
         include_paths
  in
  let scan_files =
    scan_dirs
    |> List.filter (fun dir -> Sys.file_exists dir && Sys.is_directory dir)
    |> List.concat_map (fun base_dir ->
           Project_loader.walk_cml_files base_dir base_dir
           |> List.map (fun path -> (base_dir, path)))
  in
  let* scanned_modules =
    all
      (List.map
         (fun (base_dir, module_path) ->
           let module_name = Project_loader.module_name_of_path ~base_dir module_path in
           Parsing.parse_file ~module_name module_path)
         scan_files)
  in
  let modules_by_key =
    List.fold_left
      (fun acc module_ ->
        StringMap.add (qname_key module_.Syntax.Ast.module_name) module_ acc)
      StringMap.empty (base_program.Syntax.Ast.modules @ scanned_modules)
  in
  let program =
    { Syntax.Ast.root_module = base_program.root_module;
      modules = modules_by_key |> StringMap.bindings |> List.map snd }
  in
  check program
