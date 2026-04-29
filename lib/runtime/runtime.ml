module Context = Runtime_context
module StringMap = Map.Make (String)
module StringSet = Set.Make (String)

type effect_step = {
  step_kind : string;
  step_name : string;
  input : Yojson.Safe.t;
  output : Yojson.Safe.t;
}

type execution_result = {
  steps_run : int;
  effect_steps : effect_step list;
  trace_nodes : Workflow_trace.t list;
  output : Yojson.Safe.t option;
}

type callable_impl =
  | BoundAgent of string
  | BoundSkill of string
  | InlineAgent of Ir.agent_definition

type runtime_value =
  | RData of Value.t
  | RClosure of closure
  | RCallable of callable
  | RBuiltin of string

and closure = {
  closure_params : Ir.param list;
  closure_body : Ir.expr;
  closure_env : runtime_env;
}

and callable = {
  callable_name : string;
  callable_params : Ir.param_type list;
  callable_return_type : Ir.typ;
  callable_impl : callable_impl;
}

and runtime_env = {
  locals : (string * runtime_value) list;
  local_index : runtime_value StringMap.t Lazy.t;
  opened : Syntax.Ast.qname list;
  current_module : Syntax.Ast.qname;
  state : runtime_state;
}

and runtime_state = {
  context : Context.t;
  types : Value.type_index;
  modules : Ir.module_ StringMap.t;
  mutable skill_markdown_cache : string option StringMap.t;
  mutable module_envs : runtime_value StringMap.t StringMap.t;
  mutable evaluating_modules : StringSet.t;
  effect_steps : effect_step list ref;
  trace_nodes : Workflow_trace.t list ref;
  mutable effect_steps_count : int;
}

let ( let* ) = Result.bind

let all results =
  let rec aux acc = function
    | [] -> Ok (List.rev acc)
    | Ok value :: rest -> aux (value :: acc) rest
    | Error error :: _ -> Error error
  in
  aux [] results

let short_name name =
  match List.rev name with
  | head :: _ -> head
  | [] -> invalid_arg "empty qualified name"

let module_key = Syntax.Ast.string_of_qname

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
            | Some label ->
                Printf.sprintf "%s:%s" label (string_of_typ param.Ir.param_typ))
      in
      String.concat " -> " (params @ [ string_of_typ result ])

let rec expect_data loc = function
  | RData value -> Ok value
  | _ -> Error (Printf.sprintf "expected data value at %s" (Loc.to_string loc))

let builtin_value name = RBuiltin name

let lookup_builtin name =
  match name with
  | "+" | "-" | "*" | "/" | "mod" | "+." | "-." | "*." | "/." | "=" | "<>" | "<"
  | "<=" | ">" | ">=" | "&&" | "||" | "not" | "^" | "is_some" | "is_none"
  | "unwrap_or" ->
      Some (builtin_value name)
  | _ -> None

let lookup_in_assoc name items = List.assoc_opt name items
let read_file path = In_channel.with_open_bin path In_channel.input_all

let local_index_of_bindings bindings =
  List.fold_left
    (fun acc (name, value) -> StringMap.add name value acc)
    StringMap.empty bindings

let make_env ~locals ~opened ~current_module ~state =
  {
    locals;
    local_index = lazy (local_index_of_bindings locals);
    opened;
    current_module;
    state;
  }

let env_with_local env name value =
  {
    env with
    locals = (name, value) :: env.locals;
    local_index = lazy (StringMap.add name value (Lazy.force env.local_index));
  }

let env_with_locals env bindings =
  {
    env with
    locals = bindings @ env.locals;
    local_index =
      lazy
        (List.fold_left
           (fun acc (name, value) -> StringMap.add name value acc)
           (Lazy.force env.local_index)
           bindings);
  }

