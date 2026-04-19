module StringMap = Map.Make (String)
module StringSet = Set.Make (String)

let ( let* ) = Result.bind

type position = { line : int; character : int }
type range = { start_pos : position; end_pos : position }

type diagnostic = {
  uri : string;
  range : range;
  severity : int;
  source : string;
  message : string;
}

type document_symbol = {
  name : string;
  detail : string option;
  kind : int;
  range : range;
  selection_range : range;
  children : document_symbol list;
}

type symbol_kind =
  | Module
  | Type
  | Constructor
  | Field
  | Value
  | Agent
  | Skill
  | Parameter
  | Local

type symbol = {
  id : string;
  name : string;
  kind : symbol_kind;
  uri : string;
  decl_range : range;
  decl_selection_range : range;
  hover : string option;
  renameable : bool;
}

type occurrence_role = Declaration | Reference

type occurrence = {
  symbol_id : string;
  uri : string;
  range : range;
  role : occurrence_role;
}

type analysis = {
  project_id : string;
  current_uri : string;
  symbols : symbol StringMap.t;
  occurrences_by_uri : occurrence list StringMap.t;
  occurrences_by_symbol : occurrence list StringMap.t;
  document_symbols_by_uri : document_symbol list StringMap.t;
  diagnostics_by_uri : diagnostic list StringMap.t;
}

type file_buffer = {
  path : string;
  uri : string;
  text : string;
  line_starts : int array;
}

type overlays = string StringMap.t

type loaded_project = {
  program : Syntax.Ast.program;
  files : file_buffer StringMap.t;
}

type project_context = {
  project_id : string;
  root_path : string;
  include_paths : string list;
}

type module_summary = {
  module_name : Syntax.Ast.qname;
  path : string;
  module_symbol_id : string;
  type_ids : string StringMap.t;
  value_ids : string StringMap.t;
  ctor_ids : string list StringMap.t;
  field_ids : string list StringMap.t;
}

type builder = {
  current_uri : string;
  files : file_buffer StringMap.t;
  symbols : (string, symbol) Hashtbl.t;
  mutable occurrences_by_uri : occurrence list StringMap.t;
  mutable diagnostics_by_uri : diagnostic list StringMap.t;
  mutable document_symbols_by_uri : document_symbol list StringMap.t;
}

type walk_env = {
  builder : builder;
  catalogs : module_summary StringMap.t;
  current_summary : module_summary;
  opened : Syntax.Ast.qname list;
  locals : string StringMap.t;
}

let module_key = Syntax.Ast.string_of_qname

let normalize_path path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
  else path

let hex_digit value =
  Char.chr
    (if value < 10 then Char.code '0' + value else Char.code 'A' + (value - 10))

let is_unreserved = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' | '/' -> true
  | _ -> false

let uri_of_path path =
  let path = normalize_path path in
  let buffer = Buffer.create (String.length path + 8) in
  String.iter
    (fun ch ->
      if is_unreserved ch then Buffer.add_char buffer ch
      else (
        Buffer.add_char buffer '%';
        Buffer.add_char buffer (hex_digit ((Char.code ch lsr 4) land 0xF));
        Buffer.add_char buffer (hex_digit (Char.code ch land 0xF))))
    path;
  "file://" ^ Buffer.contents buffer

let decode_hex = function
  | '0' .. '9' as ch -> Char.code ch - Char.code '0'
  | 'A' .. 'F' as ch -> 10 + Char.code ch - Char.code 'A'
  | 'a' .. 'f' as ch -> 10 + Char.code ch - Char.code 'a'
  | _ -> invalid_arg "invalid hex digit"

let path_of_uri uri =
  let prefix = "file://" in
  if
    String.length uri < String.length prefix
    || String.sub uri 0 (String.length prefix) <> prefix
  then Error (Printf.sprintf "unsupported URI: %s" uri)
  else
    let encoded =
      String.sub uri (String.length prefix)
        (String.length uri - String.length prefix)
    in
    let buffer = Buffer.create (String.length encoded) in
    let rec loop index =
      if index >= String.length encoded then
        Ok (normalize_path (Buffer.contents buffer))
      else
        match encoded.[index] with
        | '%' when index + 2 < String.length encoded ->
            let hi = decode_hex encoded.[index + 1] in
            let lo = decode_hex encoded.[index + 2] in
            Buffer.add_char buffer (Char.chr ((hi lsl 4) lor lo));
            loop (index + 3)
        | ch ->
            Buffer.add_char buffer ch;
            loop (index + 1)
    in
    loop 0

let line_starts_of_text text =
  let starts = ref [ 0 ] in
  for index = 0 to String.length text - 1 do
    if text.[index] = '\n' then starts := (index + 1) :: !starts
  done;
  Array.of_list (List.rev !starts)

let make_file_buffer path text =
  let path = normalize_path path in
  { path; uri = uri_of_path path; text; line_starts = line_starts_of_text text }

let zero_position = { line = 0; character = 0 }
let zero_range = { start_pos = zero_position; end_pos = zero_position }

let basic_range_of_loc (loc : Loc.t) =
  let start_line = max 0 (loc.start_pos.line - 1) in
  let end_line = max 0 (loc.end_pos.line - 1) in
  {
    start_pos = { line = start_line; character = max 0 loc.start_pos.column };
    end_pos = { line = end_line; character = max 0 loc.end_pos.column };
  }

let position_of_offset (file : file_buffer) offset =
  let offset = max 0 (min offset (String.length file.text)) in
  let low = ref 0 in
  let high = ref (Array.length file.line_starts - 1) in
  while !low <= !high do
    let mid = (!low + !high) / 2 in
    if file.line_starts.(mid) <= offset then low := mid + 1 else high := mid - 1
  done;
  let line = max 0 !high in
  { line; character = offset - file.line_starts.(line) }

let range_of_offsets file start_offset end_offset =
  {
    start_pos = position_of_offset file start_offset;
    end_pos = position_of_offset file end_offset;
  }

let file_buffer_of_loc builder (loc : Loc.t) =
  StringMap.find_opt (normalize_path loc.file) builder.files

let is_ident_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '\'' -> true
  | _ -> false

