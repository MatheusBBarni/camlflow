module StringMap = Map.Make (String)
module QNameSet = Set.Make (String)

let ( let* ) = Result.bind

let qname_key = Syntax.Ast.string_of_qname

let lowercase_path (module_name : Syntax.Ast.qname) : string =
  (module_name |> List.map String.lowercase_ascii |> String.concat Filename.dir_sep)
  ^ ".cml"

let resolve_module_path ~from_dir ~include_paths (module_name : Syntax.Ast.qname) :
    (string, string) result =
  let relative = lowercase_path module_name in
  let candidates =
    Filename.concat from_dir relative
    :: List.map (fun dir -> Filename.concat dir relative) include_paths
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> Ok path
  | None ->
      Error
        (Printf.sprintf "unable to resolve module %s; looked for %s"
           (Syntax.Ast.string_of_qname module_name)
           (String.concat ", " candidates))

let module_prefix_of_qname (name : Syntax.Ast.qname) : Syntax.Ast.qname option =
  match List.rev name with
  | _symbol :: module_rev -> (
      match List.rev module_rev with
      | [] -> None
      | module_name -> Some module_name)
  | [] -> None

let add_module_ref set name =
  match module_prefix_of_qname name with
  | Some module_name -> QNameSet.add (qname_key module_name) set
  | None -> set

let qname_of_key key = Syntax.Ast.qname_of_string key

let rec refs_of_type_expr set (typ : Syntax.Ast.type_expr) =
  match typ.Syntax.Ast.type_desc with
  | Syntax.Ast.TEConstr (name, args) ->
      List.fold_left refs_of_type_expr (add_module_ref set name) args
  | Syntax.Ast.TETuple items -> List.fold_left refs_of_type_expr set items
  | Syntax.Ast.TEArrow (param, result) ->
      refs_of_type_expr (refs_of_type_expr set param.Syntax.Ast.param_typ) result

let refs_of_param set (param : Syntax.Ast.param) =
  match param.Syntax.Ast.param_annotation with
  | None -> set
  | Some annotation -> refs_of_type_expr set annotation

let rec refs_of_pattern set (pattern : Syntax.Ast.pattern) =
  match pattern.Syntax.Ast.pattern_desc with
  | Syntax.Ast.PWildcard | PVar _ | PLiteral _ -> set
  | Syntax.Ast.PTuple items -> List.fold_left refs_of_pattern set items
  | Syntax.Ast.PRecord fields ->
      List.fold_left (fun acc (_name, item) -> refs_of_pattern acc item) set fields
  | Syntax.Ast.PConstruct (name, args) ->
      List.fold_left refs_of_pattern (add_module_ref set name) args

let rec refs_of_expr set (expr : Syntax.Ast.expr) =
  match expr.Syntax.Ast.expr_desc with
  | Syntax.Ast.ELiteral _ -> set
  | Syntax.Ast.EVar name -> add_module_ref set name
  | Syntax.Ast.ETuple items -> List.fold_left refs_of_expr set items
  | Syntax.Ast.ERecord fields ->
      List.fold_left (fun acc (_name, item) -> refs_of_expr acc item) set fields
  | Syntax.Ast.EField (target, _field) -> refs_of_expr set target
  | Syntax.Ast.EConstruct (name, args) ->
      List.fold_left refs_of_expr (add_module_ref set name) args
  | Syntax.Ast.ELet (binding, body) -> refs_of_expr (refs_of_binding set binding) body
  | Syntax.Ast.ELetStar (binding, body) ->
      refs_of_expr (refs_of_expr set binding.Syntax.Ast.let_star_value) body
  | Syntax.Ast.EIf (cond, then_branch, else_branch) ->
      refs_of_expr (refs_of_expr (refs_of_expr set cond) then_branch) else_branch
  | Syntax.Ast.EMatch (scrutinee, cases) ->
      List.fold_left
        (fun acc case -> refs_of_expr (refs_of_pattern acc case.Syntax.Ast.case_pattern) case.case_body)
        (refs_of_expr set scrutinee) cases
  | Syntax.Ast.EApply (fn, args) ->
      List.fold_left
        (fun acc arg -> refs_of_expr acc arg.Syntax.Ast.arg_value)
        (refs_of_expr set fn) args
  | Syntax.Ast.ELambda (params, body) ->
      refs_of_expr (List.fold_left refs_of_param set params) body

and refs_of_binding set (binding : Syntax.Ast.binding) =
  let set =
    match binding.Syntax.Ast.binding_annotation with
    | None -> set
    | Some annotation -> refs_of_type_expr set annotation
  in
  let set = List.fold_left refs_of_param set binding.binding_params in
  refs_of_expr set binding.binding_body

let refs_of_param_type set (param : Syntax.Ast.param_type) =
  refs_of_type_expr set param.Syntax.Ast.param_typ

let refs_of_callable set (callable : Syntax.Ast.callable_decl) =
  let set = List.fold_left refs_of_param_type set callable.callable_params in
  refs_of_type_expr set callable.callable_return_type