let skills_markdown state name =
  match StringMap.find_opt name state.skill_markdown_cache with
  | Some markdown -> markdown
  | None ->
      let markdown =
        match state.context.Context.skills_directory with
        | None -> None
        | Some dir ->
            let path = Filename.concat dir (Filename.concat name "SKILL.md") in
            if Sys.file_exists path then Some (read_file path) else None
      in
      state.skill_markdown_cache <-
        StringMap.add name markdown state.skill_markdown_cache;
      markdown

let entry_type (program : Ir.program) (entry : string) : (Ir.typ, string) result
    =
  let root_key = module_key program.Ir.root_module in
  let* root_module =
    match
      List.find_opt
        (fun module_ ->
          String.equal (module_key module_.Ir.module_name) root_key)
        program.Ir.modules
    with
    | Some module_ -> Ok module_
    | None -> Error (Printf.sprintf "root module %s not found" root_key)
  in
  let rec find = function
    | [] -> Error (Printf.sprintf "entry %s not found" entry)
    | Ir.LetDecl binding :: _ when String.equal binding.Ir.binding_name entry ->
        Ok binding.Ir.binding_type
    | Ir.AgentDecl callable :: _
      when String.equal callable.Ir.callable_name entry ->
        Ok
          (Ir.TFunc
             (callable.Ir.callable_params, callable.Ir.callable_return_type))
    | Ir.SkillDecl callable :: _
      when String.equal callable.Ir.callable_name entry ->
        Ok
          (Ir.TFunc
             (callable.Ir.callable_params, callable.Ir.callable_return_type))
    | _ :: rest -> find rest
  in
  find root_module.Ir.module_decls

let find_module state module_name =
  let key = module_key module_name in
  match StringMap.find_opt key state.modules with
  | Some module_ -> Ok module_
  | None -> (
      let requested = short_name module_name in
      let candidates =
        state.modules |> StringMap.bindings
        |> List.filter_map (fun (_key, module_) ->
            if String.equal (short_name module_.Ir.module_name) requested then
              Some module_
            else None)
      in
      match candidates with
      | [ module_ ] -> Ok module_
      | [] -> Error (Printf.sprintf "unknown module %s" key)
      | _ -> Error (Printf.sprintf "ambiguous module %s" key))

let build_state ?(context = Context.empty) (program : Ir.program) :
    runtime_state =
  let modules =
    List.fold_left
      (fun acc module_ ->
        StringMap.add (module_key module_.Ir.module_name) module_ acc)
      StringMap.empty program.Ir.modules
  in
  {
    context;
    types = Value.type_index_of_program program;
    modules;
    skill_markdown_cache = StringMap.empty;
    module_envs = StringMap.empty;
    evaluating_modules = StringSet.empty;
    effect_steps = ref [];
    trace_nodes = ref [];
    effect_steps_count = 0;
  }

let poll_cancellation_state state = state.context.Context.cancellation_check ()
let poll_cancellation_env env = poll_cancellation_state env.state

let rec eval_module state module_name =
  let* () = poll_cancellation_state state in
  let key = module_key module_name in
  match StringMap.find_opt key state.module_envs with
  | Some env -> Ok env
  | None ->
      if StringSet.mem key state.evaluating_modules then
        Error (Printf.sprintf "recursive module evaluation for %s" key)
      else
        let* module_ = find_module state module_name in
        state.evaluating_modules <- StringSet.add key state.evaluating_modules;
        let base_env =
          make_env ~locals:[] ~opened:[] ~current_module:module_name ~state
        in
        let* exports, _ =
          eval_module_decls base_env module_.Ir.module_decls StringMap.empty
        in
        state.module_envs <- StringMap.add key exports state.module_envs;
        state.evaluating_modules <-
          StringSet.remove key state.evaluating_modules;
        Ok exports