let range_for_name_in_loc builder path (loc : Loc.t) ~name ~prefer_last
    ?(allow_qualified_prefix = false) () =
  let path = normalize_path path in
  match StringMap.find_opt path builder.files with
  | None -> basic_range_of_loc loc
  | Some file -> (
      let start_offset = max 0 loc.start_pos.offset in
      let end_offset = min (String.length file.text) loc.end_pos.offset in
      if start_offset >= end_offset || String.length name = 0 then
        basic_range_of_loc loc
      else
        let snippet =
          String.sub file.text start_offset (end_offset - start_offset)
        in
        let limit = String.length snippet - String.length name in
        let matches = ref [] in
        for index = 0 to max (-1) limit do
          if index >= 0 && String.sub snippet index (String.length name) = name
          then
            let before_ok =
              index = 0
              ||
              let ch = snippet.[index - 1] in
              if allow_qualified_prefix then not (is_ident_char ch)
              else not (is_ident_char ch || ch = '.')
            in
            let after_index = index + String.length name in
            let after_ok =
              after_index >= String.length snippet
              ||
              let ch = snippet.[after_index] in
              not (is_ident_char ch || ch = '.')
            in
            if before_ok && after_ok then matches := index :: !matches
        done;
        match List.rev !matches with
        | [] -> basic_range_of_loc loc
        | matches ->
            let chosen =
              if prefer_last then List.hd (List.rev matches)
              else List.hd matches
            in
            let start_offset = start_offset + chosen in
            let end_offset = start_offset + String.length name in
            range_of_offsets file start_offset end_offset)

let range_size range =
  ((range.end_pos.line - range.start_pos.line) * 1_000_000)
  + (range.end_pos.character - range.start_pos.character)

let position_in_range line character range =
  let after_start =
    line > range.start_pos.line
    || (line = range.start_pos.line && character >= range.start_pos.character)
  in
  let before_end =
    line < range.end_pos.line
    || (line = range.end_pos.line && character <= range.end_pos.character)
  in
  after_start && before_end

let short_name = function
  | [] -> invalid_arg "empty qualified name"
  | names -> List.hd (List.rev names)

let empty_summary module_name path module_symbol_id =
  {
    module_name;
    path;
    module_symbol_id;
    type_ids = StringMap.empty;
    value_ids = StringMap.empty;
    ctor_ids = StringMap.empty;
    field_ids = StringMap.empty;
  }

let add_occurrence builder (occurrence : occurrence) =
  let items =
    match StringMap.find_opt occurrence.uri builder.occurrences_by_uri with
    | Some items -> occurrence :: items
    | None -> [ occurrence ]
  in
  builder.occurrences_by_uri <-
    StringMap.add occurrence.uri items builder.occurrences_by_uri

let add_diagnostic builder (diagnostic : diagnostic) =
  let items =
    match StringMap.find_opt diagnostic.uri builder.diagnostics_by_uri with
    | Some items -> diagnostic :: items
    | None -> [ diagnostic ]
  in
  builder.diagnostics_by_uri <-
    StringMap.add diagnostic.uri items builder.diagnostics_by_uri

let add_document_symbols builder uri symbols =
  builder.document_symbols_by_uri <-
    StringMap.add uri symbols builder.document_symbols_by_uri

let add_symbol builder (symbol : symbol) =
  Hashtbl.replace builder.symbols symbol.id symbol

let builtin_type_names =
  StringSet.of_list
    [ "string"; "int"; "bool"; "float"; "unit"; "list"; "option" ]

let builtin_value_names =
  StringSet.of_list
    [
      "+";
      "-";
      "*";
      "/";
      "mod";
      "+.";
      "-.";
      "*.";
      "/.";
      "=";
      "<>";
      "<";
      "<=";
      ">";
      ">=";
      "&&";
      "||";
      "not";
      "^";
    ]

let is_builtin_constructor = function
  | [ "Some" ]
  | [ "None" ]
  | [ "[]" ]
  | [ "::" ]
  | [ "true" ]
  | [ "false" ]
  | [ "()" ] ->
      true
  | _ -> false

let symbol_kind_name = function
  | Module -> "module"
  | Type -> "type"
  | Constructor -> "constructor"
  | Field -> "field"
  | Value -> "value"
  | Agent -> "agent"
  | Skill -> "skill"
  | Parameter -> "parameter"
  | Local -> "value"

let lsp_symbol_kind = function
  | Module -> 2
  | Type -> 23
  | Constructor -> 22
  | Field -> 8
  | Value | Agent | Skill -> 12
  | Parameter | Local -> 13

let string_of_qname = Syntax.Ast.string_of_qname

let terminal_name_of_qname = function
  | [] -> ""
  | names -> List.hd (List.rev names)

let rec string_of_type_expr (typ : Syntax.Ast.type_expr) =
  match typ.Syntax.Ast.type_desc with
  | Syntax.Ast.TEConstr (name, []) -> string_of_qname name
  | Syntax.Ast.TEConstr (name, args) ->
      let args = List.map string_of_type_expr args |> String.concat ", " in
      Printf.sprintf "%s<%s>" (string_of_qname name) args
  | Syntax.Ast.TETuple items ->
      items |> List.map string_of_type_expr |> String.concat " * "
  | Syntax.Ast.TEArrow (param, result) ->
      let left =
        match param.Syntax.Ast.param_label with
        | None -> string_of_type_expr param.Syntax.Ast.param_typ
        | Some label ->
            Printf.sprintf "%s:%s" label
              (string_of_type_expr param.Syntax.Ast.param_typ)
      in
      Printf.sprintf "%s -> %s" left (string_of_type_expr result)

let string_of_param (param : Syntax.Ast.param) =
  match param.Syntax.Ast.param_annotation with
  | Some annotation -> (
      match param.Syntax.Ast.param_label with
      | None ->
          Printf.sprintf "%s:%s" param.param_name
            (string_of_type_expr annotation)
      | Some label ->
          Printf.sprintf "~%s:%s" label (string_of_type_expr annotation))
  | None -> param.param_name

let render_binding_hover (binding : Syntax.Ast.binding) =
  match binding.Syntax.Ast.binding_annotation with
  | Some annotation ->
      Some
        (Printf.sprintf "let %s : %s" binding.binding_name
           (string_of_type_expr annotation))
  | None ->
      if binding.binding_params = [] then
        Some (Printf.sprintf "let %s" binding.binding_name)
      else
        let params =
          binding.binding_params |> List.map string_of_param
          |> String.concat " -> "
        in
        Some (Printf.sprintf "let %s : %s -> ?" binding.binding_name params)

