let ( let* ) = Result.bind

let die message =
  prerr_endline ("error: " ^ message);
  exit 1

let or_die = function
  | Ok value -> value
  | Error message -> die message

let help_text topic =
  Printf.sprintf "camlflow %s\n%s\n\n%s" Camlflow.version Camlflow.about
    (Camlflow.Cli.help_text topic)

let ensure_path_exists label path =
  if Sys.file_exists path then Ok ()
  else Error (Printf.sprintf "%s does not exist: %s" label path)

let ensure_file label path =
  let* () = ensure_path_exists label path in
  if Sys.is_directory path then
    Error (Printf.sprintf "%s must be a file, got directory: %s" label path)
  else Ok ()

let ensure_directory label path =
  let* () = ensure_path_exists label path in
  if Sys.is_directory path then Ok ()
  else Error (Printf.sprintf "%s must be a directory, got file: %s" label path)

let ensure_source_file label path =
  let* () = ensure_file label path in
  if Filename.check_suffix path ".json" then
    Error
      (Printf.sprintf "%s expects a CamlFlow source file, not a JSON artifact: %s"
         label path)
  else Ok ()

let read_text_file label path =
  let* () = ensure_file label path in
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error message ->
    Error (Printf.sprintf "failed to read %s %s: %s" label path message)

let write_text_file path content =
  try
    Out_channel.with_open_bin path (fun channel -> output_string channel content);
    Ok ()
  with Sys_error message ->
    Error (Printf.sprintf "failed to write output file %s: %s" path message)

let read_json_source = function
  | Some path, None ->
      let* source = read_text_file "JSON input file" path in
      (try Ok (Some (Yojson.Safe.from_string source)) with
      | Yojson.Json_error message ->
          Error
            (Printf.sprintf "failed to decode JSON input from %s: %s" path message))
  | None, Some json -> (
      try Ok (Some (Yojson.Safe.from_string json)) with
      | Yojson.Json_error message ->
          Error
            (Printf.sprintf "failed to decode inline JSON passed to --input-json: %s" message))
  | None, None -> Ok None
  | Some _, Some _ -> Error "run accepts either --input or --input-json, not both"

let load_program include_paths path =
  let* () = ensure_file "program path" path in
  if Filename.check_suffix path ".json" then
    let* source = read_text_file "JSON IR artifact" path in
    Camlflow.Ir.of_json_string source
    |> Result.map_error (fun error ->
           Printf.sprintf "failed to decode JSON IR artifact %s: %s" path error)
  else
    Camlflow.Typing.check_file ~include_paths path
    |> Result.map_error (fun error ->
           Printf.sprintf "failed to type-check source program %s: %s" path error)

let parse_source_file path =
  let* () = ensure_source_file "parse" path in
  Camlflow.Parsing.parse_file path
  |> Result.map_error (fun error ->
         Printf.sprintf "failed to parse source file %s: %s" path error)

let check_source_file include_paths path =
  let* () = ensure_source_file "check" path in
  Camlflow.Typing.check_file ~include_paths path
  |> Result.map_error (fun error ->
         Printf.sprintf "failed to check source file %s: %s" path error)

let compile_source_file include_paths path =
  let* () = ensure_source_file "compile" path in
  Camlflow.Typing.check_file ~include_paths path
  |> Result.map_error (fun error ->
         Printf.sprintf "failed to compile source file %s: %s" path error)

let print_parse path =
  let module_ = or_die (parse_source_file path) in
  Printf.printf "parsed %s (%d declarations)\n"
    (String.concat "." module_.Camlflow.Syntax.Ast.module_name)
    (List.length module_.Camlflow.Syntax.Ast.module_decls)

let print_check include_paths path =
  let program = or_die (check_source_file include_paths path) in
  Printf.printf "checked %d module(s)\n" (List.length program.Camlflow.Ir.modules)

let print_compile include_paths output path =
  let program = or_die (compile_source_file include_paths path) in
  let json = Camlflow.Ir.to_json_string program in
  (match output with
  | Some output_path ->
      or_die (write_text_file output_path json);
      Printf.printf "compiled %d module(s) to %s\n"
        (List.length program.Camlflow.Ir.modules) output_path
  | None ->
      print_endline json;
      Printf.printf "compiled %d module(s)\n"
        (List.length program.Camlflow.Ir.modules))

let resolve_path ~working_directory path =
  if Filename.is_relative path then Filename.concat working_directory path else path

let print_run (options : Camlflow.Cli.options) path =
  let working_directory = Sys.getcwd () in
  let () =
    match options.skills_dir with
    | Some dir -> or_die (ensure_directory "skills directory" dir)
    | None -> ()
  in
  let () =
    List.iter
      (fun dir ->
        or_die
          (ensure_directory "allowed write directory"
             (resolve_path ~working_directory dir)))
      options.provider_options.allow_write_dirs
  in
  let program = or_die (load_program options.include_paths path) in
  let base_context =
    let context = Camlflow.Runtime.Context.empty in
    let context =
      Camlflow.Runtime.Context.with_working_directory context working_directory
    in
    match options.skills_dir with
    | Some dir -> Camlflow.Runtime.Context.with_skills_directory context dir
    | None -> context
  in
  let context =
    match options.provider_options.provider with
    | None -> base_context
    | Some provider ->
        let adapter = Camlflow.Providers.find provider in
        let () =
          or_die
            (adapter.preflight ~working_directory ~settings:options.provider_options)
        in
        or_die
          (adapter.build_runtime_context ~working_directory
             ~settings:options.provider_options base_context)
  in
  let input =
    or_die (read_json_source (options.input_file, options.input_json))
  in
  match Camlflow.Runtime.execute ~context ~entry:options.entry ?input program with
  | Ok result ->
      Printf.printf "steps: %d\n" result.Camlflow.Runtime.steps_run;
      (match result.Camlflow.Runtime.output with
      | Some json -> print_endline (Yojson.Safe.pretty_to_string json)
      | None -> print_endline "null")
  | Error error -> die (Printf.sprintf "run failed for %s: %s" path error)

let dispatch (parsed : Camlflow.Cli.parsed) =
  match (parsed.command, parsed.positionals) with
  | Camlflow.Cli.Help, _ -> print_endline (help_text parsed.help_topic)
  | Camlflow.Cli.Completion, _ ->
      let shell =
        match parsed.completion_shell with
        | Some shell -> shell
        | None -> die "internal CLI dispatch error: missing completion shell"
      in
      print_endline (Camlflow.Cli.completion_script shell)
  | Camlflow.Cli.Parse, [ path ] -> print_parse path
  | Camlflow.Cli.Check, [ path ] -> print_check parsed.options.include_paths path
  | Camlflow.Cli.Compile, [ path ] ->
      print_compile parsed.options.include_paths parsed.options.output path
  | Camlflow.Cli.Run, [ path ] -> print_run parsed.options path
  | command, _ ->
      die
        (Printf.sprintf "internal CLI dispatch error for command %s"
           (Camlflow.Cli.command_name command))

let () =
  let argv = Array.to_list Sys.argv |> List.tl in
  let parsed = or_die (Camlflow.Cli.parse_argv argv) in
  let () = or_die (Camlflow.Cli.validate parsed) in
  dispatch parsed