and eval_module_decls env decls exports =
  let* () = poll_cancellation_env env in
  match decls with
  | [] -> Ok (exports, env)
  | decl :: rest -> (
      match decl with
      | Ir.TypeDecl _ -> eval_module_decls env rest exports
      | Ir.OpenDecl (opened, _) ->
          let* _ = eval_module env.state opened in
          let env = { env with opened = opened :: env.opened } in
          eval_module_decls env rest exports
      | Ir.AgentDecl callable ->
          let value =
            RCallable
              {
                callable_name = callable.Ir.callable_name;
                callable_params = callable.Ir.callable_params;
                callable_return_type = callable.Ir.callable_return_type;
                callable_impl =
                  (match callable.Ir.callable_body with
                  | Ir.Bind_target target -> BoundAgent target
                  | Ir.Inline_agent definition -> InlineAgent definition);
              }
          in
          let env = env_with_local env callable.Ir.callable_name value in
          let exports = StringMap.add callable.Ir.callable_name value exports in
          eval_module_decls env rest exports
      | Ir.SkillDecl callable ->
          let value =
            RCallable
              {
                callable_name = callable.Ir.callable_name;
                callable_params = callable.Ir.callable_params;
                callable_return_type = callable.Ir.callable_return_type;
                callable_impl =
                  (match callable.Ir.callable_body with
                  | Ir.Bind_target target -> BoundSkill target
                  | Ir.Inline_agent definition -> InlineAgent definition);
              }
          in
          let env = env_with_local env callable.Ir.callable_name value in
          let exports = StringMap.add callable.Ir.callable_name value exports in
          eval_module_decls env rest exports
      | Ir.LetDecl binding ->
          let* value = eval_binding env binding in
          let env = env_with_local env binding.Ir.binding_name value in
          let exports = StringMap.add binding.Ir.binding_name value exports in
          eval_module_decls env rest exports)

and eval_binding env binding =
  let* () = poll_cancellation_env env in
  match (binding.Ir.binding_recursive, binding.Ir.binding_params) with
  | true, [] ->
      Error "recursive non-function bindings are unsupported at runtime"
  | true, _ :: _ ->
      let rec closure_env =
        {
          locals = (binding.Ir.binding_name, value) :: env.locals;
          local_index =
            lazy
              (StringMap.add binding.Ir.binding_name value
                 (Lazy.force env.local_index));
          opened = env.opened;
          current_module = env.current_module;
          state = env.state;
        }
      and value =
        RClosure
          {
            closure_params = binding.Ir.binding_params;
            closure_body = binding.Ir.binding_body;
            closure_env;
          }
      in
      Ok value
  | false, [] -> eval_expr env binding.Ir.binding_body
  | false, _ ->
      Ok
        (RClosure
           {
             closure_params = binding.Ir.binding_params;
             closure_body = binding.Ir.binding_body;
             closure_env = env;
           })

and lookup_value env name =
  match name with
  | [] -> Error "empty value name"
  | [ short_name ] -> (
      match StringMap.find_opt short_name (Lazy.force env.local_index) with
      | Some value -> Ok value
      | None ->
          let rec lookup_opened = function
            | [] -> (
                match lookup_builtin short_name with
                | Some builtin -> Ok builtin
                | None -> Error (Printf.sprintf "unbound value %s" short_name))
            | opened :: rest -> (
                let* opened_env = eval_module env.state opened in
                match StringMap.find_opt short_name opened_env with
                | Some value -> Ok value
                | None -> lookup_opened rest)
          in
          lookup_opened env.opened)
  | _ -> (
      let module_name = List.rev (List.tl (List.rev name)) in
      let short_name = List.hd (List.rev name) in
      let* opened_env = eval_module env.state module_name in
      match StringMap.find_opt short_name opened_env with
      | Some value -> Ok value
      | None ->
          Error
            (Printf.sprintf "unbound qualified value %s"
               (Syntax.Ast.string_of_qname name)))