let render_callable_hover keyword (callable : Syntax.Ast.callable_decl) =
  let params =
    callable.callable_params
    |> List.map (fun (param : Syntax.Ast.param_type) ->
        match param.Syntax.Ast.param_label with
        | None -> string_of_type_expr param.Syntax.Ast.param_typ
        | Some label ->
            Printf.sprintf "%s:%s" label
              (string_of_type_expr param.Syntax.Ast.param_typ))
    |> String.concat " -> "
  in
  let suffix =
    if String.equal params "" then
      string_of_type_expr callable.callable_return_type
    else
      Printf.sprintf "%s -> %s" params
        (string_of_type_expr callable.callable_return_type)
  in
  Some (Printf.sprintf "%s %s : %s" keyword callable.callable_name suffix)

let render_type_decl_hover (decl : Syntax.Ast.type_decl) =
  let body =
    match decl.Syntax.Ast.type_kind with
    | Syntax.Ast.Type_alias typ -> string_of_type_expr typ
    | Syntax.Ast.Type_record fields ->
        fields
        |> List.map (fun field ->
            Printf.sprintf "%s : %s" field.Syntax.Ast.field_name
              (string_of_type_expr field.Syntax.Ast.field_type))
        |> String.concat "; " |> Printf.sprintf "{ %s }"
    | Syntax.Ast.Type_variant ctors ->
        ctors
        |> List.map (fun ctor ->
            match ctor.Syntax.Ast.ctor_args with
            | [] -> ctor.Syntax.Ast.ctor_name
            | args ->
                Printf.sprintf "%s of %s" ctor.Syntax.Ast.ctor_name
                  (args |> List.map string_of_type_expr |> String.concat " * "))
        |> String.concat " | "
  in
  Some (Printf.sprintf "type %s = %s" decl.type_name body)

let render_field_hover parent_name (field : Syntax.Ast.record_field) =
  Some
    (Printf.sprintf "field %s : %s\nparent type: %s" field.Syntax.Ast.field_name
       (string_of_type_expr field.Syntax.Ast.field_type)
       parent_name)

let render_ctor_hover parent_name (ctor : Syntax.Ast.variant_ctor) =
  let text =
    match ctor.Syntax.Ast.ctor_args with
    | [] -> ctor.Syntax.Ast.ctor_name
    | args ->
        Printf.sprintf "%s of %s" ctor.Syntax.Ast.ctor_name
          (args |> List.map string_of_type_expr |> String.concat " * ")
  in
  Some (Printf.sprintf "constructor %s\nparent type: %s" text parent_name)

let render_local_hover name annotation =
  match annotation with
  | Some typ -> Some (Printf.sprintf "%s : %s" name (string_of_type_expr typ))
  | None -> Some name

let symbol_id kind module_name name =
  Printf.sprintf "%s:%s:%s" kind (string_of_qname module_name) name

let local_symbol_id path loc kind name =
  Printf.sprintf "local:%s:%d:%s:%s" (normalize_path path)
    loc.Loc.start_pos.offset kind name

let top_level_symbol builder module_ name kind loc hover renameable =
  let path = normalize_path module_.Syntax.Ast.module_path in
  let uri = uri_of_path path in
  let selection_range =
    range_for_name_in_loc builder path loc ~name ~prefer_last:false ()
  in
  let decl_range = basic_range_of_loc loc in
  let id =
    symbol_id
      (match kind with
      | Type -> "type"
      | Constructor -> "ctor"
      | Field -> "field"
      | Value -> "value"
      | Agent -> "agent"
      | Skill -> "skill"
      | Module | Parameter | Local -> "symbol")
      module_.module_name name
  in
  let symbol =
    {
      id;
      name;
      kind;
      uri;
      decl_range;
      decl_selection_range = selection_range;
      hover;
      renameable;
    }
  in
  add_symbol builder symbol;
  add_occurrence builder
    { symbol_id = id; uri; range = selection_range; role = Declaration };
  (id, symbol)

let create_local_symbol builder path loc name kind annotation =
  let uri = uri_of_path path in
  let id =
    local_symbol_id path loc
      (match kind with Parameter -> "param" | _ -> "local")
      name
  in
  let selection_range =
    range_for_name_in_loc builder path loc ~name ~prefer_last:false ()
  in
  let symbol =
    {
      id;
      name;
      kind;
      uri;
      decl_range = basic_range_of_loc loc;
      decl_selection_range = selection_range;
      hover = render_local_hover name annotation;
      renameable = true;
    }
  in
  add_symbol builder symbol;
  add_occurrence builder
    { symbol_id = id; uri; range = selection_range; role = Declaration };
  id

let rec read_text_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error message ->
    Error (Printf.sprintf "failed to read %s: %s" path message)

let load_program ~overlays ~root_path ~include_paths =
  let include_paths = List.map normalize_path include_paths in
  let root_path = normalize_path root_path in
  let read_source path =
    let path = normalize_path path in
    match StringMap.find_opt path overlays with
    | Some source -> Ok source
    | None -> read_text_file path
  in
  let state_modules = ref StringMap.empty in
  let state_files = ref StringMap.empty in
  let visiting = ref StringSet.empty in
  let rec visit ~from_dir ~(module_name : Syntax.Ast.qname) ~(path : string) =
    let path = normalize_path path in
    let key = module_key module_name in
    if StringMap.mem key !state_modules then Ok ()
    else if StringSet.mem key !visiting then
      Error (Printf.sprintf "cyclic module dependency involving %s" key)
    else
      let () = visiting := StringSet.add key !visiting in
      let result =
        let* source = read_source path in
        let () =
          state_files :=
            StringMap.add path (make_file_buffer path source) !state_files
        in
        let* module_ = Parsing_driver.parse_module ~module_name ~path source in
        let dependencies = Project_loader.module_dependencies module_ in
        let* () =
          List.fold_left
            (fun acc dependency ->
              let* () = acc in
              let* resolved =
                Project_loader.resolve_module_path ~from_dir ~include_paths
                  dependency
              in
              visit
                ~from_dir:(Filename.dirname resolved)
                ~module_name:dependency ~path:resolved)
            (Ok ()) dependencies
        in
        let () = state_modules := StringMap.add key module_ !state_modules in
        Ok ()
      in
      let () = visiting := StringSet.remove key !visiting in
      result
  in
  let root_module = Parsing_driver.module_name_of_basename root_path in
  let* () =
    visit
      ~from_dir:(Filename.dirname root_path)
      ~module_name:root_module ~path:root_path
  in
  let modules = !state_modules |> StringMap.bindings |> List.map snd in
  Ok { program = { Syntax.Ast.root_module; modules }; files = !state_files }