let refs_of_type_decl set (decl : Syntax.Ast.type_decl) =
  match decl.Syntax.Ast.type_kind with
  | Syntax.Ast.Type_alias typ -> refs_of_type_expr set typ
  | Syntax.Ast.Type_record fields ->
      List.fold_left
        (fun acc field -> refs_of_type_expr acc field.Syntax.Ast.field_type)
        set fields
  | Syntax.Ast.Type_variant ctors ->
      List.fold_left
        (fun acc ctor -> List.fold_left refs_of_type_expr acc ctor.Syntax.Ast.ctor_args)
        set ctors

let decl_module_refs (decl : Syntax.Ast.decl) : QNameSet.t =
  match decl with
  | Syntax.Ast.OpenDecl (opened, _) -> QNameSet.singleton (qname_key opened)
  | Syntax.Ast.TypeDecl decl -> refs_of_type_decl QNameSet.empty decl
  | Syntax.Ast.LetDecl binding -> refs_of_binding QNameSet.empty binding
  | Syntax.Ast.AgentDecl callable | Syntax.Ast.SkillDecl callable ->
      refs_of_callable QNameSet.empty callable

let module_dependencies (module_ : Syntax.Ast.module_) : Syntax.Ast.qname list =
  module_.Syntax.Ast.module_decls
  |> List.fold_left
       (fun acc decl -> QNameSet.union acc (decl_module_refs decl))
       QNameSet.empty
  |> QNameSet.remove (qname_key module_.module_name)
  |> QNameSet.to_list |> List.map qname_of_key

let rec walk_cml_files base_dir current_dir =
  Sys.readdir current_dir
  |> Array.to_list
  |> List.sort String.compare
  |> List.concat_map (fun entry ->
         let path = Filename.concat current_dir entry in
         if Sys.is_directory path then walk_cml_files base_dir path
         else if Filename.check_suffix path ".cml" then [ path ]
         else [])

let module_name_of_path ~base_dir path =
  let relative =
    let base = if Filename.is_relative base_dir then Filename.concat (Sys.getcwd ()) base_dir else base_dir in
    let absolute = if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path in
    let prefix = base ^ Filename.dir_sep in
    if String.equal absolute base then []
    else if String.length absolute >= String.length prefix && String.sub absolute 0 (String.length prefix) = prefix then
      String.sub absolute (String.length prefix) (String.length absolute - String.length prefix)
      |> Filename.remove_extension
      |> String.split_on_char Filename.dir_sep.[0]
      |> List.filter (fun part -> part <> "")
      |> List.map String.capitalize_ascii
    else [ path |> Filename.basename |> Filename.remove_extension |> String.capitalize_ascii ]
  in
  match relative with [] -> [ path |> Filename.basename |> Filename.remove_extension |> String.capitalize_ascii ] | _ -> relative

type state = {
  include_paths : string list;
  mutable modules : Syntax.Ast.module_ StringMap.t;
  mutable visiting : string list;
}

let load ~include_paths ~(root_path : string) : (Syntax.Ast.program, string) result =
  let state = { include_paths; modules = StringMap.empty; visiting = [] } in
  let rec visit ~from_dir ~(module_name : Syntax.Ast.qname) ~(path : string) =
    let key = qname_key module_name in
    if StringMap.mem key state.modules then Ok ()
    else if List.mem key state.visiting then
      Error (Printf.sprintf "cyclic module dependency involving %s" key)
    else
      let () = state.visiting <- key :: state.visiting in
      let result =
        let* module_ = Parsing.parse_file ~module_name path in
        let dependencies = module_dependencies module_ in
        let* () =
          List.fold_left
            (fun acc dependency ->
              let* () = acc in
              let* resolved =
                resolve_module_path ~from_dir:(Filename.dirname path)
                  ~include_paths:state.include_paths dependency
              in
              visit ~from_dir:(Filename.dirname resolved) ~module_name:dependency
                ~path:resolved)
            (Ok ()) dependencies
        in
        state.modules <- StringMap.add key module_ state.modules;
        Ok ()
      in
      state.visiting <- List.filter (fun item -> not (String.equal item key)) state.visiting;
      result
  in
  let root_module = Parsing_driver.module_name_of_basename root_path in
  let root_dir = Filename.dirname root_path in
  let* () = visit ~from_dir:root_dir ~module_name:root_module ~path:root_path in
  let* () =
    List.fold_left
      (fun acc base_dir ->
        let* () = acc in
        let base_dir = if Filename.is_relative base_dir then Filename.concat root_dir base_dir else base_dir in
        let files = if Sys.file_exists base_dir && Sys.is_directory base_dir then walk_cml_files base_dir base_dir else [] in
        List.fold_left
          (fun acc path ->
            let* () = acc in
            let module_name = module_name_of_path ~base_dir path in
            visit ~from_dir:(Filename.dirname path) ~module_name ~path)
          (Ok ()) files)
      (Ok ()) (root_dir :: include_paths)
  in
  let modules = state.modules |> StringMap.bindings |> List.map snd in
  Ok { Syntax.Ast.root_module; modules }