and eval_expr env expr =
  let* () = poll_cancellation_env env in
  match expr.Ir.expr_desc with
  | Ir.ELiteral literal -> Ok (RData (value_of_literal literal))
  | Ir.EVar name -> lookup_value env name
  | Ir.ETuple items ->
      let* items = all (List.map (eval_expr env) items) in
      let* items = all (List.map (expect_data expr.Ir.expr_loc) items) in
      Ok (RData (Value.VTuple items))
  | Ir.ERecord fields ->
      let* fields =
        all
          (List.map
             (fun (name, value_expr) ->
               let* value = eval_expr env value_expr in
               let* value = expect_data value_expr.Ir.expr_loc value in
               Ok (name, value))
             fields)
      in
      Ok (RData (Value.VRecord fields))
  | Ir.EField (target_expr, field_name) -> (
      let* target = eval_expr env target_expr in
      let* target = expect_data target_expr.Ir.expr_loc target in
      match target with
      | Value.VRecord fields -> (
          match List.assoc_opt field_name fields with
          | Some value -> Ok (RData value)
          | None -> Error (Printf.sprintf "missing record field %s" field_name))
      | _ ->
          Error
            (Printf.sprintf "field access on non-record value at %s"
               (Loc.to_string expr.Ir.expr_loc)))
  | Ir.EConstruct (name, args) ->
      let* args = all (List.map (eval_expr env) args) in
      let* args = all (List.map (expect_data expr.Ir.expr_loc) args) in
      eval_construct name args
  | Ir.ELet (binding, body) ->
      let* value = eval_binding env binding in
      eval_expr (env_with_local env binding.Ir.binding_name value) body
  | Ir.ELetStar (binding, body) ->
      let* value = eval_expr env binding.Ir.let_star_value in
      eval_expr (env_with_local env binding.Ir.let_star_name value) body
  | Ir.EIf (cond, then_branch, else_branch) -> (
      let* cond = eval_expr env cond in
      let* cond = expect_data expr.Ir.expr_loc cond in
      match cond with
      | Value.VBool true -> eval_expr env then_branch
      | Value.VBool false -> eval_expr env else_branch
      | _ ->
          Error
            (Printf.sprintf "if condition must be bool at %s"
               (Loc.to_string expr.Ir.expr_loc)))
  | Ir.EMatch (scrutinee_expr, cases) ->
      let* scrutinee = eval_expr env scrutinee_expr in
      let* scrutinee = expect_data scrutinee_expr.Ir.expr_loc scrutinee in
      eval_match env scrutinee cases
  | Ir.EApply (fn, args) ->
      let* fn = eval_expr env fn in
      let* args =
        all
          (List.map
             (fun arg ->
               let* value = eval_expr env arg.Ir.arg_value in
               Ok (arg.Ir.arg_label, value, arg.Ir.arg_loc))
             args)
      in
      apply_value env expr.Ir.expr_loc fn args
  | Ir.ELambda (params, body) ->
      Ok
        (RClosure
           { closure_params = params; closure_body = body; closure_env = env })

and eval_construct name args =
  let short_name = short_name name in
  match (short_name, args) with
  | "[]", [] -> Ok (RData (Value.VList []))
  | "::", [ head; Value.VList tail ] -> Ok (RData (Value.VList (head :: tail)))
  | "Some", [ value ] -> Ok (RData (Value.VVariant ("Some", [ value ])))
  | "None", [] -> Ok (RData (Value.VVariant ("None", [])))
  | _ -> Ok (RData (Value.VVariant (short_name, args)))

and eval_match env scrutinee cases =
  let rec try_cases = function
    | [] -> Error "non-exhaustive match at runtime"
    | case :: rest -> (
        match match_pattern case.Ir.case_pattern scrutinee with
        | Some bindings ->
            eval_expr (env_with_locals env bindings) case.Ir.case_body
        | None -> try_cases rest)
  in
  try_cases cases