let program_contains_path (program : Syntax.Ast.program) path =
  let path = normalize_path path in
  List.exists
    (fun (module_ : Syntax.Ast.module_) ->
      String.equal (normalize_path module_.module_path) path)
    program.modules

let choose_project_context path =
  let path = normalize_path path in
  let working_directory = Filename.dirname path in
  match Project_config.load_nearest ~working_directory with
  | Ok (Some config) -> (
      match config.Project_config.program with
      | Some program ->
          {
            project_id = normalize_path program;
            root_path = normalize_path program;
            include_paths = Option.value config.include_paths ~default:[];
          }
      | None ->
          {
            project_id = path;
            root_path = path;
            include_paths = Option.value config.include_paths ~default:[];
          })
  | Ok None | Error _ ->
      { project_id = path; root_path = path; include_paths = [] }

let parse_loc_suffix message =
  let marker = " at " in
  let rec find_last start last =
    if start > String.length message - String.length marker then last
    else if String.sub message start (String.length marker) = marker then
      find_last (start + 1) (Some start)
    else find_last (start + 1) last
  in
  match find_last 0 None with
  | None -> None
  | Some index -> (
      let prefix = String.sub message 0 index in
      let suffix =
        String.sub message
          (index + String.length marker)
          (String.length message - index - String.length marker)
      in
      try
        Scanf.sscanf suffix "%[^:]:%d:%d-%d:%d"
          (fun file start_line start_col end_line end_col ->
            Some
              ( prefix,
                {
                  Loc.file;
                  start_pos =
                    { line = start_line; column = start_col; offset = 0 };
                  end_pos = { line = end_line; column = end_col; offset = 0 };
                } ))
      with _ -> None)

let diagnostic_from_message builder ~fallback_path message =
  match parse_loc_suffix message with
  | Some (text, loc) ->
      let path =
        if String.equal loc.Loc.file "" then normalize_path fallback_path
        else normalize_path loc.Loc.file
      in
      {
        uri = uri_of_path path;
        range = basic_range_of_loc { loc with file = path };
        severity = 1;
        source = "camlflow";
        message = text;
      }
  | None ->
      {
        uri = uri_of_path fallback_path;
        range = zero_range;
        severity = 1;
        source = "camlflow";
        message;
      }

let module_prefix_of_qname = function
  | [] | [ _ ] -> None
  | names -> Some (List.rev (List.tl (List.rev names)))

let opened_modules env =
  List.filter_map
    (fun name -> StringMap.find_opt (module_key name) env.catalogs)
    env.opened

let unique_or_error kind name = function
  | [] -> Error (Printf.sprintf "unbound %s %s" kind name)
  | [ item ] -> Ok item
  | _ -> Error (Printf.sprintf "ambiguous %s %s" kind name)

let lookup_module env (name : Syntax.Ast.qname) =
  let requested = short_name name in
  if env.current_summary.module_name = name then Ok env.current_summary
  else if String.equal (short_name env.current_summary.module_name) requested
  then Ok env.current_summary
  else
    match StringMap.find_opt (module_key name) env.catalogs with
    | Some summary -> Ok summary
    | None ->
        let candidates =
          env.catalogs |> StringMap.bindings
          |> List.filter_map (fun (_key, summary) ->
              if String.equal (short_name summary.module_name) requested then
                Some summary
              else None)
        in
        unique_or_error "module" (string_of_qname name) candidates

let lookup_type env (name : Syntax.Ast.qname) =
  match List.rev name with
  | [] -> Error "empty type name"
  | short :: rev_mod -> (
      let module_path = List.rev rev_mod in
      if module_path = [] then
        match StringMap.find_opt short env.current_summary.type_ids with
        | Some symbol_id -> Ok symbol_id
        | None ->
            let candidates =
              opened_modules env
              |> List.filter_map (fun summary ->
                  StringMap.find_opt short summary.type_ids)
            in
            unique_or_error "type" short candidates
      else
        let* summary = lookup_module env module_path in
        match StringMap.find_opt short summary.type_ids with
        | Some symbol_id -> Ok symbol_id
        | None ->
            Error (Printf.sprintf "unbound type %s" (string_of_qname name)))

let lookup_value env (name : Syntax.Ast.qname) =
  match List.rev name with
  | [] -> Error "empty value name"
  | short :: rev_mod -> (
      let module_path = List.rev rev_mod in
      if module_path = [] then
        match StringMap.find_opt short env.locals with
        | Some symbol_id -> Ok symbol_id
        | None -> (
            match StringMap.find_opt short env.current_summary.value_ids with
            | Some symbol_id -> Ok symbol_id
            | None ->
                let candidates =
                  opened_modules env
                  |> List.filter_map (fun summary ->
                      StringMap.find_opt short summary.value_ids)
                in
                unique_or_error "value" short candidates)
      else
        let* summary = lookup_module env module_path in
        match StringMap.find_opt short summary.value_ids with
        | Some symbol_id -> Ok symbol_id
        | None ->
            Error (Printf.sprintf "unbound value %s" (string_of_qname name)))

let lookup_constructor env (name : Syntax.Ast.qname) =
  match List.rev name with
  | [] -> Error "empty constructor name"
  | short :: rev_mod ->
      let module_path = List.rev rev_mod in
      if module_path = [] then
        match StringMap.find_opt short env.current_summary.ctor_ids with
        | Some symbol_ids when symbol_ids <> [] ->
            unique_or_error "constructor" short symbol_ids
        | _ ->
            let candidates =
              opened_modules env
              |> List.concat_map (fun summary ->
                  match StringMap.find_opt short summary.ctor_ids with
                  | Some items -> items
                  | None -> [])
            in
            unique_or_error "constructor" short candidates
      else
        let* summary = lookup_module env module_path in
        let candidates =
          match StringMap.find_opt short summary.ctor_ids with
          | Some items -> items
          | None -> []
        in
        unique_or_error "constructor" (string_of_qname name) candidates

let lookup_field env name =
  match StringMap.find_opt name env.current_summary.field_ids with
  | Some symbol_ids when symbol_ids <> [] ->
      unique_or_error "field" name symbol_ids
  | _ ->
      let candidates =
        opened_modules env
        |> List.concat_map (fun summary ->
            match StringMap.find_opt name summary.field_ids with
            | Some items -> items
            | None -> [])
      in
      unique_or_error "field" name candidates

let add_resolution_diagnostic env loc message =
  let path =
    if String.equal loc.Loc.file "" then env.current_summary.path else loc.file
  in
  add_diagnostic env.builder
    {
      uri = uri_of_path path;
      range = basic_range_of_loc { loc with file = path };
      severity = 1;
      source = "camlflow";
      message;
    }

let add_reference_occurrence env symbol_id path loc name ~prefer_last =
  let range =
    range_for_name_in_loc env.builder path loc ~name ~prefer_last ()
  in
  add_occurrence env.builder
    { symbol_id; uri = uri_of_path path; range; role = Reference }

let add_qname_reference_occurrence env symbol_id path loc name =
  let terminal_name = terminal_name_of_qname name in
  let range =
    range_for_name_in_loc env.builder path loc ~name:terminal_name
      ~prefer_last:true ~allow_qualified_prefix:true ()
  in
  add_occurrence env.builder
    { symbol_id; uri = uri_of_path path; range; role = Reference }

let add_module_prefix_reference env path loc name =
  match module_prefix_of_qname name with
  | None -> ()
  | Some module_name -> (
      match lookup_module env module_name with
      | Ok summary ->
          add_reference_occurrence env summary.module_symbol_id path loc
            (string_of_qname module_name)
            ~prefer_last:false
      | Error message -> add_resolution_diagnostic env loc message)

let rec walk_type_expr env path (typ : Syntax.Ast.type_expr) =
  match typ.Syntax.Ast.type_desc with
  | Syntax.Ast.TEConstr (name, args) ->
      add_module_prefix_reference env path typ.type_loc name;
      (if
         not
           (match name with
           | [ single ] -> StringSet.mem single builtin_type_names
           | _ -> false)
       then
         match lookup_type env name with
         | Ok symbol_id ->
             add_qname_reference_occurrence env symbol_id path typ.type_loc name
         | Error message -> add_resolution_diagnostic env typ.type_loc message);
      List.iter (walk_type_expr env path) args
  | Syntax.Ast.TETuple items -> List.iter (walk_type_expr env path) items
  | Syntax.Ast.TEArrow (param, result) ->
      walk_type_expr env path param.Syntax.Ast.param_typ;
      walk_type_expr env path result

let walk_param_annotation env path (param : Syntax.Ast.param) =
  match param.Syntax.Ast.param_annotation with
  | Some typ -> walk_type_expr env path typ
  | None -> ()

let rec bind_pattern_locals env path locals (pattern : Syntax.Ast.pattern) =
  match pattern.Syntax.Ast.pattern_desc with
  | Syntax.Ast.PWildcard | PLiteral _ -> locals
  | Syntax.Ast.PVar name ->
      let symbol_id =
        create_local_symbol env.builder path pattern.pattern_loc name Local None
      in
      StringMap.add name symbol_id locals
  | Syntax.Ast.PTuple items ->
      List.fold_left (bind_pattern_locals env path) locals items
  | Syntax.Ast.PRecord fields ->
      List.fold_left
        (fun acc (_field_name, item) -> bind_pattern_locals env path acc item)
        locals fields
  | Syntax.Ast.PConstruct (name, args) ->
      add_module_prefix_reference env path pattern.pattern_loc name;
      (if not (is_builtin_constructor name) then
         match lookup_constructor env name with
         | Ok symbol_id ->
             add_qname_reference_occurrence env symbol_id path
               pattern.pattern_loc name
         | Error message ->
             add_resolution_diagnostic env pattern.pattern_loc message);
      List.fold_left (bind_pattern_locals env path) locals args

let rec walk_expr env path (expr : Syntax.Ast.expr) =
  match expr.Syntax.Ast.expr_desc with
  | Syntax.Ast.ELiteral _ -> ()
  | Syntax.Ast.EVar name -> (
      add_module_prefix_reference env path expr.expr_loc name;
      if
        not
          (match name with
          | [ single ] -> StringSet.mem single builtin_value_names
          | _ -> false)
      then
        match lookup_value env name with
        | Ok symbol_id ->
            add_qname_reference_occurrence env symbol_id path expr.expr_loc name
        | Error message -> add_resolution_diagnostic env expr.expr_loc message)
  | Syntax.Ast.ETuple items -> List.iter (walk_expr env path) items
  | Syntax.Ast.ERecord fields ->
      List.iter (fun (_name, value) -> walk_expr env path value) fields
  | Syntax.Ast.EField (target, field_name) -> (
      walk_expr env path target;
      match lookup_field env field_name with
      | Ok symbol_id ->
          add_reference_occurrence env symbol_id path expr.expr_loc field_name
            ~prefer_last:true
      | Error _ -> ())
  | Syntax.Ast.EConstruct (name, args) ->
      add_module_prefix_reference env path expr.expr_loc name;
      (if not (is_builtin_constructor name) then
         match lookup_constructor env name with
         | Ok symbol_id ->
             add_qname_reference_occurrence env symbol_id path expr.expr_loc
               name
         | Error message -> add_resolution_diagnostic env expr.expr_loc message);
      List.iter (walk_expr env path) args
  | Syntax.Ast.ELet (binding, body) ->
      walk_binding env path binding;
      let local_id =
        create_local_symbol env.builder path binding.binding_loc
          binding.binding_name Local binding.binding_annotation
      in
      let env_body =
        {
          env with
          locals = StringMap.add binding.binding_name local_id env.locals;
        }
      in
      walk_expr env_body path body
  | Syntax.Ast.ELetStar (binding, body) ->
      walk_expr env path binding.Syntax.Ast.let_star_value;
      let local_id =
        create_local_symbol env.builder path binding.let_star_loc
          binding.let_star_name Local None
      in
      let env_body =
        {
          env with
          locals = StringMap.add binding.let_star_name local_id env.locals;
        }
      in
      walk_expr env_body path body
  | Syntax.Ast.EIf (cond, then_branch, else_branch) ->
      walk_expr env path cond;
      walk_expr env path then_branch;
      walk_expr env path else_branch
  | Syntax.Ast.EMatch (scrutinee, cases) ->
      walk_expr env path scrutinee;
      List.iter
        (fun (case : Syntax.Ast.case) ->
          let locals =
            bind_pattern_locals env path env.locals case.case_pattern
          in
          let env_case = { env with locals } in
          walk_expr env_case path case.case_body)
        cases
  | Syntax.Ast.EApply (fn, args) ->
      walk_expr env path fn;
      List.iter (fun arg -> walk_expr env path arg.Syntax.Ast.arg_value) args
  | Syntax.Ast.ELambda (params, body) ->
      List.iter (walk_param_annotation env path) params;
      let locals =
        List.fold_left
          (fun locals (param : Syntax.Ast.param) ->
            let symbol_id =
              create_local_symbol env.builder path param.param_loc
                param.param_name Parameter param.param_annotation
            in
            StringMap.add param.param_name symbol_id locals)
          env.locals params
      in
      walk_expr { env with locals } path body