and match_pattern pattern value =
  match pattern.Ir.pattern_desc with
  | Ir.PWildcard -> Some []
  | Ir.PVar name -> Some [ (name, RData value) ]
  | Ir.PLiteral literal ->
      if equal_literal_value literal value then Some [] else None
  | Ir.PTuple patterns -> (
      match value with
      | Value.VTuple values when List.length patterns = List.length values ->
          combine_pattern_matches (List.map2 match_pattern patterns values)
      | _ -> None)
  | Ir.PRecord fields -> (
      match value with
      | Value.VRecord values ->
          let matches =
            List.map
              (fun (field_name, pattern) ->
                match List.assoc_opt field_name values with
                | Some value -> match_pattern pattern value
                | None -> None)
              fields
          in
          combine_pattern_matches matches
      | _ -> None)
  | Ir.PConstruct (name, patterns) -> (
      let short = short_name name in
      match (short, patterns, value) with
      | "[]", [], Value.VList [] -> Some []
      | "::", [ head_pattern; tail_pattern ], Value.VList (head :: tail) ->
          combine_pattern_matches
            [
              match_pattern head_pattern head;
              match_pattern tail_pattern (Value.VList tail);
            ]
      | "Some", [ pattern ], Value.VVariant ("Some", [ value ]) ->
          match_pattern pattern value
      | "None", [], Value.VVariant ("None", []) -> Some []
      | _, _, Value.VVariant (ctor_name, values)
        when String.equal ctor_name short
             && List.length patterns = List.length values ->
          combine_pattern_matches (List.map2 match_pattern patterns values)
      | _ -> None)

and combine_pattern_matches matches =
  let rec aux acc = function
    | [] -> Some (List.rev acc)
    | None :: _ -> None
    | Some bindings :: rest -> aux (List.rev_append bindings acc) rest
  in
  aux [] matches

and equal_literal_value literal value =
  match (literal, value) with
  | Ir.LString lhs, Value.VString rhs -> String.equal lhs rhs
  | Ir.LInt lhs, Value.VInt rhs -> lhs = rhs
  | Ir.LBool lhs, Value.VBool rhs -> lhs = rhs
  | Ir.LFloat lhs, Value.VFloat rhs -> lhs = rhs
  | Ir.LUnit, Value.VUnit -> true
  | _ -> false

and value_of_literal = function
  | Ir.LString value -> Value.VString value
  | Ir.LInt value -> Value.VInt value
  | Ir.LBool value -> Value.VBool value
  | Ir.LFloat value -> Value.VFloat value
  | Ir.LUnit -> Value.VUnit

and primitive_equal lhs rhs =
  match (lhs, rhs) with
  | Value.VString lhs, Value.VString rhs -> Ok (lhs = rhs)
  | Value.VInt lhs, Value.VInt rhs -> Ok (lhs = rhs)
  | Value.VBool lhs, Value.VBool rhs -> Ok (lhs = rhs)
  | Value.VFloat lhs, Value.VFloat rhs -> Ok (lhs = rhs)
  | Value.VUnit, Value.VUnit -> Ok true
  | _ -> Error "primitive equality operands must have the same primitive type"

and primitive_compare lhs rhs =
  match (lhs, rhs) with
  | Value.VString lhs, Value.VString rhs -> Ok (String.compare lhs rhs)
  | Value.VInt lhs, Value.VInt rhs -> Ok (compare lhs rhs)
  | Value.VFloat lhs, Value.VFloat rhs -> Ok (Float.compare lhs rhs)
  | _ -> Error "ordering operands must have the same ordered primitive type"

and apply_value env loc fn args =
  let* () = poll_cancellation_env env in
  match fn with
  | RBuiltin name -> apply_builtin loc name args
  | RClosure closure -> apply_closure loc closure args
  | RCallable callable -> apply_callable env loc callable args
  | RData _ ->
      Error
        (Printf.sprintf "cannot apply non-function value at %s"
           (Loc.to_string loc))