and walk_binding env path (binding : Syntax.Ast.binding) =
  (match binding.binding_annotation with
  | Some annotation -> walk_type_expr env path annotation
  | None -> ());
  let recursive_locals =
    if binding.binding_recursive then
      let self_id =
        create_local_symbol env.builder path binding.binding_loc
          binding.binding_name Local binding.binding_annotation
      in
      StringMap.add binding.binding_name self_id env.locals
    else env.locals
  in
  List.iter (walk_param_annotation env path) binding.binding_params;
  let body_locals =
    List.fold_left
      (fun locals (param : Syntax.Ast.param) ->
        let symbol_id =
          create_local_symbol env.builder path param.param_loc param.param_name
            Parameter param.param_annotation
        in
        StringMap.add param.param_name symbol_id locals)
      recursive_locals binding.binding_params
  in
  walk_expr { env with locals = body_locals } path binding.binding_body

let add_type_to_summary summary type_name type_id field_ids ctor_ids =
  {
    summary with
    type_ids = StringMap.add type_name type_id summary.type_ids;
    field_ids =
      List.fold_left
        (fun acc (name, symbol_id) ->
          let items =
            match StringMap.find_opt name acc with
            | Some items -> items
            | None -> []
          in
          StringMap.add name (symbol_id :: items) acc)
        summary.field_ids field_ids;
    ctor_ids =
      List.fold_left
        (fun acc (name, symbol_id) ->
          let items =
            match StringMap.find_opt name acc with
            | Some items -> items
            | None -> []
          in
          StringMap.add name (symbol_id :: items) acc)
        summary.ctor_ids ctor_ids;
  }

let build_catalogs builder (program : Syntax.Ast.program) =
  let build_module (module_ : Syntax.Ast.module_) =
    let module_id =
      symbol_id "module" module_.module_name
        (string_of_qname module_.module_name)
    in
    let module_symbol =
      {
        id = module_id;
        name = string_of_qname module_.module_name;
        kind = Module;
        uri = uri_of_path module_.module_path;
        decl_range = basic_range_of_loc module_.module_loc;
        decl_selection_range = basic_range_of_loc module_.module_loc;
        hover =
          Some
            (Printf.sprintf "module %s" (string_of_qname module_.module_name));
        renameable = false;
      }
    in
    add_symbol builder module_symbol;
    let summary =
      ref (empty_summary module_.module_name module_.module_path module_id)
    in
    let document_symbols = ref [] in
    List.iter
      (function
        | Syntax.Ast.TypeDecl decl ->
            let type_id, type_symbol =
              top_level_symbol builder module_ decl.type_name Type
                decl.type_decl_loc
                (render_type_decl_hover decl)
                true
            in
            let children =
              match decl.Syntax.Ast.type_kind with
              | Syntax.Ast.Type_alias _ -> []
              | Syntax.Ast.Type_record fields ->
                  fields
                  |> List.map (fun (field : Syntax.Ast.record_field) ->
                      let field_id, field_symbol =
                        top_level_symbol builder module_
                          field.Syntax.Ast.field_name Field
                          field.Syntax.Ast.field_loc
                          (render_field_hover decl.type_name field)
                          true
                      in
                      (field.Syntax.Ast.field_name, field_id, field_symbol))
              | Syntax.Ast.Type_variant ctors ->
                  ctors
                  |> List.map (fun (ctor : Syntax.Ast.variant_ctor) ->
                      let ctor_id, ctor_symbol =
                        top_level_symbol builder module_
                          ctor.Syntax.Ast.ctor_name Constructor
                          ctor.Syntax.Ast.ctor_loc
                          (render_ctor_hover decl.type_name ctor)
                          true
                      in
                      (ctor.Syntax.Ast.ctor_name, ctor_id, ctor_symbol))
            in
            let field_ids, ctor_ids, child_symbols =
              match decl.Syntax.Ast.type_kind with
              | Syntax.Ast.Type_alias _ -> ([], [], [])
              | Syntax.Ast.Type_record _ ->
                  ( List.map (fun (name, id, _symbol) -> (name, id)) children,
                    [],
                    List.map
                      (fun (name, _id, symbol) ->
                        {
                          name;
                          detail = None;
                          kind = lsp_symbol_kind Field;
                          range = symbol.decl_range;
                          selection_range = symbol.decl_selection_range;
                          children = [];
                        })
                      children )
              | Syntax.Ast.Type_variant _ ->
                  ( [],
                    List.map (fun (name, id, _symbol) -> (name, id)) children,
                    List.map
                      (fun (name, _id, symbol) ->
                        {
                          name;
                          detail = None;
                          kind = lsp_symbol_kind Constructor;
                          range = symbol.decl_range;
                          selection_range = symbol.decl_selection_range;
                          children = [];
                        })
                      children )
            in
            summary :=
              add_type_to_summary !summary decl.type_name type_id field_ids
                ctor_ids;
            document_symbols :=
              {
                name = decl.type_name;
                detail = None;
                kind = lsp_symbol_kind Type;
                range = type_symbol.decl_range;
                selection_range = type_symbol.decl_selection_range;
                children = child_symbols;
              }
              :: !document_symbols
        | Syntax.Ast.LetDecl binding ->
            let value_id, value_symbol =
              top_level_symbol builder module_ binding.binding_name Value
                binding.binding_loc
                (render_binding_hover binding)
                true
            in
            summary :=
              {
                !summary with
                value_ids =
                  StringMap.add binding.binding_name value_id !summary.value_ids;
              };
            document_symbols :=
              {
                name = binding.binding_name;
                detail = None;
                kind = lsp_symbol_kind Value;
                range = value_symbol.decl_range;
                selection_range = value_symbol.decl_selection_range;
                children = [];
              }
              :: !document_symbols
        | Syntax.Ast.AgentDecl callable ->
            let symbol_id, symbol =
              top_level_symbol builder module_ callable.callable_name Agent
                callable.callable_loc
                (render_callable_hover "agent" callable)
                true
            in
            summary :=
              {
                !summary with
                value_ids =
                  StringMap.add callable.callable_name symbol_id
                    !summary.value_ids;
              };
            document_symbols :=
              {
                name = callable.callable_name;
                detail = None;
                kind = lsp_symbol_kind Agent;
                range = symbol.decl_range;
                selection_range = symbol.decl_selection_range;
                children = [];
              }
              :: !document_symbols
        | Syntax.Ast.SkillDecl callable ->
            let symbol_id, symbol =
              top_level_symbol builder module_ callable.callable_name Skill
                callable.callable_loc
                (render_callable_hover "skill" callable)
                true
            in
            summary :=
              {
                !summary with
                value_ids =
                  StringMap.add callable.callable_name symbol_id
                    !summary.value_ids;
              };
            document_symbols :=
              {
                name = callable.callable_name;
                detail = None;
                kind = lsp_symbol_kind Skill;
                range = symbol.decl_range;
                selection_range = symbol.decl_selection_range;
                children = [];
              }
              :: !document_symbols
        | Syntax.Ast.OpenDecl _ -> ())
      module_.module_decls;
    add_document_symbols builder
      (uri_of_path module_.module_path)
      (List.rev !document_symbols);
    (!summary, module_)
  in
  program.modules |> List.map build_module
  |> List.fold_left
       (fun acc (summary, _module_) ->
         StringMap.add (module_key summary.module_name) summary acc)
       StringMap.empty

let add_value_to_summary summary name symbol_id =
  { summary with value_ids = StringMap.add name symbol_id summary.value_ids }

let rec walk_modules builder catalogs (program : Syntax.Ast.program) =
  let find_catalog module_name =
    match StringMap.find_opt (module_key module_name) catalogs with
    | Some summary -> summary
    | None -> invalid_arg "missing catalog"
  in
  let walk_module (module_ : Syntax.Ast.module_) =
    let full_summary = find_catalog module_.module_name in
    let rec loop current_summary opened = function
      | [] -> ()
      | decl :: rest -> (
          let base_env =
            {
              builder;
              catalogs;
              current_summary;
              opened;
              locals = StringMap.empty;
            }
          in
          match decl with
          | Syntax.Ast.OpenDecl (opened_name, loc) ->
              add_module_prefix_reference base_env current_summary.path loc
                opened_name;
              let opened' =
                match lookup_module base_env opened_name with
                | Ok _ -> opened_name :: opened
                | Error message ->
                    add_resolution_diagnostic base_env loc message;
                    opened
              in
              loop current_summary opened' rest
          | Syntax.Ast.TypeDecl decl ->
              (match decl.Syntax.Ast.type_kind with
              | Syntax.Ast.Type_alias typ ->
                  walk_type_expr base_env current_summary.path typ
              | Syntax.Ast.Type_record fields ->
                  List.iter
                    (fun field ->
                      walk_type_expr base_env current_summary.path
                        field.Syntax.Ast.field_type)
                    fields
              | Syntax.Ast.Type_variant ctors ->
                  List.iter
                    (fun ctor ->
                      List.iter
                        (walk_type_expr base_env current_summary.path)
                        ctor.Syntax.Ast.ctor_args)
                    ctors);
              let current_summary =
                match
                  StringMap.find_opt decl.type_name full_summary.type_ids
                with
                | None -> current_summary
                | Some type_id ->
                    let field_ids =
                      match decl.Syntax.Ast.type_kind with
                      | Syntax.Ast.Type_record fields ->
                          List.filter_map
                            (fun (field : Syntax.Ast.record_field) ->
                              match
                                StringMap.find_opt field.Syntax.Ast.field_name
                                  full_summary.field_ids
                              with
                              | Some (symbol_id :: _) ->
                                  Some (field.Syntax.Ast.field_name, symbol_id)
                              | _ -> None)
                            fields
                      | _ -> []
                    in
                    let ctor_ids =
                      match decl.Syntax.Ast.type_kind with
                      | Syntax.Ast.Type_variant ctors ->
                          List.filter_map
                            (fun (ctor : Syntax.Ast.variant_ctor) ->
                              match
                                StringMap.find_opt ctor.Syntax.Ast.ctor_name
                                  full_summary.ctor_ids
                              with
                              | Some (symbol_id :: _) ->
                                  Some (ctor.Syntax.Ast.ctor_name, symbol_id)
                              | _ -> None)
                            ctors
                      | _ -> []
                    in
                    add_type_to_summary current_summary decl.type_name type_id
                      field_ids ctor_ids
              in
              loop current_summary opened rest
          | Syntax.Ast.LetDecl binding ->
              walk_binding base_env current_summary.path binding;
              let current_summary =
                match
                  StringMap.find_opt binding.binding_name full_summary.value_ids
                with
                | Some symbol_id ->
                    add_value_to_summary current_summary binding.binding_name
                      symbol_id
                | None -> current_summary
              in
              loop current_summary opened rest
          | Syntax.Ast.AgentDecl callable ->
              List.iter
                (fun (param : Syntax.Ast.param_type) ->
                  walk_type_expr base_env current_summary.path param.param_typ)
                callable.callable_params;
              walk_type_expr base_env current_summary.path
                callable.callable_return_type;
              let current_summary =
                match
                  StringMap.find_opt callable.callable_name
                    full_summary.value_ids
                with
                | Some symbol_id ->
                    add_value_to_summary current_summary callable.callable_name
                      symbol_id
                | None -> current_summary
              in
              loop current_summary opened rest
          | Syntax.Ast.SkillDecl callable ->
              List.iter
                (fun (param : Syntax.Ast.param_type) ->
                  walk_type_expr base_env current_summary.path param.param_typ)
                callable.callable_params;
              walk_type_expr base_env current_summary.path
                callable.callable_return_type;
              let current_summary =
                match
                  StringMap.find_opt callable.callable_name
                    full_summary.value_ids
                with
                | Some symbol_id ->
                    add_value_to_summary current_summary callable.callable_name
                      symbol_id
                | None -> current_summary
              in
              loop current_summary opened rest)
    in
    loop
      (empty_summary module_.module_name module_.module_path
         full_summary.module_symbol_id)
      [] module_.module_decls
  in
  List.iter walk_module program.modules