and apply_closure loc closure args =
  if List.length args > List.length closure.closure_params then
    Error (Printf.sprintf "too many arguments at %s" (Loc.to_string loc))
  else
    let matching, remaining =
      let rec split consumed params args =
        match (params, args) with
        | param :: params, arg :: args ->
            split ((param, arg) :: consumed) params args
        | params, [] -> (List.rev consumed, params)
        | [], _ -> assert false
      in
      split [] closure.closure_params args
    in
    let* bound_locals =
      all
        (List.map
           (fun ((param : Ir.param), (label, value, value_loc)) ->
             if label <> param.Ir.param_label then
               Error
                 (Printf.sprintf "argument label mismatch at %s"
                    (Loc.to_string value_loc))
             else Ok (param.Ir.param_name, value))
           matching)
    in
    let env = env_with_locals closure.closure_env bound_locals in
    match remaining with
    | [] -> eval_expr env closure.closure_body
    | remaining ->
        Ok
          (RClosure
             { closure with closure_params = remaining; closure_env = env })

and apply_builtin loc name args =
  let unlabeled =
    List.map
      (fun (label, value, value_loc) ->
        if Option.is_some label then
          Error
            (Printf.sprintf
               "builtin operator %s does not accept labeled arguments at %s"
               name (Loc.to_string value_loc))
        else expect_data value_loc value)
      args
  in
  let* unlabeled = all unlabeled in
  match (name, unlabeled) with
  | "not", [ Value.VBool value ] -> Ok (RData (Value.VBool (not value)))
  | "is_some", [ Value.VVariant ("Some", [ _ ]) ] ->
      Ok (RData (Value.VBool true))
  | "is_some", [ Value.VVariant ("None", []) ] -> Ok (RData (Value.VBool false))
  | "is_none", [ Value.VVariant ("Some", [ _ ]) ] ->
      Ok (RData (Value.VBool false))
  | "is_none", [ Value.VVariant ("None", []) ] -> Ok (RData (Value.VBool true))
  | "unwrap_or", [ Value.VVariant ("Some", [ value ]); _fallback ] ->
      Ok (RData value)
  | "unwrap_or", [ Value.VVariant ("None", []); fallback ] ->
      Ok (RData fallback)
  | "+", [ Value.VInt lhs; Value.VInt rhs ] ->
      Ok (RData (Value.VInt (lhs + rhs)))
  | "-", [ Value.VInt lhs; Value.VInt rhs ] ->
      Ok (RData (Value.VInt (lhs - rhs)))
  | "*", [ Value.VInt lhs; Value.VInt rhs ] ->
      Ok (RData (Value.VInt (lhs * rhs)))
  | "/", [ Value.VInt lhs; Value.VInt rhs ] ->
      Ok (RData (Value.VInt (lhs / rhs)))
  | "mod", [ Value.VInt lhs; Value.VInt rhs ] ->
      Ok (RData (Value.VInt (lhs mod rhs)))
  | "+.", [ Value.VFloat lhs; Value.VFloat rhs ] ->
      Ok (RData (Value.VFloat (lhs +. rhs)))
  | "-.", [ Value.VFloat lhs; Value.VFloat rhs ] ->
      Ok (RData (Value.VFloat (lhs -. rhs)))
  | "*.", [ Value.VFloat lhs; Value.VFloat rhs ] ->
      Ok (RData (Value.VFloat (lhs *. rhs)))
  | "/.", [ Value.VFloat lhs; Value.VFloat rhs ] ->
      Ok (RData (Value.VFloat (lhs /. rhs)))
  | ("=" | "<>"), [ lhs; rhs ] ->
      let* equal = primitive_equal lhs rhs in
      Ok
        (RData
           (Value.VBool (if String.equal name "=" then equal else not equal)))
  | ("<" | "<=" | ">" | ">="), [ lhs; rhs ] ->
      let* ordering = primitive_compare lhs rhs in
      let result =
        match name with
        | "<" -> ordering < 0
        | "<=" -> ordering <= 0
        | ">" -> ordering > 0
        | ">=" -> ordering >= 0
        | _ -> false
      in
      Ok (RData (Value.VBool result))
  | "&&", [ Value.VBool lhs; Value.VBool rhs ] ->
      Ok (RData (Value.VBool (lhs && rhs)))
  | "||", [ Value.VBool lhs; Value.VBool rhs ] ->
      Ok (RData (Value.VBool (lhs || rhs)))
  | "^", [ Value.VString lhs; Value.VString rhs ] ->
      Ok (RData (Value.VString (lhs ^ rhs)))
  | _ ->
      Error
        (Printf.sprintf "invalid builtin application %s at %s" name
           (Loc.to_string loc))