let finalize_occurrences_by_symbol occurrences_by_uri =
  occurrences_by_uri |> StringMap.bindings
  |> List.fold_left
       (fun acc (_uri, items) ->
         List.fold_left
           (fun acc item ->
             let existing =
               match StringMap.find_opt item.symbol_id acc with
               | Some existing -> item :: existing
               | None -> [ item ]
             in
             StringMap.add item.symbol_id existing acc)
           acc items)
       StringMap.empty
  |> StringMap.map List.rev

let dedup_diagnostics diagnostics =
  let key (diagnostic : diagnostic) =
    Printf.sprintf "%s:%d:%d:%d:%d:%s" diagnostic.uri
      diagnostic.range.start_pos.line diagnostic.range.start_pos.character
      diagnostic.range.end_pos.line diagnostic.range.end_pos.character
      diagnostic.message
  in
  let seen = Hashtbl.create 16 in
  diagnostics
  |> List.fold_left
       (fun acc diagnostic ->
         let key = key diagnostic in
         if Hashtbl.mem seen key then acc
         else (
           Hashtbl.add seen key ();
           diagnostic :: acc))
       []
  |> List.rev

let analyze_with_loaded ~context ~current_path (loaded : loaded_project) =
  let builder =
    {
      current_uri = uri_of_path current_path;
      files = loaded.files;
      symbols = Hashtbl.create 128;
      occurrences_by_uri = StringMap.empty;
      diagnostics_by_uri = StringMap.empty;
      document_symbols_by_uri = StringMap.empty;
    }
  in
  let catalogs = build_catalogs builder loaded.program in
  walk_modules builder catalogs loaded.program;
  (match Typing.check loaded.program with
  | Ok _ -> ()
  | Error message ->
      add_diagnostic builder
        (diagnostic_from_message builder ~fallback_path:context.root_path
           message));
  let symbols =
    Hashtbl.to_seq builder.symbols
    |> List.of_seq |> List.to_seq |> StringMap.of_seq
  in
  let occurrences_by_uri = StringMap.map List.rev builder.occurrences_by_uri in
  let diagnostics_by_uri =
    StringMap.map
      (fun items -> dedup_diagnostics (List.rev items))
      builder.diagnostics_by_uri
  in
  {
    project_id = context.project_id;
    current_uri = builder.current_uri;
    symbols;
    occurrences_by_uri;
    occurrences_by_symbol = finalize_occurrences_by_symbol occurrences_by_uri;
    document_symbols_by_uri = builder.document_symbols_by_uri;
    diagnostics_by_uri;
  }

let analyze ?(overlays = StringMap.empty) path =
  let path = normalize_path path in
  let context = choose_project_context path in
  let load_current root_path =
    let context =
      if String.equal root_path context.root_path then context
      else { context with project_id = root_path; root_path }
    in
    match
      load_program ~overlays ~root_path ~include_paths:context.include_paths
    with
    | Ok loaded -> Ok (context, loaded)
    | Error error -> Error (context, error)
  in
  let loaded =
    match load_current context.root_path with
    | Ok (context, loaded)
      when (not (String.equal context.root_path path))
           && not (program_contains_path loaded.program path) ->
        load_current path
    | other -> other
  in
  match loaded with
  | Ok (context, loaded) ->
      analyze_with_loaded ~context ~current_path:path loaded
  | Error (context, error) ->
      {
        project_id = context.project_id;
        current_uri = uri_of_path path;
        symbols = StringMap.empty;
        occurrences_by_uri = StringMap.empty;
        occurrences_by_symbol = StringMap.empty;
        document_symbols_by_uri = StringMap.empty;
        diagnostics_by_uri =
          StringMap.singleton
            (uri_of_path context.root_path)
            [
              diagnostic_from_message
                {
                  current_uri = uri_of_path path;
                  files = StringMap.empty;
                  symbols = Hashtbl.create 1;
                  occurrences_by_uri = StringMap.empty;
                  diagnostics_by_uri = StringMap.empty;
                  document_symbols_by_uri = StringMap.empty;
                }
                ~fallback_path:context.root_path error;
            ];
      }

let diagnostics_for_uri (analysis : analysis) uri =
  match StringMap.find_opt uri analysis.diagnostics_by_uri with
  | Some items -> items
  | None -> []

let document_symbols_for_uri (analysis : analysis) uri =
  match StringMap.find_opt uri analysis.document_symbols_by_uri with
  | Some items -> items
  | None -> []

let occurrences_for_symbol (analysis : analysis) symbol_id =
  match StringMap.find_opt symbol_id analysis.occurrences_by_symbol with
  | Some items -> items
  | None -> []

let symbol_by_id (analysis : analysis) symbol_id =
  StringMap.find_opt symbol_id analysis.symbols

let symbol_at_position (analysis : analysis) uri ~line ~character =
  match StringMap.find_opt uri analysis.occurrences_by_uri with
  | None -> None
  | Some items ->
      items
      |> List.filter (fun item -> position_in_range line character item.range)
      |> List.sort (fun left right ->
          compare (range_size left.range) (range_size right.range))
      |> List.find_map (fun item ->
          match symbol_by_id analysis item.symbol_id with
          | Some symbol -> Some (item, symbol)
          | None -> None)