and apply_callable env _loc callable args =
  if List.length args <> List.length callable.callable_params then
    Error "callable arity mismatch"
  else
    let* payload_fields =
      all
        (List.mapi
           (fun index ((param : Ir.param_type), (label, value, value_loc)) ->
             if label <> param.Ir.param_label then
               Error
                 (Printf.sprintf "argument label mismatch at %s"
                    (Loc.to_string value_loc))
             else
               let* value = expect_data value_loc value in
               let* json =
                 Value.to_json env.state.types param.Ir.param_typ value
               in
               let field_name =
                 match param.Ir.param_label with
                 | Some label -> label
                 | None -> Printf.sprintf "arg%d" (index + 1)
               in
               Ok (field_name, json))
           (List.combine callable.callable_params args))
    in
    let input = `Assoc payload_fields in
    let skill_markdown =
      match callable.callable_impl with
      | BoundSkill target -> skills_markdown env.state target
      | BoundAgent _ | InlineAgent _ -> None
    in
    let invocation =
      match callable.callable_impl with
      | BoundAgent target ->
          {
            Context.invocation_kind = Context.Bound_agent;
            invocation_name = target;
            invocation_input = input;
            invocation_return_type = callable.callable_return_type;
            invocation_types = env.state.types;
            invocation_working_directory = env.state.context.working_directory;
            invocation_skills_directory = env.state.context.skills_directory;
            invocation_markdown = None;
            invocation_definition = None;
          }
      | BoundSkill target ->
          {
            Context.invocation_kind =
              (match skill_markdown with
              | Some _ -> Context.Local_prompt_skill
              | None -> Context.Bound_skill);
            invocation_name = target;
            invocation_input = input;
            invocation_return_type = callable.callable_return_type;
            invocation_types = env.state.types;
            invocation_working_directory = env.state.context.working_directory;
            invocation_skills_directory = env.state.context.skills_directory;
            invocation_markdown = skill_markdown;
            invocation_definition = None;
          }
      | InlineAgent definition ->
          {
            Context.invocation_kind = Context.Inline_agent;
            invocation_name = callable.callable_name;
            invocation_input = input;
            invocation_return_type = callable.callable_return_type;
            invocation_types = env.state.types;
            invocation_working_directory = env.state.context.working_directory;
            invocation_skills_directory = env.state.context.skills_directory;
            invocation_markdown = None;
            invocation_definition = Some definition;
          }
    in
    let step_kind, step_name =
      match invocation.Context.invocation_kind with
      | Context.Bound_agent -> ("agent", invocation.invocation_name)
      | Context.Bound_skill -> ("skill", invocation.invocation_name)
      | Context.Local_prompt_skill -> ("local-skill", invocation.invocation_name)
      | Context.Inline_agent -> ("inline-agent", invocation.invocation_name)
    in
    let step_index = env.state.effect_steps_count + 1 in
    let* request =
      Effect_request.of_invocation ~step_index ?run_id:env.state.context.run_id
        invocation
    in
    env.state.effect_steps_count <- step_index;
    let started_at = Unix.gettimeofday () in
    let output_result =
      match callable.callable_impl with
      | BoundAgent target -> (
          match Context.find_agent_handler env.state.context target with
          | Some handler ->
              handler ~name:target ~input
                ~return_type:callable.callable_return_type
                ~types:env.state.types
          | None -> env.state.context.default_provider invocation)
      | BoundSkill target -> (
          match Context.find_skill_handler env.state.context target with
          | Some handler ->
              handler ~name:target ~input
                ~return_type:callable.callable_return_type
                ~types:env.state.types
          | None -> (
              match skill_markdown with
              | Some markdown ->
                  env.state.context.prompt_skill_provider ~name:target ~markdown
                    ~input ~return_type:callable.callable_return_type
                    ~types:env.state.types
              | None -> env.state.context.default_provider invocation))
      | InlineAgent definition ->
          env.state.context.inline_agent_provider ~name:callable.callable_name
            ~definition ~input ~return_type:callable.callable_return_type
            ~types:env.state.types
    in
    let finished_provider_at = Unix.gettimeofday () in
    let record_trace ?output ~validation finished_at =
      let trace_node =
        Workflow_trace.create ~request ~output ~validation
          ~timing:(Workflow_trace.timing ~started_at ~finished_at)
          ()
      in
      env.state.trace_nodes := trace_node :: !(env.state.trace_nodes);
      env.state.context.trace_observer invocation
        ~trace_node:(Workflow_trace.to_yojson trace_node);
      match output with
      | Some output -> env.state.context.effect_observer invocation ~output
      | None -> ()
    in
    let* output =
      match output_result with
      | Ok output -> Ok output
      | Error error ->
          record_trace
            ~validation:(Workflow_trace.validation_error error)
            finished_provider_at;
          Error error
    in
    env.state.effect_steps :=
      { step_kind; step_name; input; output } :: !(env.state.effect_steps);
    let value_result =
      Value.of_json env.state.types callable.callable_return_type output
      |> Result.map_error (fun error ->
          Printf.sprintf
            "provider output for %s %s does not match declared return type %s: \
             %s (output: %s)"
            step_kind step_name
            (string_of_typ callable.callable_return_type)
            error
            (Yojson.Safe.to_string output))
    in
    let finished_at = Unix.gettimeofday () in
    match value_result with
    | Ok value ->
        record_trace ~output ~validation:Workflow_trace.validation_ok
          finished_at;
        Ok (RData value)
    | Error error ->
        record_trace ~output
          ~validation:(Workflow_trace.validation_error error)
          finished_at;
        Error error

let execute ?(context = Context.empty) ?(entry = "main") ?input
    (program : Ir.program) : (execution_result, string) result =
  let state = build_state ~context program in
  let* root_env = eval_module state program.Ir.root_module in
  let* entry_type = entry_type program entry in
  let* entry_value =
    match StringMap.find_opt entry root_env with
    | Some value -> Ok value
    | None -> Error (Printf.sprintf "entry %s not found" entry)
  in
  let run_env =
    {
      locals = StringMap.bindings root_env;
      local_index = lazy root_env;
      opened = [];
      current_module = program.Ir.root_module;
      state;
    }
  in
  let* result_value =
    match input with
    | None -> (
        match entry_type with
        | Ir.TFunc (_ :: _, _) -> Error "entrypoint requires input"
        | _ -> Ok entry_value)
    | Some json ->
        let input_param =
          match entry_type with
          | Ir.TFunc ([ param ], _result) -> Ok param
          | Ir.TFunc (_ :: _ :: _, _) ->
              Error "entrypoints may take at most one argument"
          | _ -> Error "entrypoint is not a function"
        in
        let* input_param = input_param in
        let* value = Value.of_json state.types input_param.Ir.param_typ json in
        apply_value run_env Loc.none entry_value
          [ (input_param.Ir.param_label, RData value, Loc.none) ]
  in
  let output =
    match (result_value, entry_type) with
    | RData value, Ir.TFunc (_, result_type) ->
        Some (Value.to_json state.types result_type value)
    | RData value, typ -> Some (Value.to_json state.types typ value)
    | _ -> None
  in
  let* output =
    match output with
    | None -> Ok None
    | Some result ->
        let* json = result in
        Ok (Some json)
  in
  Ok
    {
      steps_run = state.effect_steps_count;
      effect_steps = List.rev !(state.effect_steps);
      trace_nodes = List.rev !(state.trace_nodes);
      output;
    }
