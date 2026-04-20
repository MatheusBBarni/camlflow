let ( let* ) = Result.bind

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun child -> rm_rf (Filename.concat path child));
      Unix.rmdir path)
    else Sys.remove path

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)

let ensure_dir path = if Sys.file_exists path then () else Unix.mkdir path 0o755

let write_file path content =
  Out_channel.with_open_bin path (fun channel -> output_string channel content)

let get_output_string = function
  | Some (`String value) -> value
  | Some json ->
      Alcotest.failf "expected JSON string output, got %s"
        (Yojson.Safe.to_string json)
  | None -> Alcotest.fail "expected output"

let get_output_int = function
  | Some (`Int value) -> value
  | Some json ->
      Alcotest.failf "expected JSON int output, got %s"
        (Yojson.Safe.to_string json)
  | None -> Alcotest.fail "expected output"

let get_output_float = function
  | Some (`Float value) -> value
  | Some (`Int value) -> float_of_int value
  | Some json ->
      Alcotest.failf "expected JSON float output, got %s"
        (Yojson.Safe.to_string json)
  | None -> Alcotest.fail "expected output"

let parse_program source =
  match Camlflow.Parsing.parse_string source with
  | Ok program -> program
  | Error error -> Alcotest.failf "parse failed: %s" error

let check_file ?(include_paths = []) path =
  match Camlflow.Typing.check_file ~include_paths path with
  | Ok program -> program
  | Error error -> Alcotest.failf "check failed: %s" error

let run_program ?context ?input program =
  match Camlflow.Runtime.execute ?context ?input program with
  | Ok result -> result
  | Error error -> Alcotest.failf "runtime failed: %s" error

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    if needle_len = 0 then true
    else if index + needle_len > haystack_len then false
    else if String.sub haystack index needle_len = needle then true
    else loop (index + 1)
  in
  loop 0

let expect_error_contains label needle = function
  | Ok _ -> Alcotest.failf "expected error containing %S for %s" needle label
  | Error error ->
      if not (contains_substring error needle) then
        Alcotest.failf "unexpected error for %s: %s" label error

let parse_cli argv =
  match Camlflow.Cli.parse_argv argv with
  | Ok parsed -> parsed
  | Error error -> Alcotest.failf "cli parse failed: %s" error

let load_nearest_project_config working_directory =
  match Camlflow.Project_config.load_nearest ~working_directory with
  | Ok (Some config) -> config
  | Ok None -> Alcotest.fail "expected CamlFlow config"
  | Error error -> Alcotest.failf "project config load failed: %s" error

let load_project_config_file path =
  match Camlflow.Project_config.load_file path with
  | Ok config -> config
  | Error error -> Alcotest.failf "project config load failed: %s" error

let write_project_config dir content =
  write_file (Filename.concat dir Camlflow.Project_config.filename) content

let write_rpc_messages path messages =
  Out_channel.with_open_bin path (fun channel ->
      List.iter
        (fun message ->
          match Camlflow.Rpc_stdio.write_message channel message with
          | Ok () -> ()
          | Error error -> Alcotest.failf "rpc write failed: %s" error)
        messages)

let read_rpc_messages path =
  In_channel.with_open_bin path (fun channel ->
      let rec loop acc =
        match Camlflow.Rpc_stdio.read_message channel with
        | Ok (Some message) -> loop (message :: acc)
        | Ok None -> List.rev acc
        | Error error -> Alcotest.failf "rpc read failed: %s" error
      in
      loop [])

let run_rpc_server_with_messages messages =
  with_temp_dir "camlflow-rpc-" @@ fun dir ->
  let input_path = Filename.concat dir "input.rpc" in
  let output_path = Filename.concat dir "output.rpc" in
  write_rpc_messages input_path messages;
  let input = In_channel.open_bin input_path in
  let output = Out_channel.open_bin output_path in
  Fun.protect
    ~finally:(fun () ->
      In_channel.close input;
      Out_channel.close output)
    (fun () ->
      match Camlflow.Rpc_server.run ~input ~output with
      | Ok () -> read_rpc_messages output_path
      | Error error -> Alcotest.failf "rpc server run failed: %s" error)

let run_lsp_server_with_messages messages =
  with_temp_dir "camlflow-lsp-" @@ fun dir ->
  let input_path = Filename.concat dir "input.rpc" in
  let output_path = Filename.concat dir "output.rpc" in
  write_rpc_messages input_path messages;
  let input = In_channel.open_bin input_path in
  let output = Out_channel.open_bin output_path in
  Fun.protect
    ~finally:(fun () ->
      In_channel.close input;
      Out_channel.close output)
    (fun () ->
      match Camlflow.Lsp_server.run ~input ~output with
      | Ok () -> read_rpc_messages output_path
      | Error error -> Alcotest.failf "lsp server run failed: %s" error)

let schema_for_type ?(types = Camlflow.Value.StringMap.empty) typ =
  match Camlflow.Provider_schema.of_type ~types typ with
  | Ok schema -> schema
  | Error error -> Alcotest.failf "schema generation failed: %s" error

let assoc_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let expect_assoc_field name json =
  match assoc_field name json with
  | Some value -> value
  | None ->
      Alcotest.failf "missing JSON field %s in %s" name
        (Yojson.Safe.to_string json)

let expect_string_field name expected json =
  match expect_assoc_field name json with
  | `String value -> Alcotest.(check string) name expected value
  | other ->
      Alcotest.failf "expected field %s to be a string, got %s" name
        (Yojson.Safe.to_string other)

let expect_int_field name expected json =
  match expect_assoc_field name json with
  | `Int value -> Alcotest.(check int) name expected value
  | other ->
      Alcotest.failf "expected field %s to be an int, got %s" name
        (Yojson.Safe.to_string other)

let expect_bool_field name expected json =
  match expect_assoc_field name json with
  | `Bool value -> Alcotest.(check bool) name expected value
  | other ->
      Alcotest.failf "expected field %s to be a bool, got %s" name
        (Yojson.Safe.to_string other)

let tagged tag = `Assoc [ ("tag", `String tag) ]
let tagged_value tag value = `Assoc [ ("tag", `String tag); ("value", value) ]

let repo_path path =
  let rec find dir depth =
    let candidate = Filename.concat dir path in
    if Sys.file_exists candidate || depth = 0 then candidate
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir then candidate else find parent (depth - 1)
  in
  find (Sys.getcwd ()) 6

let rpc_request_message = function
  | `Assoc fields as json when List.mem_assoc "method" fields -> (
      match Camlflow.Rpc_protocol.request_of_yojson json with
      | Ok request -> Some request
      | Error error -> Alcotest.failf "rpc request decode failed: %s" error)
  | _ -> None

let rpc_response_message = function
  | `Assoc fields as json when not (List.mem_assoc "method" fields) -> (
      match Camlflow.Rpc_protocol.response_of_yojson json with
      | Ok response -> Some response
      | Error error -> Alcotest.failf "rpc response decode failed: %s" error)
  | _ -> None

let find_rpc_requests method_ messages =
  List.filter_map
    (fun json ->
      match rpc_request_message json with
      | Some request
        when String.equal request.Camlflow.Rpc_protocol.request_method method_
        ->
          Some request
      | _ -> None)
    messages

let find_rpc_request method_ messages =
  match find_rpc_requests method_ messages with
  | request :: _ -> request
  | [] -> Alcotest.failf "rpc request %s not found" method_

let find_rpc_response_by_id expected_id messages =
  match
    List.find_opt
      (fun json ->
        match rpc_response_message json with
        | Some response -> (
            match response.Camlflow.Rpc_protocol.response_id with
            | Some id ->
                String.equal (Camlflow.Rpc_protocol.string_of_id id) expected_id
            | None -> false)
        | None -> false)
      messages
  with
  | Some json -> (
      match rpc_response_message json with
      | Some response -> response
      | None -> assert false)
  | None -> Alcotest.failf "rpc response %s not found" expected_id

let find_rpc_response_without_id messages =
  match
    List.find_opt
      (fun json ->
        match rpc_response_message json with
        | Some response ->
            Option.is_none response.Camlflow.Rpc_protocol.response_id
        | None -> false)
      messages
  with
  | Some json -> (
      match rpc_response_message json with
      | Some response -> response
      | None -> assert false)
  | None -> Alcotest.fail "rpc response without id not found"

let substring_index text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop index =
    if needle_len = 0 then 0
    else if index + needle_len > text_len then
      Alcotest.failf "substring %S not found in %S" needle text
    else if String.sub text index needle_len = needle then index
    else loop (index + 1)
  in
  loop 0

let find_type_decl program local_name =
  let rec find_in_decls = function
    | [] -> None
    | Camlflow.Ir.TypeDecl decl :: _
      when String.equal
             (List.hd (List.rev decl.Camlflow.Ir.type_name))
             local_name ->
        Some decl
    | _ :: rest -> find_in_decls rest
  in
  let rec find_in_modules = function
    | [] -> Alcotest.failf "type decl %s not found" local_name
    | module_ :: rest -> (
        match find_in_decls module_.Camlflow.Ir.module_decls with
        | Some decl -> decl
        | None -> find_in_modules rest)
  in
  find_in_modules program.Camlflow.Ir.modules

let make_invocation ?(kind = Camlflow.Runtime.Context.Bound_agent)
    ?(name = "step") ?(input = `Assoc []) ?(return_type = Camlflow.Ir.TString)
    ?(types = Camlflow.Value.StringMap.empty) ?working_directory
    ?skills_directory ?markdown ?definition () =
  {
    Camlflow.Runtime.Context.invocation_kind = kind;
    invocation_name = name;
    invocation_input = input;
    invocation_return_type = return_type;
    invocation_types = types;
    invocation_working_directory = working_directory;
    invocation_skills_directory = skills_directory;
    invocation_markdown = markdown;
    invocation_definition = definition;
  }

let render_prompt (invocation : Camlflow.Runtime.Context.invocation) =
  let output_schema =
    schema_for_type ~types:invocation.invocation_types
      invocation.invocation_return_type
  in
  match Camlflow.Provider_prompt.render ~invocation ~output_schema with
  | Ok rendered -> rendered
  | Error error -> Alcotest.failf "prompt rendering failed: %s" error

let build_effect_request ?step_index ?run_id
    (invocation : Camlflow.Runtime.Context.invocation) =
  match
    Camlflow.Effect_request.of_invocation ?step_index ?run_id invocation
  with
  | Ok request -> request
  | Error error -> Alcotest.failf "effect request failed: %s" error

let run_effect_bridge ?step_index ?run_id ~executor
    (invocation : Camlflow.Runtime.Context.invocation) =
  match
    Camlflow.Effect_bridge.execute ?step_index ?run_id ~executor invocation
  with
  | Ok execution -> execution
  | Error error -> Alcotest.failf "effect bridge failed: %s" error

let test_parse_source () =
  let source =
    {|
type req = { prompt : string }
skill caveman : prompt:string -> string = Skill.bind "caveman"
let main = "ok"
|}
  in
  let program = parse_program source in
  Alcotest.(check int) "module count" 1 (List.length program.modules);
  let module_ = List.hd program.modules in
  Alcotest.(check int) "decl count" 3 (List.length module_.module_decls)

let test_multiline_quoted_strings_preserve_agent_skill_text () =
  with_temp_dir "camlflow-quoted-string-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main "let main : string = {|\nagent hello\nskill bye\n|}\n";
  let program = check_file main in
  let result = run_program program in
  Alcotest.(check string)
    "quoted string preserved" "\nagent hello\nskill bye\n"
    (get_output_string result.output)

let test_return_annotated_function_without_param_annotations_fails_cleanly () =
  with_temp_dir "camlflow-return-annotation-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main {|
let identity x : int = x
|};
  expect_error_contains "return annotation without parameter annotations"
    "function parameters require type annotations when using a return type \
     annotation"
    (Camlflow.Typing.check_file ~include_paths:[] main)

let test_cli_help_alias () =
  let parsed = parse_cli [ "parse"; "--help" ] in
  Alcotest.(check string)
    "help command" "help"
    (Camlflow.Cli.command_name parsed.command);
  Alcotest.(check string)
    "help topic" "parse"
    (match parsed.help_topic with
    | Some command -> Camlflow.Cli.command_name command
    | None -> "none")

let test_cli_help_subcommand () =
  let parsed = parse_cli [ "help"; "run" ] in
  Alcotest.(check string)
    "help subcommand" "run"
    (match parsed.help_topic with
    | Some command -> Camlflow.Cli.command_name command
    | None -> "none")

let test_cli_missing_flag_value () =
  expect_error_contains "missing -o" "missing value for flag -o"
    (Camlflow.Cli.parse_argv [ "compile"; "-o" ])

let test_cli_run_rejects_conflicting_inputs () =
  let parsed =
    parse_cli
      [ "run"; "main.cml"; "--input"; "input.json"; "--input-json"; "{}" ]
  in
  expect_error_contains "conflicting run inputs"
    "either --input or --input-json"
    (Camlflow.Cli.validate parsed)

let test_cli_check_rejects_run_flags () =
  let parsed = parse_cli [ "check"; "main.cml"; "--skills"; "skills" ] in
  expect_error_contains "check rejects run flags" "does not accept"
    (Camlflow.Cli.validate parsed)

let test_cli_completion_command () =
  let parsed = parse_cli [ "completion"; "bash" ] in
  Alcotest.(check string)
    "completion command" "completion"
    (Camlflow.Cli.command_name parsed.command);
  Alcotest.(check string)
    "completion shell" "bash"
    (match parsed.completion_shell with
    | Some shell -> Camlflow.Cli.shell_name shell
    | None -> "none");
  match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error -> Alcotest.failf "completion validate failed: %s" error

let test_cli_completion_script_mentions_commands () =
  let script = Camlflow.Cli.completion_script Camlflow.Cli.Bash in
  if
    not
      (contains_substring script "parse check compile run serve lsp completion")
  then Alcotest.failf "unexpected completion script: %s" script;
  if not (contains_substring script "--provider --model --reasoning") then
    Alcotest.failf "provider flags missing from completion script: %s" script;
  if
    not
      (contains_substring script
         (String.concat " " Camlflow.Provider.available_provider_names))
  then Alcotest.failf "provider completions missing adapter names: %s" script;
  if not (contains_substring script "--stdio") then
    Alcotest.failf "serve flags missing from completion script: %s" script

let test_cli_serve_stdio_parse () =
  let parsed = parse_cli [ "serve"; "--stdio" ] in
  Alcotest.(check string)
    "serve command" "serve"
    (Camlflow.Cli.command_name parsed.command);
  Alcotest.(check bool) "serve stdio flag" true parsed.options.rpc_stdio;
  match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error -> Alcotest.failf "serve validate failed: %s" error

let test_cli_serve_requires_stdio () =
  let parsed = parse_cli [ "serve" ] in
  expect_error_contains "serve requires stdio" "serve requires flag --stdio"
    (Camlflow.Cli.validate parsed)

let test_cli_run_provider_flags_parse () =
  let parsed =
    parse_cli
      [
        "run";
        "main.cml";
        "--provider";
        "codex";
        "--model";
        "gpt-5.4-mini";
        "--reasoning";
        "high";
        "--provider-profile";
        "daily";
        "--provider-config";
        "foo=bar";
        "--sandbox";
        "read-only";
        "--allow-write-dir";
        "tmp";
        "--trace-provider";
      ]
  in
  (match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error -> Alcotest.failf "run validate failed: %s" error);
  let settings = parsed.options.provider_options in
  Alcotest.(check string)
    "provider" "codex"
    (match settings.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none");
  Alcotest.(check string)
    "model" "gpt-5.4-mini"
    (match settings.model with Some model -> model | None -> "none");
  Alcotest.(check string)
    "reasoning" "high"
    (match settings.reasoning with
    | Some reasoning -> Camlflow.Provider.reasoning_to_string reasoning
    | None -> "none");
  Alcotest.(check string)
    "provider profile" "daily"
    (match settings.provider_profile with
    | Some profile -> profile
    | None -> "none");
  Alcotest.(check string)
    "provider config" "foo=bar"
    (match settings.provider_configs with
    | [ config ] -> Camlflow.Provider.config_to_string config
    | _ -> "unexpected");
  Alcotest.(check string)
    "sandbox" "read-only"
    (Camlflow.Provider.sandbox_to_string settings.sandbox);
  Alcotest.(check (list string))
    "write dirs" [ "tmp" ] settings.allow_write_dirs;
  Alcotest.(check bool) "trace provider" true settings.trace_provider

let test_cli_run_opencode_provider_parse () =
  let parsed =
    parse_cli
      [
        "run";
        "main.cml";
        "--provider";
        "opencode";
        "--model";
        "openai/gpt-5.4-mini";
        "--reasoning";
        "low";
      ]
  in
  (match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error -> Alcotest.failf "run validate failed: %s" error);
  let settings = parsed.options.provider_options in
  Alcotest.(check string)
    "provider" "opencode"
    (match settings.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none");
  Alcotest.(check string)
    "model" "openai/gpt-5.4-mini"
    (match settings.model with Some model -> model | None -> "none")

let test_cli_run_claude_code_provider_parse () =
  let parsed =
    parse_cli
      [
        "run";
        "main.cml";
        "--provider";
        "claude-code";
        "--model";
        "sonnet";
        "--reasoning";
        "medium";
        "--allow-write-dir";
        "tmp";
      ]
  in
  (match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error -> Alcotest.failf "run validate failed: %s" error);
  let settings = parsed.options.provider_options in
  Alcotest.(check string)
    "provider" "claude-code"
    (match settings.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none");
  Alcotest.(check string)
    "model" "sonnet"
    (match settings.model with Some model -> model | None -> "none");
  Alcotest.(check string)
    "reasoning" "medium"
    (match settings.reasoning with
    | Some reasoning -> Camlflow.Provider.reasoning_to_string reasoning
    | None -> "none");
  Alcotest.(check (list string))
    "write dirs" [ "tmp" ] settings.allow_write_dirs

let test_cli_run_claude_cli_provider_parse () =
  let parsed =
    parse_cli
      [
        "run";
        "main.cml";
        "--provider";
        "claude-cli";
        "--model";
        "claude-sonnet-4-6";
        "--reasoning";
        "max";
      ]
  in
  (match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error -> Alcotest.failf "run validate failed: %s" error);
  let settings = parsed.options.provider_options in
  Alcotest.(check string)
    "provider" "claude-cli"
    (match settings.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none");
  Alcotest.(check string)
    "model" "claude-sonnet-4-6"
    (match settings.model with Some model -> model | None -> "none");
  Alcotest.(check string)
    "reasoning" "max"
    (match settings.reasoning with
    | Some reasoning -> Camlflow.Provider.reasoning_to_string reasoning
    | None -> "none")

let test_cli_provider_flags_require_provider () =
  let parsed = parse_cli [ "run"; "main.cml"; "--model"; "gpt-5.4-mini" ] in
  expect_error_contains "provider required" "run requires --provider"
    (Camlflow.Cli.validate parsed)

let test_cli_unknown_provider_rejected () =
  expect_error_contains "unknown provider" "unknown provider unknown"
    (Camlflow.Cli.parse_argv [ "run"; "main.cml"; "--provider"; "unknown" ])

let test_cli_invalid_provider_config_rejected () =
  expect_error_contains "invalid provider config"
    "provider config must have the form key=value"
    (Camlflow.Cli.parse_argv [ "run"; "main.cml"; "--provider-config"; "oops" ])

let test_cli_check_rejects_provider_flags () =
  let parsed = parse_cli [ "check"; "main.cml"; "--provider"; "codex" ] in
  expect_error_contains "check rejects provider flags" "flag --provider"
    (Camlflow.Cli.validate parsed)

let test_project_config_loads_nearest_and_resolves_paths () =
  with_temp_dir "camlflow-config-" @@ fun dir ->
  let nested = Filename.concat dir "nested" in
  let deep = Filename.concat nested "deep" in
  ensure_dir nested;
  ensure_dir deep;
  write_project_config dir
    {|
{
  "program": "flows/main.cml",
  "entry": "workflow",
  "includePaths": [".", "lib"],
  "skillsDir": "skills",
  "provider": "codex",
  "model": "gpt-5.4-mini",
  "reasoning": "low",
  "providerProfile": "daily",
  "providerConfig": {
    "foo": "bar"
  },
  "sandbox": "read-only",
  "allowWriteDirs": ["tmp"],
  "traceProvider": true
}
|};
  let config = load_nearest_project_config deep in
  Alcotest.(check (option string))
    "program"
    (Some (Filename.concat dir "flows/main.cml"))
    config.Camlflow.Project_config.program;
  Alcotest.(check (option string)) "entry" (Some "workflow") config.entry;
  Alcotest.(check (option (list string)))
    "include paths"
    (Some [ dir; Filename.concat dir "lib" ])
    config.include_paths;
  Alcotest.(check (option string))
    "skills dir"
    (Some (Filename.concat dir "skills"))
    config.skills_dir;
  Alcotest.(check string)
    "provider" "codex"
    (match config.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none");
  Alcotest.(check (option string)) "model" (Some "gpt-5.4-mini") config.model;
  Alcotest.(check string)
    "reasoning" "low"
    (match config.reasoning with
    | Some reasoning -> Camlflow.Provider.reasoning_to_string reasoning
    | None -> "none");
  Alcotest.(check (option string))
    "provider profile" (Some "daily") config.provider_profile;
  Alcotest.(check (option string))
    "provider config" (Some "foo=bar")
    (match config.provider_configs with
    | Some [ item ] -> Some (Camlflow.Provider.config_to_string item)
    | _ -> None);
  Alcotest.(check string)
    "sandbox" "read-only"
    (match config.sandbox with
    | Some sandbox -> Camlflow.Provider.sandbox_to_string sandbox
    | None -> "none");
  Alcotest.(check (option (list string)))
    "allow write dirs"
    (Some [ Filename.concat dir "tmp" ])
    config.allow_write_dirs;
  Alcotest.(check (option bool))
    "trace provider" (Some true) config.trace_provider

let test_project_config_load_file_normalizes_relative_and_absolute_paths () =
  with_temp_dir "camlflow-config-load-file-" @@ fun dir ->
  let config_path = Filename.concat dir Camlflow.Project_config.filename in
  let absolute_program = Filename.concat dir "main.cml" in
  let absolute_include = "/opt/camlflow/lib" in
  let absolute_skills = "/srv/camlflow/skills" in
  let absolute_output = "/var/tmp/camlflow-out" in
  write_project_config dir
    (Printf.sprintf
       {|
{
  "program": %S,
  "includePaths": ["relative-lib", %S],
  "skillsDir": %S,
  "allowWriteDirs": ["relative-out", %S]
}
|}
       absolute_program absolute_include absolute_skills absolute_output);
  let config = load_project_config_file config_path in
  Alcotest.(check (option string))
    "absolute program preserved" (Some absolute_program) config.program;
  Alcotest.(check (option (list string)))
    "include paths normalized"
    (Some [ Filename.concat dir "relative-lib"; absolute_include ])
    config.include_paths;
  Alcotest.(check (option string))
    "absolute skills preserved" (Some absolute_skills) config.skills_dir;
  Alcotest.(check (option (list string)))
    "allow write dirs normalized"
    (Some [ Filename.concat dir "relative-out"; absolute_output ])
    config.allow_write_dirs

let test_project_config_invalid_enum_includes_path_and_field () =
  with_temp_dir "camlflow-config-invalid-enum-" @@ fun dir ->
  let config_path = Filename.concat dir Camlflow.Project_config.filename in
  write_project_config dir {|
{
  "provider": "bogus"
}
|};
  let result = Camlflow.Project_config.load_file config_path in
  expect_error_contains "invalid enum includes path" config_path result;
  expect_error_contains "invalid enum includes field" "invalid field provider"
    result;
  expect_error_contains "invalid enum includes reason" "unknown provider bogus"
    result

let test_project_config_wrong_shape_includes_path_and_field () =
  with_temp_dir "camlflow-config-wrong-shape-" @@ fun dir ->
  let config_path = Filename.concat dir Camlflow.Project_config.filename in
  write_project_config dir {|
{
  "providerConfig": {
    "foo": 1
  }
}
|};
  let result = Camlflow.Project_config.load_file config_path in
  expect_error_contains "wrong shape includes path" config_path result;
  expect_error_contains "wrong shape includes nested field"
    "invalid field providerConfig.foo" result;
  expect_error_contains "wrong shape includes reason" "expected string" result

let test_project_config_invalid_provider_config_key_rejected () =
  with_temp_dir "camlflow-config-provider-key-" @@ fun dir ->
  let config_path = Filename.concat dir Camlflow.Project_config.filename in
  write_project_config dir {|
{
  "providerConfig": {
    "": "x"
  }
}
|};
  let result = Camlflow.Project_config.load_file config_path in
  expect_error_contains "provider config key includes path" config_path result;
  expect_error_contains "provider config key includes field"
    "invalid field providerConfig" result;
  expect_error_contains "provider config key includes reason"
    "provider config key cannot be empty" result

let test_project_config_bad_path_value_includes_path_and_field () =
  with_temp_dir "camlflow-config-bad-path-" @@ fun dir ->
  let config_path = Filename.concat dir Camlflow.Project_config.filename in
  write_project_config dir {|
{
  "allowWriteDirs": [""]
}
|};
  let result = Camlflow.Project_config.load_file config_path in
  expect_error_contains "bad path includes path" config_path result;
  expect_error_contains "bad path includes indexed field"
    "invalid field allowWriteDirs[0]" result;
  expect_error_contains "bad path includes reason" "expected non-empty path"
    result

let test_project_config_unknown_field_rejected () =
  with_temp_dir "camlflow-config-unknown-field-" @@ fun dir ->
  let config_path = Filename.concat dir Camlflow.Project_config.filename in
  write_project_config dir {|
{
  "includePath": ["lib"]
}
|};
  let result = Camlflow.Project_config.load_file config_path in
  expect_error_contains "unknown field includes path" config_path result;
  expect_error_contains "unknown field includes field"
    "invalid field includePath" result;
  expect_error_contains "unknown field includes reason" "unknown field" result

let sample_project_config ?program ?entry ?include_paths ?skills_dir ?provider
    ?model ?reasoning ?provider_profile ?provider_configs ?sandbox
    ?allow_write_dirs ?trace_provider () =
  {
    Camlflow.Project_config.path = "/tmp/camlflow.json";
    directory = "/tmp";
    program;
    entry;
    include_paths;
    skills_dir;
    provider;
    model;
    reasoning;
    provider_profile;
    provider_configs;
    sandbox;
    allow_write_dirs;
    trace_provider;
  }

let test_cli_run_uses_project_config_defaults () =
  let parsed = parse_cli [ "run" ] in
  let config =
    sample_project_config ~program:"/tmp/workflow.cml" ~entry:"workflow"
      ~include_paths:[ "/tmp/lib" ] ~skills_dir:"/tmp/skills"
      ~provider:Camlflow.Provider.Codex ~model:"gpt-5.4-mini"
      ~reasoning:Camlflow.Provider.Low ~provider_profile:"daily"
      ~provider_configs:[ { Camlflow.Provider.key = "foo"; value = "bar" } ]
      ~sandbox:Camlflow.Provider.Read_only ~allow_write_dirs:[ "/tmp/out" ]
      ~trace_provider:true ()
  in
  let parsed = Camlflow.Cli.apply_project_config parsed config in
  (match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error -> Alcotest.failf "run validate with config failed: %s" error);
  Alcotest.(check (list string))
    "config program applied" [ "/tmp/workflow.cml" ] parsed.positionals;
  Alcotest.(check string) "config entry applied" "workflow" parsed.options.entry;
  Alcotest.(check (list string))
    "config include paths applied" [ "/tmp/lib" ] parsed.options.include_paths;
  Alcotest.(check (option string))
    "config skills dir applied" (Some "/tmp/skills") parsed.options.skills_dir;
  Alcotest.(check string)
    "config provider applied" "codex"
    (match parsed.options.provider_options.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none");
  Alcotest.(check (option string))
    "config model applied" (Some "gpt-5.4-mini")
    parsed.options.provider_options.model;
  Alcotest.(check string)
    "config reasoning applied" "low"
    (match parsed.options.provider_options.reasoning with
    | Some reasoning -> Camlflow.Provider.reasoning_to_string reasoning
    | None -> "none");
  Alcotest.(check (option string))
    "config provider profile applied" (Some "daily")
    parsed.options.provider_options.provider_profile;
  Alcotest.(check (list string))
    "config allow write dirs applied" [ "/tmp/out" ]
    parsed.options.provider_options.allow_write_dirs;
  Alcotest.(check bool)
    "config trace provider applied" true
    parsed.options.provider_options.trace_provider

let test_cli_explicit_run_flags_override_project_config () =
  let parsed =
    parse_cli
      [
        "run";
        "cli.cml";
        "--entry";
        "main";
        "--skills";
        "cli-skills";
        "--provider";
        "opencode";
        "--model";
        "openai/gpt-5.4-mini";
        "--reasoning";
        "high";
        "--provider-profile";
        "cli-profile";
        "--provider-config";
        "alpha=beta";
        "--sandbox";
        "danger-full-access";
        "--allow-write-dir";
        "cli-out";
        "--trace-provider";
      ]
  in
  let config =
    sample_project_config ~program:"/tmp/workflow.cml" ~entry:"workflow"
      ~skills_dir:"/tmp/skills" ~provider:Camlflow.Provider.Codex
      ~model:"gpt-5.4-mini" ~reasoning:Camlflow.Provider.Low
      ~provider_profile:"daily"
      ~provider_configs:[ { Camlflow.Provider.key = "foo"; value = "bar" } ]
      ~sandbox:Camlflow.Provider.Read_only ~allow_write_dirs:[ "/tmp/out" ]
      ~trace_provider:false ()
  in
  let parsed = Camlflow.Cli.apply_project_config parsed config in
  Alcotest.(check (list string))
    "cli program preserved" [ "cli.cml" ] parsed.positionals;
  Alcotest.(check string) "cli entry preserved" "main" parsed.options.entry;
  Alcotest.(check (option string))
    "cli skills preserved" (Some "cli-skills") parsed.options.skills_dir;
  Alcotest.(check string)
    "cli provider preserved" "opencode"
    (match parsed.options.provider_options.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none");
  Alcotest.(check (option string))
    "cli model preserved" (Some "openai/gpt-5.4-mini")
    parsed.options.provider_options.model;
  Alcotest.(check string)
    "cli reasoning preserved" "high"
    (match parsed.options.provider_options.reasoning with
    | Some reasoning -> Camlflow.Provider.reasoning_to_string reasoning
    | None -> "none");
  Alcotest.(check (option string))
    "cli provider profile preserved" (Some "cli-profile")
    parsed.options.provider_options.provider_profile;
  Alcotest.(check (option string))
    "cli provider config preserved" (Some "alpha=beta")
    (match parsed.options.provider_options.provider_configs with
    | [ item ] -> Some (Camlflow.Provider.config_to_string item)
    | _ -> None);
  Alcotest.(check string)
    "cli sandbox preserved" "danger-full-access"
    (Camlflow.Provider.sandbox_to_string parsed.options.provider_options.sandbox);
  Alcotest.(check (list string))
    "cli allow write dirs preserved" [ "cli-out" ]
    parsed.options.provider_options.allow_write_dirs;
  Alcotest.(check bool)
    "cli trace provider preserved" true
    parsed.options.provider_options.trace_provider

let test_cli_project_config_precedence_cli_config_defaults () =
  let parsed =
    parse_cli [ "run"; "--provider"; "opencode"; "--entry"; "cli-entry" ]
  in
  let config =
    sample_project_config ~program:"/tmp/workflow.cml" ~entry:"config-entry"
      ~include_paths:[ "/tmp/lib" ] ~provider:Camlflow.Provider.Codex
      ~model:"gpt-5.4-mini" ~reasoning:Camlflow.Provider.Low ()
  in
  let parsed = Camlflow.Cli.apply_project_config parsed config in
  (match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error ->
      Alcotest.failf "run validate with precedence failed: %s" error);
  Alcotest.(check (list string))
    "config program fills missing positional" [ "/tmp/workflow.cml" ]
    parsed.positionals;
  Alcotest.(check string) "cli entry wins" "cli-entry" parsed.options.entry;
  Alcotest.(check (list string))
    "config include paths win over defaults" [ "/tmp/lib" ]
    parsed.options.include_paths;
  Alcotest.(check string)
    "cli provider wins" "opencode"
    (match parsed.options.provider_options.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none");
  Alcotest.(check (option string))
    "config model wins over default" (Some "gpt-5.4-mini")
    parsed.options.provider_options.model;
  Alcotest.(check string)
    "config reasoning wins over default" "low"
    (match parsed.options.provider_options.reasoning with
    | Some reasoning -> Camlflow.Provider.reasoning_to_string reasoning
    | None -> "none");
  Alcotest.(check string)
    "default sandbox remains" "workspace-write"
    (Camlflow.Provider.sandbox_to_string parsed.options.provider_options.sandbox);
  Alcotest.(check bool)
    "default trace provider remains false" false
    parsed.options.provider_options.trace_provider

let test_cli_explicit_program_overrides_project_config_program () =
  let parsed = parse_cli [ "compile"; "cli.cml" ] in
  let config =
    sample_project_config ~program:"/tmp/workflow.cml"
      ~include_paths:[ "/tmp/lib" ] ()
  in
  let parsed = Camlflow.Cli.apply_project_config parsed config in
  (match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error ->
      Alcotest.failf "compile validate with explicit program failed: %s" error);
  Alcotest.(check (list string))
    "explicit positional preserved" [ "cli.cml" ] parsed.positionals;
  Alcotest.(check (list string))
    "config include paths still applied" [ "/tmp/lib" ]
    parsed.options.include_paths

let test_cli_explicit_provider_setting_overrides_project_config_setting () =
  let parsed =
    parse_cli [ "run"; "--provider"; "codex"; "--model"; "cli-model" ]
  in
  let config =
    sample_project_config ~program:"/tmp/workflow.cml" ~model:"config-model"
      ~reasoning:Camlflow.Provider.Low ~provider_profile:"daily"
      ~sandbox:Camlflow.Provider.Read_only ~trace_provider:true ()
  in
  let parsed = Camlflow.Cli.apply_project_config parsed config in
  (match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error ->
      Alcotest.failf "run validate with provider override failed: %s" error);
  Alcotest.(check (option string))
    "cli model preserved" (Some "cli-model")
    parsed.options.provider_options.model;
  Alcotest.(check string)
    "config reasoning still applied" "low"
    (match parsed.options.provider_options.reasoning with
    | Some reasoning -> Camlflow.Provider.reasoning_to_string reasoning
    | None -> "none");
  Alcotest.(check (option string))
    "config provider profile still applied" (Some "daily")
    parsed.options.provider_options.provider_profile;
  Alcotest.(check string)
    "config sandbox still applied" "read-only"
    (Camlflow.Provider.sandbox_to_string parsed.options.provider_options.sandbox);
  Alcotest.(check bool)
    "config trace provider still applied" true
    parsed.options.provider_options.trace_provider

let test_cli_project_config_keeps_run_input_validation () =
  let parsed =
    parse_cli
      [
        "run";
        "--provider";
        "codex";
        "--input";
        "input.json";
        "--input-json";
        "{}";
      ]
  in
  let config = sample_project_config ~program:"/tmp/workflow.cml" () in
  let parsed = Camlflow.Cli.apply_project_config parsed config in
  expect_error_contains "config-backed run input validation"
    "either --input or --input-json"
    (Camlflow.Cli.validate parsed)

let test_cli_check_uses_project_program_without_run_only_defaults () =
  let parsed = parse_cli [ "check" ] in
  let config =
    sample_project_config ~program:"/tmp/workflow.cml" ~entry:"workflow"
      ~include_paths:[ "/tmp/lib" ] ~skills_dir:"/tmp/skills"
      ~provider:Camlflow.Provider.Codex ~model:"gpt-5.4-mini"
      ~reasoning:Camlflow.Provider.Low ~trace_provider:true ()
  in
  let parsed = Camlflow.Cli.apply_project_config parsed config in
  (match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error -> Alcotest.failf "check validate with config failed: %s" error);
  Alcotest.(check (list string))
    "check config program applied" [ "/tmp/workflow.cml" ] parsed.positionals;
  Alcotest.(check (list string))
    "check include paths applied" [ "/tmp/lib" ] parsed.options.include_paths;
  Alcotest.(check string) "check entry unchanged" "main" parsed.options.entry;
  Alcotest.(check (option string))
    "check skills ignored" None parsed.options.skills_dir;
  Alcotest.(check string)
    "check provider ignored" "none"
    (match parsed.options.provider_options.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none")

let test_rpc_protocol_request_roundtrip () =
  let json =
    Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.String "1")
      ~params:(`Assoc [ ("x", `Int 1) ])
      "camlflow/check"
  in
  match Camlflow.Rpc_protocol.request_of_yojson json with
  | Ok request ->
      Alcotest.(check string)
        "rpc method" "camlflow/check"
        request.Camlflow.Rpc_protocol.request_method;
      Alcotest.(check string)
        "rpc id" "1"
        (match request.request_id with
        | Some id -> Camlflow.Rpc_protocol.string_of_id id
        | None -> "none")
  | Error error -> Alcotest.failf "rpc request parse failed: %s" error

let test_rpc_protocol_notification_includes_params () =
  let json =
    Camlflow.Rpc_protocol.request
      ~params:(`Assoc [ ("event", `String "run-start") ])
      "camlflow/trace"
  in
  match Camlflow.Rpc_protocol.request_of_yojson json with
  | Ok request ->
      Alcotest.(check string)
        "rpc notification method" "camlflow/trace"
        request.Camlflow.Rpc_protocol.request_method;
      Alcotest.(check bool)
        "rpc notification params present" true
        (Option.is_some request.request_params)
  | Error error -> Alcotest.failf "rpc notification parse failed: %s" error

let test_rpc_stdio_parse_content_length () =
  match
    Camlflow.Rpc_stdio.parse_content_length
      [
        "Content-Type: application/vscode-jsonrpc; charset=utf-8";
        "Content-Length: 17";
      ]
  with
  | Ok length -> Alcotest.(check int) "content length" 17 length
  | Error error -> Alcotest.failf "content length parse failed: %s" error

let test_rpc_server_run_request_parse () =
  let json =
    `Assoc
      [
        ( "program",
          `Assoc
            [
              ("path", `String "examples/basic/main.cml");
              ("includePaths", `List [ `String "lib" ]);
              ("skillsDir", `String "skills");
            ] );
        ("entry", `String "main");
        ("input", `String "Ada");
      ]
  in
  match Camlflow.Rpc_server.run_request_of_yojson json with
  | Ok request ->
      Alcotest.(check string)
        "run path" "examples/basic/main.cml"
        request.Camlflow.Rpc_server.run_program.program_path;
      Alcotest.(check (list string))
        "run include paths" [ "lib" ] request.run_program.program_include_paths;
      Alcotest.(check (option string))
        "run skills dir" (Some "skills") request.run_program.program_skills_dir;
      Alcotest.(check string) "run entry" "main" request.run_entry;
      Alcotest.(check bool)
        "run input present" true
        (Option.is_some request.run_input)
  | Error error -> Alcotest.failf "run request parse failed: %s" error

let test_ir_program_json_includes_version () =
  with_temp_dir "camlflow-ir-version-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main "let main : string = \"ok\"\n";
  let program = check_file main in
  let json = Camlflow.Ir.program_to_yojson program in
  expect_string_field "version" Camlflow.Ir.ir_version json;
  let serialized = Camlflow.Ir.to_json_string program in
  match Camlflow.Ir.of_json_string serialized with
  | Ok _ -> ()
  | Error error -> Alcotest.failf "IR roundtrip with version failed: %s" error

let test_rpc_server_initialize_advertises_trace () =
  let json = Camlflow.Rpc_server.initialized_result () in
  expect_string_field "protocolVersion" "0.1.0" json;
  expect_string_field "irVersion" Camlflow.Ir.ir_version json;
  match expect_assoc_field "capabilities" json with
  | `Assoc fields -> (
      (match List.assoc_opt "trace" fields with
      | Some (`Bool true) -> ()
      | other ->
          Alcotest.failf "expected trace capability, got %s"
            (match other with
            | Some json -> Yojson.Safe.to_string json
            | None -> "null"));
      (match List.assoc_opt "diagnostic" fields with
      | Some (`Bool true) -> ()
      | other ->
          Alcotest.failf "expected diagnostic capability, got %s"
            (match other with
            | Some json -> Yojson.Safe.to_string json
            | None -> "null"));
      (match List.assoc_opt "progress" fields with
      | Some (`Bool true) -> ()
      | other ->
          Alcotest.failf "expected progress capability, got %s"
            (match other with
            | Some json -> Yojson.Safe.to_string json
            | None -> "null"));
      (match List.assoc_opt "streaming" fields with
      | Some (`Bool true) -> ()
      | other ->
          Alcotest.failf "expected streaming capability, got %s"
            (match other with
            | Some json -> Yojson.Safe.to_string json
            | None -> "null"));
      match List.assoc_opt "cancelRequest" fields with
      | Some (`Bool true) -> ()
      | other ->
          Alcotest.failf "expected cancelRequest capability, got %s"
            (match other with
            | Some json -> Yojson.Safe.to_string json
            | None -> "null"))
  | other ->
      Alcotest.failf "expected capabilities object, got %s"
        (Yojson.Safe.to_string other)

let test_rpc_server_diagnostic_payload () =
  let request =
    build_effect_request ~step_index:2 ~run_id:"run-1"
      (make_invocation ~name:"greeter" ())
  in
  let json =
    Camlflow.Rpc_server.diagnostic_payload ~run_id:"run-1" ~step:2
      ~method_:"camlflow/run" ~request "boom"
  in
  expect_string_field "severity" "error" json;
  expect_string_field "message" "boom" json;
  expect_string_field "method" "camlflow/run" json;
  match expect_assoc_field "effect" json with
  | `Assoc fields -> (
      match List.assoc_opt "name" fields with
      | Some (`String name) ->
          Alcotest.(check string) "diagnostic effect name" "greeter" name
      | _ -> Alcotest.fail "missing diagnostic effect name")
  | other ->
      Alcotest.failf "expected effect object, got %s"
        (Yojson.Safe.to_string other)

let test_rpc_server_progress_payload () =
  let json =
    Camlflow.Rpc_server.progress_payload ~run_id:"run-1" ~step:2
      ~message:"Executing bound-agent greeter" ~completed_steps:1 ~known_steps:3
      ~cancellable:true "effect-start"
  in
  expect_string_field "runId" "run-1" json;
  expect_string_field "stage" "effect-start" json;
  expect_int_field "step" 2 json;
  expect_string_field "message" "Executing bound-agent greeter" json;
  expect_int_field "completedSteps" 1 json;
  expect_int_field "knownSteps" 3 json;
  expect_bool_field "cancellable" true json

let test_rpc_server_output_chunk_payload () =
  let json =
    Camlflow.Rpc_server.output_chunk_payload ~run_id:"run-1" ~step:2
      ~stream_id:"stream-1" ~format:"text" ~delta:(`String "hello") ~done_:false
      ()
  in
  expect_string_field "runId" "run-1" json;
  expect_int_field "step" 2 json;
  expect_string_field "streamId" "stream-1" json;
  expect_string_field "format" "text" json;
  expect_string_field "delta" "hello" json;
  expect_bool_field "done" false json

let test_rpc_server_trace_payload () =
  let request =
    build_effect_request ~step_index:2 ~run_id:"run-1"
      (make_invocation ~name:"greeter" ())
  in
  let json =
    Camlflow.Rpc_server.trace_payload ~run_id:"run-1" ~step:2 ~request
      ~details:(`Assoc [ ("status", `String "ok") ])
      "effect-result"
  in
  expect_string_field "event" "effect-result" json;
  match expect_assoc_field "effect" json with
  | `Assoc fields -> (
      (match List.assoc_opt "kind" fields with
      | Some (`String kind) ->
          Alcotest.(check string) "trace kind" "bound-agent" kind
      | _ -> Alcotest.fail "missing trace effect kind");
      match List.assoc_opt "name" fields with
      | Some (`String name) ->
          Alcotest.(check string) "trace name" "greeter" name
      | _ -> Alcotest.fail "missing trace effect name")
  | other ->
      Alcotest.failf "expected effect object, got %s"
        (Yojson.Safe.to_string other)

let test_rpc_server_end_to_end_run () =
  with_temp_dir "camlflow-rpc-e2e-" @@ fun dir ->
  let skills_dir = Filename.concat dir "skills" in
  let caveman_dir = Filename.concat skills_dir "caveman" in
  Unix.mkdir skills_dir 0o755;
  Unix.mkdir caveman_dir 0o755;
  write_file
    (Filename.concat caveman_dir "SKILL.md")
    "# Caveman\n\nReply tersely.\n";
  let workflow_path = Filename.concat dir "workflow.cml" in
  write_file workflow_path
    {|
skill caveman : prompt:string -> string = Skill.bind "caveman"
agent greeter : name:string -> string = Agent.bind "greeter"
agent reviewer : code:string -> string =
  Agent.define ~system_prompt:"Review tersely"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  let* short = caveman ~prompt:greeting in
  let* review = reviewer ~code:short in
  review
|};
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        ~params:(`Assoc []) "initialize";
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
        ~params:
          (`Assoc
             [
               ( "program",
                 `Assoc
                   [
                     ("path", `String workflow_path);
                     ("includePaths", `List []);
                     ("skillsDir", `String skills_dir);
                   ] );
               ("entry", `String "main");
               ("input", `String "Ada");
             ])
        "camlflow/run";
      Camlflow.Rpc_protocol.success (Camlflow.Rpc_protocol.String "effect-1")
        (`Assoc [ ("output", `String "hello Ada") ]);
      Camlflow.Rpc_protocol.success (Camlflow.Rpc_protocol.String "effect-2")
        (`Assoc [ ("output", `String "small") ]);
      Camlflow.Rpc_protocol.success (Camlflow.Rpc_protocol.String "effect-3")
        (`Assoc [ ("output", `String "done") ]);
    ]
  in
  let output = run_rpc_server_with_messages messages in
  let initialize_response = find_rpc_response_by_id "1" output in
  (match initialize_response.Camlflow.Rpc_protocol.response_result with
  | Some json -> expect_string_field "protocolVersion" "0.1.0" json
  | None -> Alcotest.fail "missing initialize result");
  let run_response = find_rpc_response_by_id "2" output in
  (match run_response.Camlflow.Rpc_protocol.response_result with
  | Some json ->
      (match expect_assoc_field "stepsRun" json with
      | `Int steps -> Alcotest.(check int) "steps run" 3 steps
      | other ->
          Alcotest.failf "expected int stepsRun, got %s"
            (Yojson.Safe.to_string other));
      expect_string_field "output" "done" json
  | None -> Alcotest.fail "missing run result");
  let effect_requests =
    List.filter_map
      (fun json ->
        match rpc_request_message json with
        | Some request
          when String.equal request.Camlflow.Rpc_protocol.request_method
                 "camlflow/executeEffect" ->
            Some request
        | _ -> None)
      output
  in
  Alcotest.(check int) "effect request count" 3 (List.length effect_requests);
  let trace_request = find_rpc_request "camlflow/trace" output in
  Alcotest.(check bool)
    "trace params present" true
    (Option.is_some trace_request.Camlflow.Rpc_protocol.request_params)

let test_rpc_server_end_to_end_progress_notifications () =
  with_temp_dir "camlflow-rpc-progress-" @@ fun dir ->
  let workflow = Filename.concat dir "workflow.cml" in
  write_file workflow
    {|
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting
|};
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        ~params:(`Assoc []) "initialize";
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
        ~params:
          (`Assoc
             [
               ( "program",
                 `Assoc
                   [
                     ("path", `String workflow);
                     ("includePaths", `List []);
                     ("skillsDir", `Null);
                   ] );
               ("entry", `String "main");
               ("input", `String "Ada");
             ])
        "camlflow/run";
      Camlflow.Rpc_protocol.success (Camlflow.Rpc_protocol.String "effect-1")
        (`Assoc [ ("output", `String "hello Ada") ]);
    ]
  in
  let output = run_rpc_server_with_messages messages in
  let progress_requests = find_rpc_requests "camlflow/progress" output in
  let stages =
    List.filter_map
      (fun request ->
        match request.Camlflow.Rpc_protocol.request_params with
        | Some (`Assoc fields) -> (
            match List.assoc_opt "stage" fields with
            | Some (`String stage) -> Some stage
            | _ -> None)
        | _ -> None)
      progress_requests
  in
  Alcotest.(check (list string))
    "progress stages"
    [ "run-start"; "effect-start"; "effect-finish"; "run-finish" ]
    stages;
  let effect_finish =
    match
      List.find_opt
        (fun request ->
          match request.Camlflow.Rpc_protocol.request_params with
          | Some (`Assoc fields) -> (
              match List.assoc_opt "stage" fields with
              | Some (`String stage) -> String.equal stage "effect-finish"
              | _ -> false)
          | _ -> false)
        progress_requests
    with
    | Some request -> request
    | None -> Alcotest.fail "missing effect-finish progress"
  in
  (match effect_finish.Camlflow.Rpc_protocol.request_params with
  | Some json ->
      expect_int_field "completedSteps" 1 json;
      expect_bool_field "cancellable" true json
  | None -> Alcotest.fail "missing progress params");
  let run_finish =
    match List.rev progress_requests with
    | request :: _ -> request
    | [] -> Alcotest.fail "missing run-finish progress"
  in
  match run_finish.Camlflow.Rpc_protocol.request_params with
  | Some json ->
      expect_string_field "stage" "run-finish" json;
      expect_bool_field "cancellable" false json
  | None -> Alcotest.fail "missing run-finish progress params"

let test_rpc_server_initialize_notification_preferences () =
  with_temp_dir "camlflow-rpc-notification-prefs-" @@ fun dir ->
  let workflow = Filename.concat dir "workflow.cml" in
  write_file workflow
    {|
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting
|};
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        ~params:
          (`Assoc
             [
               ( "notifications",
                 `Assoc [ ("trace", `Bool false); ("progress", `Bool true) ] );
             ])
        "initialize";
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
        ~params:
          (`Assoc
             [
               ( "program",
                 `Assoc
                   [
                     ("path", `String workflow);
                     ("includePaths", `List []);
                     ("skillsDir", `Null);
                   ] );
               ("entry", `String "main");
               ("input", `String "Ada");
             ])
        "camlflow/run";
      Camlflow.Rpc_protocol.success (Camlflow.Rpc_protocol.String "effect-1")
        (`Assoc [ ("output", `String "hello Ada") ]);
    ]
  in
  let output = run_rpc_server_with_messages messages in
  Alcotest.(check int)
    "trace disabled" 0
    (List.length (find_rpc_requests "camlflow/trace" output));
  Alcotest.(check bool)
    "progress still enabled" true
    (List.length (find_rpc_requests "camlflow/progress" output) > 0)

let test_rpc_server_initialize_can_disable_diagnostics () =
  with_temp_dir "camlflow-rpc-diagnostic-prefs-" @@ fun dir ->
  let workflow = Filename.concat dir "workflow.cml" in
  write_file workflow {|let main (name : string) : string = name|};
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        ~params:
          (`Assoc
             [
               ( "notifications",
                 `Assoc
                   [ ("diagnostic", `Bool false); ("progress", `Bool true) ] );
             ])
        "initialize";
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
        ~params:
          (`Assoc
             [
               ( "program",
                 `Assoc
                   [
                     ("path", `String workflow);
                     ("includePaths", `List []);
                     ("skillsDir", `Null);
                   ] );
               ("entry", `String "main");
             ])
        "camlflow/run";
    ]
  in
  let output = run_rpc_server_with_messages messages in
  Alcotest.(check int)
    "diagnostics disabled" 0
    (List.length (find_rpc_requests "camlflow/diagnostic" output));
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int)
        "run failure still returned" (-32012) error.error_code
  | None -> Alcotest.fail "missing run failure response"

let test_rpc_server_end_to_end_requires_initialize () =
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        "camlflow/check";
    ]
  in
  let output = run_rpc_server_with_messages messages in
  let diagnostic = find_rpc_request "camlflow/diagnostic" output in
  (match diagnostic.Camlflow.Rpc_protocol.request_params with
  | Some json -> expect_string_field "message" "server not initialized" json
  | None -> Alcotest.fail "missing diagnostic params");
  let response = find_rpc_response_by_id "1" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int) "pre-init error code" (-32002) error.error_code;
      Alcotest.(check string)
        "pre-init error message" "server not initialized" error.error_message
  | None -> Alcotest.fail "missing error response"

let test_rpc_server_compile_includes_ir_version () =
  with_temp_dir "camlflow-rpc-compile-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main "let main : string = \"ok\"\n";
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        ~params:(`Assoc []) "initialize";
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
        ~params:
          (`Assoc
             [
               ( "program",
                 `Assoc
                   [
                     ("path", `String main);
                     ("includePaths", `List []);
                     ("skillsDir", `Null);
                   ] );
             ])
        "camlflow/compile";
    ]
  in
  let output = run_rpc_server_with_messages messages in
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_result with
  | Some json -> (
      expect_string_field "irVersion" Camlflow.Ir.ir_version json;
      match expect_assoc_field "artifact" json with
      | `Assoc _ as artifact ->
          expect_string_field "version" Camlflow.Ir.ir_version artifact
      | other ->
          Alcotest.failf "expected artifact object, got %s"
            (Yojson.Safe.to_string other))
  | None -> Alcotest.fail "missing compile result"

let test_rpc_server_invalid_request_error () =
  let messages =
    [ `Assoc [ ("id", `Int 1); ("method", `String "initialize") ] ]
  in
  let output = run_rpc_server_with_messages messages in
  let diagnostic = find_rpc_request "camlflow/diagnostic" output in
  (match diagnostic.Camlflow.Rpc_protocol.request_params with
  | Some json ->
      expect_string_field "method" "(invalid-request)" json;
      expect_string_field "message" "missing jsonrpc version" json
  | None -> Alcotest.fail "missing invalid-request diagnostic params");
  let response = find_rpc_response_without_id output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int)
        "invalid request error code" (-32600) error.error_code;
      Alcotest.(check string)
        "invalid request error message" "missing jsonrpc version"
        error.error_message
  | None -> Alcotest.fail "missing invalid request error response"

let test_rpc_server_method_not_found_error () =
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        ~params:(`Assoc []) "initialize";
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
        ~params:(`Assoc []) "camlflow/unknown";
    ]
  in
  let output = run_rpc_server_with_messages messages in
  let diagnostics = find_rpc_requests "camlflow/diagnostic" output in
  let diagnostic =
    match diagnostics with
    | diagnostic :: _ -> diagnostic
    | [] -> Alcotest.fail "missing method-not-found diagnostic"
  in
  (match diagnostic.Camlflow.Rpc_protocol.request_params with
  | Some json ->
      expect_string_field "method" "camlflow/unknown" json;
      expect_string_field "message" "method not found" json
  | None -> Alcotest.fail "missing method-not-found diagnostic params");
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int)
        "method not found error code" (-32601) error.error_code;
      Alcotest.(check string)
        "method not found error message" "method not found" error.error_message
  | None -> Alcotest.fail "missing method not found response"

let test_rpc_server_check_failure_error () =
  with_temp_dir "camlflow-rpc-check-fail-" @@ fun dir ->
  let missing = Filename.concat dir "missing.cml" in
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        ~params:(`Assoc []) "initialize";
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
        ~params:
          (`Assoc
             [
               ( "program",
                 `Assoc
                   [
                     ("path", `String missing);
                     ("includePaths", `List []);
                     ("skillsDir", `Null);
                   ] );
             ])
        "camlflow/check";
    ]
  in
  let output = run_rpc_server_with_messages messages in
  let diagnostics = find_rpc_requests "camlflow/diagnostic" output in
  let diagnostic =
    match diagnostics with
    | diagnostic :: _ -> diagnostic
    | [] -> Alcotest.fail "missing check failure diagnostic"
  in
  (match diagnostic.Camlflow.Rpc_protocol.request_params with
  | Some (`Assoc fields as json) -> (
      expect_string_field "method" "camlflow/check" json;
      match List.assoc_opt "message" fields with
      | Some (`String message) ->
          Alcotest.(check bool)
            "check failure mentions missing program" true
            (contains_substring message "program path does not exist")
      | _ -> Alcotest.fail "missing check failure message")
  | Some other ->
      Alcotest.failf "unexpected check failure diagnostic params: %s"
        (Yojson.Safe.to_string other)
  | None -> Alcotest.fail "missing check failure diagnostic params");
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int) "check failure error code" (-32010) error.error_code;
      Alcotest.(check bool)
        "check failure response mentions missing program" true
        (contains_substring error.error_message "program path does not exist")
  | None -> Alcotest.fail "missing check failure response"

let test_rpc_server_compile_failure_error () =
  with_temp_dir "camlflow-rpc-compile-fail-" @@ fun dir ->
  let missing = Filename.concat dir "missing.cml" in
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        ~params:(`Assoc []) "initialize";
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
        ~params:
          (`Assoc
             [
               ( "program",
                 `Assoc
                   [
                     ("path", `String missing);
                     ("includePaths", `List []);
                     ("skillsDir", `Null);
                   ] );
             ])
        "camlflow/compile";
    ]
  in
  let output = run_rpc_server_with_messages messages in
  let diagnostics = find_rpc_requests "camlflow/diagnostic" output in
  let diagnostic =
    match diagnostics with
    | diagnostic :: _ -> diagnostic
    | [] -> Alcotest.fail "missing compile failure diagnostic"
  in
  (match diagnostic.Camlflow.Rpc_protocol.request_params with
  | Some (`Assoc fields as json) -> (
      expect_string_field "method" "camlflow/compile" json;
      match List.assoc_opt "message" fields with
      | Some (`String message) ->
          Alcotest.(check bool)
            "compile failure mentions missing program" true
            (contains_substring message "program path does not exist")
      | _ -> Alcotest.fail "missing compile failure message")
  | Some other ->
      Alcotest.failf "unexpected compile failure diagnostic params: %s"
        (Yojson.Safe.to_string other)
  | None -> Alcotest.fail "missing compile failure diagnostic params");
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int)
        "compile failure error code" (-32011) error.error_code;
      Alcotest.(check bool)
        "compile failure response mentions missing program" true
        (contains_substring error.error_message "program path does not exist")
  | None -> Alcotest.fail "missing compile failure response"

let test_rpc_server_run_failure_error () =
  with_temp_dir "camlflow-rpc-run-fail-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main {|let main (name : string) : string = name|};
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        ~params:(`Assoc []) "initialize";
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
        ~params:
          (`Assoc
             [
               ( "program",
                 `Assoc
                   [
                     ("path", `String main);
                     ("includePaths", `List []);
                     ("skillsDir", `Null);
                   ] );
               ("entry", `String "main");
             ])
        "camlflow/run";
    ]
  in
  let output = run_rpc_server_with_messages messages in
  let traces = find_rpc_requests "camlflow/trace" output in
  let has_run_error =
    List.exists
      (fun request ->
        match request.Camlflow.Rpc_protocol.request_params with
        | Some (`Assoc fields) -> (
            match List.assoc_opt "event" fields with
            | Some (`String event) -> String.equal event "run-error"
            | _ -> false)
        | _ -> false)
      traces
  in
  Alcotest.(check bool) "run failure emits run-error trace" true has_run_error;
  let diagnostics = find_rpc_requests "camlflow/diagnostic" output in
  let diagnostic =
    match diagnostics with
    | diagnostic :: _ -> diagnostic
    | [] -> Alcotest.fail "missing run failure diagnostic"
  in
  (match diagnostic.Camlflow.Rpc_protocol.request_params with
  | Some (`Assoc fields as json) -> (
      expect_string_field "method" "camlflow/run" json;
      match List.assoc_opt "message" fields with
      | Some (`String message) ->
          Alcotest.(check bool)
            "run failure mentions missing input" true
            (contains_substring message "entrypoint requires input")
      | _ -> Alcotest.fail "missing run failure message")
  | Some other ->
      Alcotest.failf "unexpected run failure diagnostic params: %s"
        (Yojson.Safe.to_string other)
  | None -> Alcotest.fail "missing run failure diagnostic params");
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int) "run failure error code" (-32012) error.error_code;
      Alcotest.(check bool)
        "run failure response mentions missing input" true
        (contains_substring error.error_message "entrypoint requires input")
  | None -> Alcotest.fail "missing run failure response"

let test_rpc_server_effect_error_propagation () =
  with_temp_dir "camlflow-rpc-effect-fail-" @@ fun dir ->
  let workflow = Filename.concat dir "workflow.cml" in
  write_file workflow
    {|
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting
|};
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        ~params:(`Assoc []) "initialize";
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
        ~params:
          (`Assoc
             [
               ( "program",
                 `Assoc
                   [
                     ("path", `String workflow);
                     ("includePaths", `List []);
                     ("skillsDir", `Null);
                   ] );
               ("entry", `String "main");
               ("input", `String "Ada");
             ])
        "camlflow/run";
      Camlflow.Rpc_protocol.error ~id:(Camlflow.Rpc_protocol.String "effect-1")
        ~code:(-32000) ~message:"model timeout" ();
    ]
  in
  let output = run_rpc_server_with_messages messages in
  let traces = find_rpc_requests "camlflow/trace" output in
  let has_effect_error =
    List.exists
      (fun request ->
        match request.Camlflow.Rpc_protocol.request_params with
        | Some (`Assoc fields) -> (
            match List.assoc_opt "event" fields with
            | Some (`String event) -> String.equal event "effect-error"
            | _ -> false)
        | _ -> false)
      traces
  in
  Alcotest.(check bool)
    "effect failure emits effect-error trace" true has_effect_error;
  let diagnostics = find_rpc_requests "camlflow/diagnostic" output in
  Alcotest.(check bool)
    "effect failure emits diagnostics" true
    (List.length diagnostics >= 2);
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int) "effect failure error code" (-32012) error.error_code;
      Alcotest.(check bool)
        "effect failure response mentions host timeout" true
        (contains_substring error.error_message
           "host returned JSON-RPC error -32000 for greeter: model timeout")
  | None -> Alcotest.fail "missing effect failure response"

let test_rpc_server_cancellation_returns_request_cancelled () =
  with_temp_dir "camlflow-rpc-cancel-" @@ fun dir ->
  let workflow = Filename.concat dir "workflow.cml" in
  write_file workflow
    {|
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting
|};
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        ~params:(`Assoc []) "initialize";
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
        ~params:
          (`Assoc
             [
               ( "program",
                 `Assoc
                   [
                     ("path", `String workflow);
                     ("includePaths", `List []);
                     ("skillsDir", `Null);
                   ] );
               ("entry", `String "main");
               ("input", `String "Ada");
             ])
        "camlflow/run";
      Camlflow.Rpc_protocol.request
        ~params:(`Assoc [ ("id", `Int 2) ])
        "$/cancelRequest";
      Camlflow.Rpc_protocol.success (Camlflow.Rpc_protocol.String "effect-1")
        (`Assoc [ ("output", `String "hello Ada") ]);
    ]
  in
  let output = run_rpc_server_with_messages messages in
  let traces = find_rpc_requests "camlflow/trace" output in
  let has_run_cancelled =
    List.exists
      (fun request ->
        match request.Camlflow.Rpc_protocol.request_params with
        | Some (`Assoc fields) -> (
            match List.assoc_opt "event" fields with
            | Some (`String event) -> String.equal event "run-cancelled"
            | _ -> false)
        | _ -> false)
      traces
  in
  Alcotest.(check bool)
    "cancellation emits run-cancelled trace" true has_run_cancelled;
  let diagnostics = find_rpc_requests "camlflow/diagnostic" output in
  let has_cancel_diagnostic =
    List.exists
      (fun request ->
        match request.Camlflow.Rpc_protocol.request_params with
        | Some (`Assoc fields) -> (
            match List.assoc_opt "message" fields with
            | Some (`String message) ->
                String.equal message "run cancelled by host"
            | _ -> false)
        | _ -> false)
      diagnostics
  in
  Alcotest.(check bool)
    "cancellation emits diagnostic" true has_cancel_diagnostic;
  let responses = List.filter_map rpc_response_message output in
  Alcotest.(check int)
    "late effect response is ignored" 2 (List.length responses);
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int) "cancellation error code" (-32800) error.error_code;
      Alcotest.(check string)
        "cancellation error message" "run cancelled by host" error.error_message
  | None -> Alcotest.fail "missing cancellation response"

let test_rpc_server_cancellation_after_effect_response_before_run_finish () =
  with_temp_dir "camlflow-rpc-cancel-after-effect-response-" @@ fun dir ->
  let workflow = Filename.concat dir "workflow.cml" in
  write_file workflow
    {|
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting
|};
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        ~params:(`Assoc []) "initialize";
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
        ~params:
          (`Assoc
             [
               ( "program",
                 `Assoc
                   [
                     ("path", `String workflow);
                     ("includePaths", `List []);
                     ("skillsDir", `Null);
                   ] );
               ("entry", `String "main");
               ("input", `String "Ada");
             ])
        "camlflow/run";
      Camlflow.Rpc_protocol.success (Camlflow.Rpc_protocol.String "effect-1")
        (`Assoc [ ("output", `String "hello Ada") ]);
      Camlflow.Rpc_protocol.request
        ~params:(`Assoc [ ("id", `Int 2) ])
        "$/cancelRequest";
    ]
  in
  let output = run_rpc_server_with_messages messages in
  Alcotest.(check int)
    "run-finish not emitted after late cancellation" 0
    (List.length
       (List.filter
          (fun request ->
            match request.Camlflow.Rpc_protocol.request_params with
            | Some (`Assoc fields) -> (
                match List.assoc_opt "stage" fields with
                | Some (`String stage) -> String.equal stage "run-finish"
                | _ -> false)
            | _ -> false)
          (find_rpc_requests "camlflow/progress" output)));
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int)
        "late cancellation error code" (-32800) error.error_code
  | None -> Alcotest.fail "missing late cancellation response"

let test_rpc_server_cancellation_before_next_effect_request () =
  with_temp_dir "camlflow-rpc-cancel-between-effects-" @@ fun dir ->
  let workflow = Filename.concat dir "workflow.cml" in
  write_file workflow
    {|
agent greeter : name:string -> string = Agent.bind "greeter"
skill caveman : prompt:string -> string = Skill.bind "caveman"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  let* short = caveman ~prompt:greeting in
  short
|};
  let messages =
    [
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
        ~params:(`Assoc []) "initialize";
      Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
        ~params:
          (`Assoc
             [
               ( "program",
                 `Assoc
                   [
                     ("path", `String workflow);
                     ("includePaths", `List []);
                     ("skillsDir", `Null);
                   ] );
               ("entry", `String "main");
               ("input", `String "Ada");
             ])
        "camlflow/run";
      Camlflow.Rpc_protocol.success (Camlflow.Rpc_protocol.String "effect-1")
        (`Assoc [ ("output", `String "hello Ada") ]);
      Camlflow.Rpc_protocol.request
        ~params:(`Assoc [ ("id", `Int 2) ])
        "$/cancelRequest";
      Camlflow.Rpc_protocol.success (Camlflow.Rpc_protocol.String "effect-2")
        (`Assoc [ ("output", `String "me ada") ]);
    ]
  in
  let output = run_rpc_server_with_messages messages in
  let effect_requests = find_rpc_requests "camlflow/executeEffect" output in
  Alcotest.(check int)
    "second effect request is skipped after cancellation" 1
    (List.length effect_requests);
  let progress_requests = find_rpc_requests "camlflow/progress" output in
  let has_run_cancelled_progress =
    List.exists
      (fun request ->
        match request.Camlflow.Rpc_protocol.request_params with
        | Some (`Assoc fields) -> (
            match List.assoc_opt "stage" fields with
            | Some (`String stage) -> String.equal stage "run-cancelled"
            | _ -> false)
        | _ -> false)
      progress_requests
  in
  Alcotest.(check bool)
    "cancellation emits run-cancelled progress" true has_run_cancelled_progress;
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int)
        "between-effects cancellation error code" (-32800) error.error_code
  | None -> Alcotest.fail "missing between-effects cancellation response"

let test_rpc_server_relays_output_chunk_notifications () =
  with_temp_dir "camlflow-rpc-output-chunk-" @@ fun dir ->
  let input_path = Filename.concat dir "input.rpc" in
  let output_path = Filename.concat dir "output.rpc" in
  write_rpc_messages input_path [];
  let input = In_channel.open_bin input_path in
  let output_channel = Out_channel.open_bin output_path in
  Fun.protect
    ~finally:(fun () ->
      In_channel.close input;
      Out_channel.close output_channel)
    (fun () ->
      let server : Camlflow.Rpc_server.server =
        {
          input;
          output = output_channel;
          initialized = true;
          shutdown_requested = false;
          next_run = 1;
          active_run = None;
          pending_message = None;
          trace_enabled = true;
          diagnostics_enabled = true;
          progress_enabled = true;
        }
      in
      let request =
        build_effect_request ~step_index:1 ~run_id:"run-1"
          (make_invocation ~name:"greeter" ())
      in
      match
        Camlflow.Rpc_server.handle_in_run_output_chunk server request
          (`Assoc
             [
               ("runId", `String "run-1");
               ("step", `Int 1);
               ("streamId", `String "stream-1");
               ("format", `String "text");
               ("delta", `String "hello ");
               ("done", `Bool false);
             ])
      with
      | Ok () -> (
          Out_channel.flush output_channel;
          let output = read_rpc_messages output_path in
          let chunks = find_rpc_requests "camlflow/outputChunk" output in
          Alcotest.(check int) "relayed chunk count" 1 (List.length chunks);
          match chunks with
          | [ request ] -> (
              match request.Camlflow.Rpc_protocol.request_params with
              | Some json ->
                  expect_string_field "streamId" "stream-1" json;
                  expect_string_field "delta" "hello " json;
                  expect_bool_field "done" false json
              | None -> Alcotest.fail "missing relayed output chunk params")
          | _ -> Alcotest.fail "expected relayed output chunk")
      | Error error -> Alcotest.failf "output chunk relay failed: %s" error)

let test_provider_schema_for_tuple_and_option () =
  let schema =
    schema_for_type
      (Camlflow.Ir.TTuple
         [
           Camlflow.Ir.TString;
           Camlflow.Ir.TOption Camlflow.Ir.TInt;
           Camlflow.Ir.TList Camlflow.Ir.TBool;
         ])
  in
  expect_string_field "$schema" "https://json-schema.org/draft/2020-12/schema"
    schema;
  expect_string_field "type" "array" schema;
  match expect_assoc_field "prefixItems" schema with
  | `List [ first; second; third ] ->
      expect_string_field "type" "string" first;
      (match expect_assoc_field "oneOf" second with
      | `List [ none_case; some_case ] ->
          expect_string_field "type" "object" none_case;
          expect_string_field "const" "None"
            (expect_assoc_field "tag"
               (expect_assoc_field "properties" none_case));
          expect_string_field "type" "object" some_case;
          expect_string_field "const" "Some"
            (expect_assoc_field "tag"
               (expect_assoc_field "properties" some_case));
          expect_string_field "type" "integer"
            (expect_assoc_field "value"
               (expect_assoc_field "properties" some_case))
      | other ->
          Alcotest.failf "unexpected option schema: %s"
            (Yojson.Safe.to_string other));
      expect_string_field "type" "array" third;
      expect_string_field "type" "boolean" (expect_assoc_field "items" third)
  | other ->
      Alcotest.failf "unexpected tuple schema: %s" (Yojson.Safe.to_string other)

let test_provider_schema_for_named_types () =
  with_temp_dir "camlflow-schema-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
type review = Approved | NeedsChanges of string

type report = { author : string; review : review }

let main : report =
  { author = "Ada"; review = Approved }
|};
  let program = check_file main in
  let types = Camlflow.Value.type_index_of_program program in
  let report_decl = find_type_decl program "report" in
  let review_decl = find_type_decl program "review" in
  let report_key =
    Camlflow.Syntax.Ast.string_of_qname report_decl.Camlflow.Ir.type_name
  in
  let review_key =
    Camlflow.Syntax.Ast.string_of_qname review_decl.Camlflow.Ir.type_name
  in
  let schema =
    schema_for_type ~types
      (Camlflow.Ir.TRecord report_decl.Camlflow.Ir.type_name)
  in
  expect_string_field "$schema" "https://json-schema.org/draft/2020-12/schema"
    schema;
  expect_string_field "$ref" ("#/$defs/" ^ report_key) schema;
  match expect_assoc_field "$defs" schema with
  | `Assoc defs -> (
      let report_schema =
        match List.assoc_opt report_key defs with
        | Some schema -> schema
        | None -> Alcotest.failf "missing report schema def %s" report_key
      in
      let review_schema =
        match List.assoc_opt review_key defs with
        | Some schema -> schema
        | None -> Alcotest.failf "missing review schema def %s" review_key
      in
      expect_string_field "type" "object" report_schema;
      expect_string_field "$ref" ("#/$defs/" ^ review_key)
        (expect_assoc_field "review"
           (expect_assoc_field "properties" report_schema));
      match expect_assoc_field "oneOf" review_schema with
      | `List [ approved; needs_changes ] ->
          expect_string_field "const" "Approved"
            (expect_assoc_field "tag"
               (expect_assoc_field "properties" approved));
          expect_string_field "const" "NeedsChanges"
            (expect_assoc_field "tag"
               (expect_assoc_field "properties" needs_changes));
          expect_string_field "type" "string"
            (expect_assoc_field "value"
               (expect_assoc_field "properties" needs_changes))
      | other ->
          Alcotest.failf "unexpected variant schema: %s"
            (Yojson.Safe.to_string other))
  | other ->
      Alcotest.failf "unexpected defs payload: %s" (Yojson.Safe.to_string other)

let test_provider_prompt_for_bound_agent () =
  let rendered =
    render_prompt
      (make_invocation ~name:"greeter"
         ~input:(`Assoc [ ("name", `String "Ada") ])
         ~working_directory:"/workspace" ())
  in
  Alcotest.(check (option string))
    "requested model" None rendered.requested_model;
  Alcotest.(check (list string))
    "unsupported settings" [] rendered.unsupported_settings;
  if not (contains_substring rendered.prompt "- role: agent") then
    Alcotest.failf "missing agent role in prompt: %s" rendered.prompt;
  if not (contains_substring rendered.prompt "- name: greeter") then
    Alcotest.failf "missing step name in prompt: %s" rendered.prompt;
  if not (contains_substring rendered.prompt "\"Ada\"") then
    Alcotest.failf "missing input JSON in prompt: %s" rendered.prompt;
  if not (contains_substring rendered.prompt "Return only JSON") then
    Alcotest.failf "missing output contract in prompt: %s" rendered.prompt

let test_provider_prompt_for_local_skill () =
  let rendered =
    render_prompt
      (make_invocation ~kind:Camlflow.Runtime.Context.Local_prompt_skill
         ~name:"caveman" ~markdown:"# Caveman\n\nReply tersely."
         ~skills_directory:"/workspace/skills" ())
  in
  if not (contains_substring rendered.prompt "- role: skill") then
    Alcotest.failf "missing skill role in prompt: %s" rendered.prompt;
  if
    not
      (contains_substring rendered.prompt
         "Local skill specification (SKILL.md):")
  then Alcotest.failf "missing SKILL.md section in prompt: %s" rendered.prompt;
  if not (contains_substring rendered.prompt "Reply tersely.") then
    Alcotest.failf "missing skill markdown body in prompt: %s" rendered.prompt

let test_provider_prompt_for_inline_agent () =
  let definition =
    {
      Camlflow.Ir.define_model = Some "gpt-5.4-mini";
      define_temperature = Some 0.1;
      define_system_prompt = Some "Review tersely";
      define_metadata = [ ("tone", Camlflow.Ir.LString "terse") ];
      define_loc = Camlflow.Loc.none;
    }
  in
  let rendered =
    render_prompt
      (make_invocation ~kind:Camlflow.Runtime.Context.Inline_agent
         ~name:"reviewer" ~definition ())
  in
  Alcotest.(check (option string))
    "requested model" (Some "gpt-5.4-mini") rendered.requested_model;
  Alcotest.(check (list string))
    "unsupported settings" [ "temperature" ] rendered.unsupported_settings;
  if
    not
      (contains_substring rendered.prompt
         "The system prompt only defines task intent; it does not need to \
          restate the response structure.")
  then
    Alcotest.failf "missing generated response-contract guidance: %s"
      rendered.prompt;
  if not (contains_substring rendered.prompt "Inline agent system prompt:") then
    Alcotest.failf "missing inline system prompt section: %s" rendered.prompt;
  if not (contains_substring rendered.prompt "Review tersely") then
    Alcotest.failf "missing inline system prompt body: %s" rendered.prompt;
  if not (contains_substring rendered.prompt "Inline agent metadata (JSON):")
  then Alcotest.failf "missing inline metadata section: %s" rendered.prompt;
  if not (contains_substring rendered.prompt "\"tone\"") then
    Alcotest.failf "missing inline metadata payload: %s" rendered.prompt

let test_provider_prompt_derives_structured_response_contract () =
  with_temp_dir "camlflow-prompt-contract-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
type action = TEST | RUN

type code_response = {
  action : action;
  accuracy : int;
  description : string;
}

let main : string = "ok"
|};
  let program = check_file main in
  let response_decl = find_type_decl program "code_response" in
  let rendered =
    render_prompt
      (make_invocation ~kind:Camlflow.Runtime.Context.Inline_agent
         ~name:"reviewer"
         ~return_type:(Camlflow.Ir.TRecord response_decl.Camlflow.Ir.type_name)
         ~types:(Camlflow.Value.type_index_of_program program)
         ~definition:
           {
             Camlflow.Ir.define_model = None;
             define_temperature = None;
             define_system_prompt = Some "Review the submitted code.";
             define_metadata = [];
             define_loc = Camlflow.Loc.none;
           }
         ())
  in
  if not (contains_substring rendered.prompt "Declared response contract:") then
    Alcotest.failf "missing declared response contract section: %s"
      rendered.prompt;
  if
    not
      (contains_substring rendered.prompt
         "The system prompt only defines task intent; it does not need to \
          restate the response structure.")
  then Alcotest.failf "missing task-vs-structure guidance: %s" rendered.prompt;
  if
    not
      (contains_substring rendered.prompt
         "code_response is encoded as a JSON object with required fields:")
  then Alcotest.failf "missing record contract details: %s" rendered.prompt;
  if not (contains_substring rendered.prompt "action: tagged JSON variant") then
    Alcotest.failf "missing variant field summary: %s" rendered.prompt;
  if not (contains_substring rendered.prompt {|TEST -> {"tag":"TEST"}|}) then
    Alcotest.failf "missing TEST constructor encoding: %s" rendered.prompt;
  if not (contains_substring rendered.prompt {|RUN -> {"tag":"RUN"}|}) then
    Alcotest.failf "missing RUN constructor encoding: %s" rendered.prompt

let test_effect_request_for_local_skill () =
  let invocation =
    make_invocation ~kind:Camlflow.Runtime.Context.Local_prompt_skill
      ~name:"caveman"
      ~input:(`Assoc [ ("prompt", `String "hello") ])
      ~return_type:Camlflow.Ir.TString ~skills_directory:"/workspace/skills"
      ~markdown:"# Caveman\n\nReply tersely." ()
  in
  let request = build_effect_request ~step_index:7 ~run_id:"run-1" invocation in
  Alcotest.(check string)
    "kind" "local-prompt-skill"
    (Camlflow.Effect_request.kind_to_string request.kind);
  Alcotest.(check string) "name" "caveman" request.name;
  Alcotest.(check string)
    "declared return type" "string" request.declared_return_type;
  Alcotest.(check (option string))
    "skills directory" (Some "/workspace/skills") request.skills_directory;
  Alcotest.(check (option string))
    "skill markdown" (Some "# Caveman\n\nReply tersely.") request.skill_markdown;
  Alcotest.(check (option int)) "step index" (Some 7) request.step_index;
  Alcotest.(check (option string)) "run id" (Some "run-1") request.run_id;
  Alcotest.(check (option string))
    "requested model" None request.requested_model;
  Alcotest.(check (list string))
    "unsupported settings" [] request.unsupported_settings;
  expect_string_field "type" "string" request.output_schema;
  if not (contains_substring request.rendered_prompt "Reply tersely.") then
    Alcotest.failf "missing skill markdown in rendered prompt: %s"
      request.rendered_prompt;
  let json = Camlflow.Effect_request.to_yojson request in
  expect_string_field "kind" "local-prompt-skill" json;
  expect_string_field "role" "skill" json;
  expect_string_field "name" "caveman" json

let test_effect_request_for_inline_agent () =
  let definition =
    {
      Camlflow.Ir.define_model = Some "gpt-5.4-mini";
      define_temperature = Some 0.1;
      define_system_prompt = Some "Review tersely";
      define_metadata = [ ("tone", Camlflow.Ir.LString "terse") ];
      define_loc = Camlflow.Loc.none;
    }
  in
  let invocation =
    make_invocation ~kind:Camlflow.Runtime.Context.Inline_agent ~name:"reviewer"
      ~definition ~working_directory:"/workspace" ()
  in
  let request = build_effect_request invocation in
  Alcotest.(check string)
    "kind" "inline-agent"
    (Camlflow.Effect_request.kind_to_string request.kind);
  Alcotest.(check (option string))
    "requested model" (Some "gpt-5.4-mini") request.requested_model;
  Alcotest.(check (list string))
    "unsupported settings" [ "temperature" ] request.unsupported_settings;
  Alcotest.(check (option string))
    "working directory" (Some "/workspace") request.working_directory;
  Alcotest.(check bool)
    "inline definition present" true
    (Option.is_some request.inline_definition);
  if not (contains_substring request.rendered_prompt "Review tersely") then
    Alcotest.failf "missing inline prompt in rendered request: %s"
      request.rendered_prompt;
  let json = Camlflow.Effect_request.to_yojson request in
  expect_string_field "kind" "inline-agent" json;
  expect_string_field "role" "agent" json;
  match expect_assoc_field "inlineDefinition" json with
  | `Assoc _ -> ()
  | other ->
      Alcotest.failf "expected inlineDefinition object, got %s"
        (Yojson.Safe.to_string other)

let test_effect_bridge_executes_with_effect_request () =
  let invocation =
    make_invocation ~kind:Camlflow.Runtime.Context.Local_prompt_skill
      ~name:"caveman"
      ~input:(`Assoc [ ("prompt", `String "hello") ])
      ~skills_directory:"/workspace/skills"
      ~markdown:"# Caveman\n\nReply tersely." ()
  in
  let execution =
    run_effect_bridge ~step_index:3 ~run_id:"run-2"
      ~executor:(fun request ->
        Alcotest.(check string) "executor request name" "caveman" request.name;
        Alcotest.(check (option int))
          "executor step" (Some 3) request.step_index;
        Alcotest.(check (option string))
          "executor run id" (Some "run-2") request.run_id;
        Ok (`String request.name))
      invocation
  in
  Alcotest.(check string) "bridge request name" "caveman" execution.request.name;
  match execution.output_json with
  | `String value -> Alcotest.(check string) "bridge output" "caveman" value
  | json ->
      Alcotest.failf "expected string bridge output, got %s"
        (Yojson.Safe.to_string json)

let test_effect_bridge_validation_error () =
  let invocation = make_invocation ~name:"greeter" () in
  expect_error_contains "effect bridge validation"
    "host output for agent greeter does not match declared return type string"
    (Camlflow.Effect_bridge.validate_output ~source:"host" invocation (`Int 7))

let test_codex_build_exec_args () =
  let settings =
    {
      Camlflow.Provider.default_settings with
      provider = Some Camlflow.Provider.Codex;
      model = Some "gpt-5.4-mini";
      reasoning = Some Camlflow.Provider.Max;
      provider_profile = Some "daily";
      provider_configs = [ { Camlflow.Provider.key = "foo"; value = "bar" } ];
      sandbox = Camlflow.Provider.Read_only;
      allow_write_dirs = [ "tmp"; "/abs/cache" ];
    }
  in
  let argv =
    Camlflow.Providers_codex.build_exec_args ~working_directory:"/workspace"
      ~settings ~model:settings.model ~schema_path:"/tmp/schema.json"
      ~output_path:"/tmp/out.json"
  in
  let expected =
    [
      "codex";
      "exec";
      "--skip-git-repo-check";
      "-C";
      "/workspace";
      "--sandbox";
      "read-only";
      "--output-schema";
      "/tmp/schema.json";
      "--output-last-message";
      "/tmp/out.json";
      "--model";
      "gpt-5.4-mini";
      "--profile";
      "daily";
      "--config";
      "model_reasoning_effort=\"xhigh\"";
      "--config";
      "foo=bar";
      "--add-dir";
      "/workspace/tmp";
      "--add-dir";
      "/abs/cache";
      "-";
    ]
  in
  Alcotest.(check (list string)) "codex argv" expected argv

let test_codex_preflight_validation () =
  expect_error_contains "missing codex" "provider codex is not available"
    (Camlflow.Providers_codex.validate_preflight_status ~codex_available:false
       ~logged_in:false);
  expect_error_contains "missing login" "provider codex requires login"
    (Camlflow.Providers_codex.validate_preflight_status ~codex_available:true
       ~logged_in:false);
  match
    Camlflow.Providers_codex.validate_preflight_status ~codex_available:true
      ~logged_in:true
  with
  | Ok () -> ()
  | Error error -> Alcotest.failf "unexpected preflight error: %s" error

let test_codex_wrapped_response_schema () =
  let wrapped =
    match
      Camlflow.Providers_codex.wrapped_response_schema
        (`Assoc
           [
             ("$schema", `String "https://json-schema.org/draft/2020-12/schema");
             ("type", `String "string");
           ])
    with
    | Ok schema -> schema
    | Error error -> Alcotest.failf "wrapped schema failed: %s" error
  in
  expect_string_field "type" "object" wrapped;
  expect_string_field "$schema" "https://json-schema.org/draft/2020-12/schema"
    wrapped;
  expect_string_field "type" "string"
    (expect_assoc_field "result" (expect_assoc_field "properties" wrapped))

let test_provider_wrapped_response_json_unwraps_result () =
  match
    Camlflow.Provider_schema.unwrap_wrapped_response_json
      (`Assoc [ ("result", `String "hello") ])
  with
  | Ok (`String value) -> Alcotest.(check string) "wrapped result" "hello" value
  | Ok json ->
      Alcotest.failf "unexpected wrapped response JSON: %s"
        (Yojson.Safe.to_string json)
  | Error error -> Alcotest.failf "wrapped response unwrap failed: %s" error

let test_provider_wrapped_response_json_rejects_extra_fields () =
  expect_error_contains "wrapped response extra fields"
    "model response wrapper must not contain extra field(s): debug"
    (Camlflow.Provider_schema.unwrap_wrapped_response_json
       (`Assoc [ ("result", `String "hello"); ("debug", `Bool true) ]))

let test_provider_wrapped_response_json_rejects_duplicate_result_fields () =
  expect_error_contains "wrapped response duplicate result"
    "model response wrapper must contain exactly one result field"
    (Camlflow.Provider_schema.unwrap_wrapped_response_json
       (`Assoc [ ("result", `String "hello"); ("result", `String "again") ]))

let test_codex_inline_temperature_fails_fast () =
  with_temp_dir "camlflow-codex-temp-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
agent reviewer : code:string -> string =
  Agent.define ~temperature:0.1 ~system_prompt:"Review tersely"

let main (code : string) : string =
  let* review = reviewer ~code:code in
  review
|};
  let program = check_file main in
  let settings =
    {
      Camlflow.Provider.default_settings with
      provider = Some Camlflow.Provider.Codex;
    }
  in
  let base_context =
    Camlflow.Runtime.Context.empty |> fun context ->
    Camlflow.Runtime.Context.with_working_directory context dir
  in
  let context =
    match
      Camlflow.Providers_codex.build_runtime_context ~working_directory:dir
        ~settings base_context
    with
    | Ok context -> context
    | Error error -> Alcotest.failf "build runtime context failed: %s" error
  in
  expect_error_contains "inline temperature unsupported"
    "provider codex does not support inline setting(s) temperature"
    (Camlflow.Runtime.execute ~context ~input:(`String "let x = 1") program)

let test_opencode_build_exec_args () =
  let settings =
    {
      Camlflow.Provider.default_settings with
      provider = Some Camlflow.Provider.Opencode;
      model = Some "openai/gpt-5.4-mini";
      reasoning = Some Camlflow.Provider.Max;
    }
  in
  let argv =
    Camlflow.Providers_opencode.build_exec_args ~working_directory:"/workspace"
      ~settings ~model:settings.model ~prompt:"Reply with JSON"
  in
  let expected =
    [
      "opencode";
      "run";
      "--format";
      "json";
      "--pure";
      "--dir";
      "/workspace";
      "--dangerously-skip-permissions";
      "--model";
      "openai/gpt-5.4-mini";
      "--variant";
      "max";
      "Reply with JSON";
    ]
  in
  Alcotest.(check (list string)) "opencode argv" expected argv

let test_opencode_preflight_validation () =
  expect_error_contains "missing opencode" "provider opencode is not available"
    (Camlflow.Providers_opencode.validate_preflight_status
       ~opencode_available:false);
  match
    Camlflow.Providers_opencode.validate_preflight_status
      ~opencode_available:true
  with
  | Ok () -> ()
  | Error error -> Alcotest.failf "unexpected preflight error: %s" error

let test_opencode_parse_wrapped_response () =
  let events =
    match
      Camlflow.Providers_opencode.json_line_events
        (String.concat "\n"
           [
             "{\"type\":\"step_start\"}";
             "{\"type\":\"text\",\"part\":{\"text\":\"{\\\"result\\\":\\\"he\"}}";
             "{\"type\":\"text\",\"part\":{\"text\":\"llo\\\"}\"}}";
             "{\"type\":\"step_finish\"}";
           ])
    with
    | Ok events -> events
    | Error error -> Alcotest.failf "opencode event parse failed: %s" error
  in
  let text =
    match Camlflow.Providers_opencode.combined_text_response events with
    | Some text -> text
    | None -> Alcotest.fail "missing opencode text response"
  in
  match
    Camlflow.Providers_opencode.parse_wrapped_response ~trace_kind:"bound-agent"
      ~trace_name:"greeter" text
  with
  | Ok (`String value) ->
      Alcotest.(check string) "opencode parsed result" "hello" value
  | Ok json ->
      Alcotest.failf "unexpected opencode parsed JSON: %s"
        (Yojson.Safe.to_string json)
  | Error error -> Alcotest.failf "opencode parse failed: %s" error

let test_opencode_parse_wrapped_response_rejects_extra_fields () =
  expect_error_contains "opencode extra fields"
    "model response wrapper must not contain extra field(s): debug"
    (Camlflow.Providers_opencode.parse_wrapped_response
       ~trace_kind:"bound-agent" ~trace_name:"greeter"
       "{\"result\":\"hello\",\"debug\":true}")

let test_opencode_error_event_message () =
  let events =
    match
      Camlflow.Providers_opencode.json_line_events
        "{\"type\":\"error\",\"error\":{\"name\":\"UnknownError\",\"data\":{\"message\":\"Model \
         not found\"}}}"
    with
    | Ok events -> events
    | Error error -> Alcotest.failf "opencode event parse failed: %s" error
  in
  match
    Camlflow.Providers_opencode.response_text_or_error ~trace_kind:"bound-agent"
      ~trace_name:"greeter" events
  with
  | Ok text -> Alcotest.failf "expected opencode error, got text %s" text
  | Error error ->
      Alcotest.(check bool)
        "opencode error message extracted" true
        (contains_substring error "Model not found")

let test_opencode_inline_temperature_fails_fast () =
  with_temp_dir "camlflow-opencode-temp-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
agent reviewer : code:string -> string =
  Agent.define ~temperature:0.1 ~system_prompt:"Review tersely"

let main (code : string) : string =
  let* review = reviewer ~code:code in
  review
|};
  let program = check_file main in
  let settings =
    {
      Camlflow.Provider.default_settings with
      provider = Some Camlflow.Provider.Opencode;
    }
  in
  let base_context =
    Camlflow.Runtime.Context.empty |> fun context ->
    Camlflow.Runtime.Context.with_working_directory context dir
  in
  let context =
    match
      Camlflow.Providers_opencode.build_runtime_context ~working_directory:dir
        ~settings base_context
    with
    | Ok context -> context
    | Error error -> Alcotest.failf "build runtime context failed: %s" error
  in
  expect_error_contains "inline temperature unsupported"
    "provider opencode does not support inline setting(s) temperature"
    (Camlflow.Runtime.execute ~context ~input:(`String "let x = 1") program)

let test_claude_code_build_exec_args () =
  let settings =
    {
      Camlflow.Provider.default_settings with
      provider = Some Camlflow.Provider.Claude_code;
      model = Some "sonnet";
      reasoning = Some Camlflow.Provider.Medium;
      allow_write_dirs = [ "tmp"; "/abs/cache" ];
    }
  in
  let schema = `Assoc [ ("type", `String "object") ] in
  let argv =
    Camlflow.Providers_claude_code.build_exec_args
      ~working_directory:"/workspace" ~settings ~model:settings.model ~schema
      ~prompt:"Reply with JSON"
  in
  let expected =
    [
      "claude";
      "-p";
      "--output-format";
      "json";
      "--json-schema";
      "{\"type\":\"object\"}";
      "--cwd";
      "/workspace";
      "--bare";
      "--no-session-persistence";
      "--dangerously-skip-permissions";
      "--model";
      "sonnet";
      "--effort";
      "medium";
      "--add-dir";
      "/workspace/tmp";
      "--add-dir";
      "/abs/cache";
      "Reply with JSON";
    ]
  in
  Alcotest.(check (list string)) "claude-code argv" expected argv

let test_claude_code_preflight_validation () =
  expect_error_contains "missing claude-code"
    "provider claude-code is not available"
    (Camlflow.Providers_claude_code.validate_preflight_status
       ~claude_available:false ~logged_in:false);
  expect_error_contains "missing claude-code login"
    "provider claude-code requires login"
    (Camlflow.Providers_claude_code.validate_preflight_status
       ~claude_available:true ~logged_in:false);
  match
    Camlflow.Providers_claude_code.validate_preflight_status
      ~claude_available:true ~logged_in:true
  with
  | Ok () -> ()
  | Error error -> Alcotest.failf "unexpected preflight error: %s" error

let test_claude_code_parse_structured_response () =
  match
    Camlflow.Providers_claude_code.parse_structured_response
      ~trace_kind:"bound-agent" ~trace_name:"greeter"
      {|{"result":"hello","structured_output":{"result":"hello"}}|}
  with
  | Ok (`String value) ->
      Alcotest.(check string) "claude-code parsed result" "hello" value
  | Ok json ->
      Alcotest.failf "unexpected claude-code parsed JSON: %s"
        (Yojson.Safe.to_string json)
  | Error error -> Alcotest.failf "claude-code parse failed: %s" error

let test_claude_code_parse_structured_response_rejects_extra_fields () =
  expect_error_contains "claude-code extra fields"
    "model response wrapper must not contain extra field(s): debug"
    (Camlflow.Providers_claude_code.parse_structured_response
       ~trace_kind:"bound-agent" ~trace_name:"greeter"
       {|{"structured_output":{"result":"hello","debug":true}}|})

let test_claude_code_inline_temperature_fails_fast () =
  with_temp_dir "camlflow-claude-code-temp-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
agent reviewer : code:string -> string =
  Agent.define ~temperature:0.1 ~system_prompt:"Review tersely"

let main (code : string) : string =
  let* review = reviewer ~code:code in
  review
|};
  let program = check_file main in
  let settings =
    {
      Camlflow.Provider.default_settings with
      provider = Some Camlflow.Provider.Claude_code;
    }
  in
  let base_context =
    Camlflow.Runtime.Context.empty |> fun context ->
    Camlflow.Runtime.Context.with_working_directory context dir
  in
  let context =
    match
      Camlflow.Providers_claude_code.build_runtime_context
        ~working_directory:dir ~settings base_context
    with
    | Ok context -> context
    | Error error -> Alcotest.failf "build runtime context failed: %s" error
  in
  expect_error_contains "inline temperature unsupported"
    "provider claude-code does not support inline setting(s) temperature"
    (Camlflow.Runtime.execute ~context ~input:(`String "let x = 1") program)

let test_claude_cli_build_request_body () =
  let settings =
    {
      Camlflow.Provider.default_settings with
      provider = Some Camlflow.Provider.Claude_cli;
      reasoning = Some Camlflow.Provider.Low;
    }
  in
  let schema = `Assoc [ ("type", `String "object") ] in
  let request_body =
    Camlflow.Providers_claude_cli.build_request_body ~prompt:"Reply with JSON"
      ~schema ~model:"claude-sonnet-4-6" ~settings
  in
  let message =
    match expect_assoc_field "messages" request_body with
    | `List [ message ] -> message
    | other ->
        Alcotest.failf "expected one request message, got %s"
          (Yojson.Safe.to_string other)
  in
  expect_string_field "model" "claude-sonnet-4-6" request_body;
  expect_string_field "content" "Reply with JSON" message;
  expect_string_field "effort" "low"
    (expect_assoc_field "output_config" request_body)

let test_claude_cli_preflight_validation () =
  expect_error_contains "missing claude-cli"
    "provider claude-cli is not available"
    (Camlflow.Providers_claude_cli.validate_preflight_status
       ~ant_available:false ~api_key_present:false);
  expect_error_contains "missing claude-cli api key"
    "provider claude-cli requires ANTHROPIC_API_KEY"
    (Camlflow.Providers_claude_cli.validate_preflight_status ~ant_available:true
       ~api_key_present:false);
  match
    Camlflow.Providers_claude_cli.validate_preflight_status ~ant_available:true
      ~api_key_present:true
  with
  | Ok () -> ()
  | Error error -> Alcotest.failf "unexpected preflight error: %s" error

let test_claude_cli_parse_wrapped_response () =
  let response =
    `Assoc
      [
        ( "content",
          `List
            [
              `Assoc
                [
                  ("type", `String "text");
                  ("text", `String {|{"result":"hello"}|});
                ];
            ] );
      ]
  in
  let text =
    match
      Camlflow.Providers_claude_cli.extract_response_text
        ~trace_kind:"bound-agent" ~trace_name:"greeter" response
    with
    | Ok text -> text
    | Error error -> Alcotest.failf "claude-cli response text failed: %s" error
  in
  match
    Camlflow.Providers_claude_cli.parse_wrapped_response
      ~trace_kind:"bound-agent" ~trace_name:"greeter" text
  with
  | Ok (`String value) ->
      Alcotest.(check string) "claude-cli parsed result" "hello" value
  | Ok json ->
      Alcotest.failf "unexpected claude-cli parsed JSON: %s"
        (Yojson.Safe.to_string json)
  | Error error -> Alcotest.failf "claude-cli parse failed: %s" error

let test_claude_cli_missing_model_fails_fast () =
  with_temp_dir "camlflow-claude-cli-model-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
agent reviewer : code:string -> string =
  Agent.define ~system_prompt:"Review tersely"

let main (code : string) : string =
  let* review = reviewer ~code:code in
  review
|};
  let program = check_file main in
  let settings =
    {
      Camlflow.Provider.default_settings with
      provider = Some Camlflow.Provider.Claude_cli;
    }
  in
  let base_context =
    Camlflow.Runtime.Context.empty |> fun context ->
    Camlflow.Runtime.Context.with_working_directory context dir
  in
  let context =
    match
      Camlflow.Providers_claude_cli.build_runtime_context ~working_directory:dir
        ~settings base_context
    with
    | Ok context -> context
    | Error error -> Alcotest.failf "build runtime context failed: %s" error
  in
  expect_error_contains "missing claude-cli model"
    "provider claude-cli requires --model or inline Agent.define ~model"
    (Camlflow.Runtime.execute ~context ~input:(`String "let x = 1") program)

let test_wrong_argument_labels_fail () =
  with_temp_dir "camlflow-labels-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
let add ~(x : int) ~(y : int) : int =
  x + y

let main : int =
  add ~x:1 ~z:2
|};
  expect_error_contains "wrong argument labels" "argument label mismatch"
    (Camlflow.Typing.check_file main)

let test_unsupported_library_module_call_fails () =
  with_temp_dir "camlflow-stdlib-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main {|
let main : int =
  List.length []
|};
  expect_error_contains "unsupported library/module call"
    "qualified library/module calls such as List.<value> are unsupported"
    (Camlflow.Typing.check_file main)

let test_zero_arg_main_runs () =
  with_temp_dir "camlflow-zero-arg-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main {|
let main : string =
  "ready"
|};
  let program = check_file main in
  let result = run_program program in
  Alcotest.(check int) "zero-arg steps" 0 result.steps_run;
  Alcotest.(check string)
    "zero-arg output" "ready"
    (get_output_string result.output)

let test_check_ignores_unrelated_broken_files () =
  with_temp_dir "camlflow-ignore-broken-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  let broken = Filename.concat dir "broken.cml" in
  write_file main "let main : int = 1\n";
  write_file broken "let broken =\n";
  let program = check_file main in
  let result = run_program program in
  Alcotest.(check int)
    "unrelated broken file ignored" 1
    (get_output_int result.output)

let test_check_run_and_ir_roundtrip () =
  with_temp_dir "camlflow-main-" @@ fun dir ->
  let helpers = Filename.concat dir "helpers.cml" in
  let main = Filename.concat dir "main.cml" in
  write_file helpers "type payload = { name : string }\n";
  write_file main
    {|
open Helpers

agent greeter : name:string -> string = Agent.bind "greeter"

let make_payload (name : string) : payload =
  { name = name }

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting ^ "!"
|};
  let program = check_file main in
  let result = run_program ~input:(`String "Ada") program in
  Alcotest.(check int) "effect steps" 1 result.steps_run;
  Alcotest.(check string) "runtime output" "!" (get_output_string result.output);
  let artifact = Camlflow.Ir.to_json_string program in
  let reloaded =
    match Camlflow.Ir.of_json_string artifact with
    | Ok program -> program
    | Error error -> Alcotest.failf "artifact decode failed: %s" error
  in
  let result = run_program ~input:(`String "Ada") reloaded in
  Alcotest.(check string)
    "roundtrip output" "!"
    (get_output_string result.output)

let test_local_skill_resolution () =
  with_temp_dir "camlflow-skill-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  let skills_dir = Filename.concat dir "skills" in
  let caveman_dir = Filename.concat skills_dir "caveman" in
  Unix.mkdir skills_dir 0o755;
  Unix.mkdir caveman_dir 0o755;
  write_file
    (Filename.concat caveman_dir "SKILL.md")
    "# Caveman\n\nPrompt-backed test skill.\n";
  write_file main
    {|
skill caveman : prompt:string -> string = Skill.bind "caveman"

let main (prompt : string) : string =
  let* answer = caveman ~prompt:prompt in
  answer
|};
  let program = check_file main in
  let context =
    Camlflow.Runtime.Context.with_skills_directory
      Camlflow.Runtime.Context.empty skills_dir
  in
  let result = run_program ~context ~input:(`String "hello") program in
  Alcotest.(check int) "local skill step count" 1 result.steps_run;
  Alcotest.(check string)
    "local skill kind" "local-skill" (List.hd result.effect_steps).step_kind;
  Alcotest.(check string)
    "local skill output" ""
    (get_output_string result.output)

let test_unresolved_open_fails () =
  with_temp_dir "camlflow-bad-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main "open Missing\nlet main = 1\n";
  match Camlflow.Typing.check_file main with
  | Ok _ -> Alcotest.fail "expected unresolved open to fail"
  | Error error ->
      if not (String.contains error 'M') then
        Alcotest.failf "unexpected error: %s" error

let test_non_exhaustive_match_fails () =
  with_temp_dir "camlflow-match-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
type t = A | B

let main (x : t) : int =
  match x with
  | A -> 1
|};
  expect_error_contains "non-exhaustive match" "non-exhaustive match"
    (Camlflow.Typing.check_file main)

let test_wildcard_match_is_exhaustive () =
  with_temp_dir "camlflow-match-wildcard-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
let main (flag : bool) : int =
  match flag with
  | _ -> 1
|};
  let program = check_file main in
  let true_result = run_program ~input:(`Bool true) program in
  let false_result = run_program ~input:(`Bool false) program in
  Alcotest.(check int)
    "wildcard true branch" 1
    (get_output_int true_result.output);
  Alcotest.(check int)
    "wildcard false branch" 1
    (get_output_int false_result.output)

let test_ctor_then_wildcard_match_is_exhaustive () =
  with_temp_dir "camlflow-match-ctor-wildcard-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
let main (flag : bool) : int =
  match flag with
  | true -> 1
  | _ -> 0
|};
  let program = check_file main in
  let true_result = run_program ~input:(`Bool true) program in
  let false_result = run_program ~input:(`Bool false) program in
  Alcotest.(check int)
    "ctor wildcard true branch" 1
    (get_output_int true_result.output);
  Alcotest.(check int)
    "ctor wildcard false branch" 0
    (get_output_int false_result.output)

let test_effectful_call_requires_let_star () =
  with_temp_dir "camlflow-effects-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  greeter ~name:name
|};
  match Camlflow.Typing.check_file main with
  | Ok _ -> Alcotest.fail "expected direct effectful call to fail"
  | Error error ->
      if not (String.contains error '*') then
        Alcotest.failf "unexpected error: %s" error

let test_unsaturated_agent_call_fails () =
  with_temp_dir "camlflow-unsat-agent-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
agent greeter : name:string -> string = Agent.bind "greeter"

let main : string =
  greeter
|};
  expect_error_contains "unsaturated agent call" "must be fully applied"
    (Camlflow.Typing.check_file main)

let test_unsaturated_skill_call_fails () =
  with_temp_dir "camlflow-unsat-skill-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
skill caveman : prompt:string -> string = Skill.bind "caveman"

let main : string =
  caveman
|};
  expect_error_contains "unsaturated skill call" "must be fully applied"
    (Camlflow.Typing.check_file main)

let test_qualified_refs_without_open () =
  with_temp_dir "camlflow-qualified-" @@ fun dir ->
  let helpers = Filename.concat dir "helpers.cml" in
  let main = Filename.concat dir "main.cml" in
  write_file helpers
    {|
type payload = { name : string }

let make (name : string) : payload =
  { name = name }
|};
  write_file main
    {|
let main (name : string) : string =
  let payload : Helpers.payload = Helpers.make name in
  payload.name
|};
  let program = check_file main in
  let result = run_program ~input:(`String "Ada") program in
  Alcotest.(check string)
    "qualified module output" "Ada"
    (get_output_string result.output)

let test_recursion_and_int_builtins () =
  with_temp_dir "camlflow-rec-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
let rec sum_to (n : int) : int =
  if n = 0 then 0 else n + sum_to (n - 1)

let main (n : int) : int =
  sum_to n
|};
  let program = check_file main in
  let result = run_program ~input:(`Int 4) program in
  Alcotest.(check int) "recursive result" 10 (get_output_int result.output)

let test_option_helper_builtins () =
  with_temp_dir "camlflow-option-builtins-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
let primary_hint : string option = Some "retry"
let backup_hint : string option = None

let main : string =
  if is_some primary_hint && is_none backup_hint then
    unwrap_or primary_hint "missing"
  else
    unwrap_or backup_hint "fallback"
|};
  let program = check_file main in
  let result = run_program program in
  Alcotest.(check string)
    "option helper output" "retry"
    (get_output_string result.output)

let test_bool_match_patterns () =
  with_temp_dir "camlflow-bool-match-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
let main (flag : bool) : int =
  match flag with
  | true -> 1
  | false -> 0
|};
  let program = check_file main in
  let true_result = run_program ~input:(`Bool true) program in
  let false_result = run_program ~input:(`Bool false) program in
  Alcotest.(check int) "true branch" 1 (get_output_int true_result.output);
  Alcotest.(check int) "false branch" 0 (get_output_int false_result.output)

let test_float_operators () =
  with_temp_dir "camlflow-float-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main {|
let main (x : float) : float =
  (x +. 1.5) *. 2.0
|};
  let program = check_file main in
  let result = run_program ~input:(`Float 2.0) program in
  Alcotest.(check (float 0.0001))
    "float result" 7.0
    (get_output_float result.output)

let test_default_provider_hook_for_bound_agent () =
  with_temp_dir "camlflow-provider-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting
|};
  let program = check_file main in
  let context =
    Camlflow.Runtime.Context.with_default_provider
      Camlflow.Runtime.Context.empty (fun invocation ->
        match invocation.Camlflow.Runtime.Context.invocation_kind with
        | Camlflow.Runtime.Context.Bound_agent ->
            Ok (`String invocation.invocation_name)
        | _ -> Error "unexpected invocation kind")
  in
  let result = run_program ~context ~input:(`String "Ada") program in
  Alcotest.(check string)
    "default provider result" "greeter"
    (get_output_string result.output)

let test_inline_agent_typed_response_branches_with_if_and_match () =
  with_temp_dir "camlflow-model-response-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
type action = TEST | RUN

type code_response = {
  action : action;
  accuracy : int;
  description : string;
}

agent reviewer : code:string -> code_response =
  Agent.define ~system_prompt:"Review the submitted code."

let branch_summary (response : code_response) : string =
  if response.accuracy < 90 then
    match response.action with
    | TEST -> "retry-after-tests: " ^ response.description
    | RUN -> "retry-after-fix: " ^ response.description
  else
    match response.action with
    | TEST -> "run-tests: " ^ response.description
    | RUN -> "continue: " ^ response.description

let main (code : string) : string =
  let* response = reviewer ~code:code in
  branch_summary response
|};
  let program = check_file main in
  let provider ~name:_ ~definition:_ ~input ~return_type:_ ~types:_ =
    match input with
    | `Assoc [ ("code", `String code) ] when contains_substring code "todo" ->
        Ok
          (`Assoc
             [
               ("action", `Assoc [ ("tag", `String "TEST") ]);
               ("accuracy", `Int 42);
               ("description", `String "needs stronger validation");
             ])
    | `Assoc [ ("code", `String _code) ] ->
        Ok
          (`Assoc
             [
               ("action", `Assoc [ ("tag", `String "RUN") ]);
               ("accuracy", `Int 96);
               ("description", `String "ready for execution");
             ])
    | _ -> Error "unexpected input"
  in
  let context =
    Camlflow.Runtime.Context.with_inline_agent_provider
      Camlflow.Runtime.Context.empty provider
  in
  let low_result =
    run_program ~context ~input:(`String "todo: add tests") program
  in
  Alcotest.(check string)
    "low accuracy branch" "retry-after-tests: needs stronger validation"
    (get_output_string low_result.output);
  let high_result = run_program ~context ~input:(`String "ship it") program in
  Alcotest.(check string)
    "high accuracy branch" "continue: ready for execution"
    (get_output_string high_result.output)

let test_inline_agent_typed_response_retries_recursively () =
  with_temp_dir "camlflow-model-retry-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
type action = TEST | RUN

type code_response = {
  action : action;
  accuracy : int;
  description : string;
  retry_hint : string option;
}

type review_outcome =
  | Approved of code_response
  | Exhausted of code_response

agent reviewer : code:string -> code_response =
  Agent.define ~system_prompt:"Review the submitted code."

let needs_retry (response : code_response) : bool =
  response.accuracy < 90 || is_some response.retry_hint

let retry_message (response : code_response) : string =
  unwrap_or response.retry_hint response.description

let rec review_until_ready (code : string) (attempt : int) : review_outcome =
  let* response = reviewer ~code:code in
  if needs_retry response then
    if attempt >= 2 then Exhausted response
    else
      review_until_ready
        (code ^ "\nRetry guidance: " ^ retry_message response)
        (attempt + 1)
  else Approved response

let summarize (outcome : review_outcome) : string =
  match outcome with
  | Approved response -> "approved: " ^ response.description
  | Exhausted response -> "exhausted: " ^ response.description

let main (code : string) : string =
  let outcome = review_until_ready code 0 in
  summarize outcome
|};
  let program = check_file main in
  let provider ~name:_ ~definition:_ ~input ~return_type:_ ~types:_ =
    match input with
    | `Assoc [ ("code", `String code) ]
      when contains_substring code "Retry guidance:" ->
        Ok
          (`Assoc
             [
               ("action", `Assoc [ ("tag", `String "RUN") ]);
               ("accuracy", `Int 96);
               ("description", `String "ready for execution");
               ("retry_hint", `Assoc [ ("tag", `String "None") ]);
             ])
    | `Assoc [ ("code", `String _code) ] ->
        Ok
          (`Assoc
             [
               ("action", `Assoc [ ("tag", `String "TEST") ]);
               ("accuracy", `Int 42);
               ("description", `String "needs stronger validation");
               ( "retry_hint",
                 `Assoc
                   [
                     ("tag", `String "Some");
                     ("value", `String "ask for test coverage");
                   ] );
             ])
    | _ -> Error "unexpected input"
  in
  let context =
    Camlflow.Runtime.Context.with_inline_agent_provider
      Camlflow.Runtime.Context.empty provider
  in
  let result = run_program ~context ~input:(`String "ship it") program in
  Alcotest.(check int) "retry step count" 2 result.steps_run;
  Alcotest.(check string)
    "retry output" "approved: ready for execution"
    (get_output_string result.output);
  let second_input =
    match List.nth_opt result.effect_steps 1 with
    | Some step -> (
        match step.Camlflow.Runtime.input with
        | `Assoc [ ("code", `String code) ] -> code
        | input ->
            Alcotest.failf "unexpected retry input payload: %s"
              (Yojson.Safe.to_string input))
    | None -> Alcotest.fail "missing retry effect step"
  in
  if
    not
      (contains_substring second_input "Retry guidance: ask for test coverage")
  then
    Alcotest.failf "missing retry guidance in second attempt: %s" second_input

let test_dev_workflow_example_awaits_clarification () =
  let main = repo_path "examples/dev-workflow/main.cml" in
  let skills_dir = repo_path "examples/dev-workflow/skills" in
  let input =
    Yojson.Safe.from_file
      (repo_path "examples/dev-workflow/input-approved.json")
  in
  let program = check_file main in
  let requirements_document =
    `Assoc
      [
        ("summary", `String "Feature flag dashboard for internal operators.");
        ( "user_stories",
          `List [ `String "As an operator, I can inspect rollout state." ] );
        ( "acceptance_criteria",
          `List [ `String "Dashboard lists flags and environments." ] );
        ("technical_requirements", `List [ `String "Read-only v1." ]);
        ( "data_requirements",
          `List [ `String "Expose flag metadata and audit history." ] );
        ( "performance_requirements",
          `List [ `String "Keep table responses fast." ] );
        ( "maintainability_requirements",
          `List [ `String "Reuse existing admin UI patterns." ] );
        ( "test_requirements",
          `List [ `String "Cover empty states and pagination." ] );
        ( "deployment_requirements",
          `List [ `String "Roll out behind an internal flag." ] );
      ]
  in
  let prompt_skill_provider ~name ~markdown:_ ~input:_ ~return_type:_ ~types:_ =
    match name with
    | "grill-me" ->
        Ok
          (`Assoc
             [
               ("readiness", tagged "NeedsUserAnswers");
               ("requirements_document", requirements_document);
               ( "open_questions",
                 `List
                   [
                     `String "Who can edit rollout metadata in later phases?";
                     `String
                       "What pagination size should the default table use?";
                   ] );
               ("approval_summary", `String "Not ready for approval yet.");
             ])
    | "caveman" -> Alcotest.fail "caveman should not run before clarification"
    | other -> Alcotest.failf "unexpected prompt skill %s" other
  in
  let inline_agent_provider ~name ~definition:_ ~input:_ ~return_type:_ ~types:_
      =
    Alcotest.failf "inline agent %s should not run before clarification" name
  in
  let context =
    Camlflow.Runtime.Context.empty |> fun context ->
    Camlflow.Runtime.Context.with_skills_directory context skills_dir
    |> fun context ->
    Camlflow.Runtime.Context.with_prompt_skill_provider context
      prompt_skill_provider
    |> fun context ->
    Camlflow.Runtime.Context.with_inline_agent_provider context
      inline_agent_provider
  in
  let result = run_program ~context ~input program in
  Alcotest.(check int) "clarification step count" 1 result.steps_run;
  Alcotest.(check string)
    "clarification step kind" "local-skill"
    (List.hd result.effect_steps).step_kind;
  let output =
    match result.output with
    | Some json -> json
    | None -> Alcotest.fail "expected output"
  in
  expect_string_field "tag" "NeedsClarification" output;
  let packet = expect_assoc_field "value" output in
  expect_string_field "next_step"
    "Answer the open questions and rerun the harness." packet;
  match expect_assoc_field "open_questions" packet with
  | `List [ `String first; `String second ] ->
      Alcotest.(check string)
        "first clarification question"
        "Who can edit rollout metadata in later phases?" first;
      Alcotest.(check string)
        "second clarification question"
        "What pagination size should the default table use?" second
  | other ->
      Alcotest.failf "unexpected open_questions payload: %s"
        (Yojson.Safe.to_string other)

let test_dev_workflow_example_waits_for_approval () =
  let main = repo_path "examples/dev-workflow/main.cml" in
  let skills_dir = repo_path "examples/dev-workflow/skills" in
  let input =
    Yojson.Safe.from_file (repo_path "examples/dev-workflow/input-pending.json")
  in
  let program = check_file main in
  let prompt_skill_provider ~name ~markdown:_ ~input:_ ~return_type:_ ~types:_ =
    match name with
    | "grill-me" ->
        Ok
          (`Assoc
             [
               ("readiness", tagged "ReadyForApproval");
               ( "requirements_document",
                 `Assoc
                   [
                     ("summary", `String "Approved-ready dashboard plan.");
                     ( "user_stories",
                       `List [ `String "Inspect flags by environment." ] );
                     ( "acceptance_criteria",
                       `List [ `String "Show audit history." ] );
                     ( "technical_requirements",
                       `List [ `String "Read-only scope." ] );
                     ( "data_requirements",
                       `List [ `String "Need flag and audit tables." ] );
                     ( "performance_requirements",
                       `List [ `String "Paginate large tables." ] );
                     ( "maintainability_requirements",
                       `List [ `String "Reuse admin table components." ] );
                     ( "test_requirements",
                       `List [ `String "Cover empty states." ] );
                     ( "deployment_requirements",
                       `List [ `String "Roll out to staff only." ] );
                   ] );
               ("open_questions", `List []);
               ("approval_summary", `String "Requirements ready for sign-off.");
             ])
    | "caveman" -> Alcotest.fail "caveman should not run before approval"
    | other -> Alcotest.failf "unexpected prompt skill %s" other
  in
  let inline_agent_provider ~name ~definition:_ ~input:_ ~return_type:_ ~types:_
      =
    Alcotest.failf "inline agent %s should not run before approval" name
  in
  let context =
    Camlflow.Runtime.Context.empty |> fun context ->
    Camlflow.Runtime.Context.with_skills_directory context skills_dir
    |> fun context ->
    Camlflow.Runtime.Context.with_prompt_skill_provider context
      prompt_skill_provider
    |> fun context ->
    Camlflow.Runtime.Context.with_inline_agent_provider context
      inline_agent_provider
  in
  let result = run_program ~context ~input program in
  Alcotest.(check int) "approval step count" 1 result.steps_run;
  let output =
    match result.output with
    | Some json -> json
    | None -> Alcotest.fail "expected output"
  in
  expect_string_field "tag" "NeedsApproval" output;
  let packet = expect_assoc_field "value" output in
  expect_string_field "approval_summary" "Requirements ready for sign-off."
    packet;
  expect_string_field "next_step"
    "Review the requirements document, approve it, and rerun with \
     ApprovalGranted."
    packet

let test_dev_workflow_example_completes_after_approval () =
  let main = repo_path "examples/dev-workflow/main.cml" in
  let skills_dir = repo_path "examples/dev-workflow/skills" in
  let input =
    Yojson.Safe.from_file
      (repo_path "examples/dev-workflow/input-approved.json")
  in
  let program = check_file main in
  let prompt_skill_provider ~name ~markdown:_ ~input:_ ~return_type:_ ~types:_ =
    match name with
    | "grill-me" ->
        Ok
          (`Assoc
             [
               ("readiness", tagged "ReadyForApproval");
               ( "requirements_document",
                 `Assoc
                   [
                     ( "summary",
                       `String
                         "Feature flag dashboard v1 for internal operators." );
                     ( "user_stories",
                       `List [ `String "Inspect flags by environment." ] );
                     ( "acceptance_criteria",
                       `List [ `String "Show audit history and search." ] );
                     ( "technical_requirements",
                       `List [ `String "Read-only dashboard." ] );
                     ( "data_requirements",
                       `List
                         [
                           `String
                             "Use feature flag metadata and audit records.";
                         ] );
                     ( "performance_requirements",
                       `List [ `String "Page large result sets." ] );
                     ( "maintainability_requirements",
                       `List
                         [ `String "Stay aligned with admin UI conventions." ]
                     );
                     ( "test_requirements",
                       `List [ `String "Add UI and API coverage." ] );
                     ( "deployment_requirements",
                       `List [ `String "Release behind an internal flag." ] );
                   ] );
               ("open_questions", `List []);
               ( "approval_summary",
                 `String "Plan covers scope, tests, and rollout constraints." );
             ])
    | "caveman" -> Ok (`String "flag dashboard plan, terse")
    | other -> Alcotest.failf "unexpected prompt skill %s" other
  in
  let inline_agent_provider ~name ~definition:_ ~input:_ ~return_type:_ ~types:_
      =
    match name with
    | "the_engineer" ->
        Ok
          (`Assoc
             [
               ("summary", `String "Implemented dashboard read path.");
               ( "implemented_files",
                 `List
                   [
                     `Assoc
                       [
                         ("path", `String "web/src/flags/dashboard.tsx");
                         ( "change_summary",
                           `String "Added searchable read-only dashboard." );
                       ];
                     `Assoc
                       [
                         ("path", `String "server/routes/flags.ts");
                         ( "change_summary",
                           `String "Added paginated flag listing endpoint." );
                       ];
                   ] );
               ( "technical_decisions",
                 `List
                   [
                     `Assoc
                       [
                         ("title", `String "Reuse admin table primitives");
                         ( "rationale",
                           `String "Keeps the first release maintainable." );
                       ];
                   ] );
               ( "added_dependencies",
                 `List
                   [
                     `Assoc
                       [
                         ("name", `String "none");
                         ( "reason",
                           `String "Used existing repo dependencies only." );
                       ];
                   ] );
             ])
    | "code_reviewer" ->
        Ok
          (`Assoc
             [
               ("status", tagged "ReviewApproved");
               ("summary", `String "Implementation matches the approved scope.");
               ( "issues_found",
                 `List
                   [
                     `Assoc
                       [
                         ("severity", tagged "Low");
                         ( "message",
                           `String "Consider adding rate-limit coverage later."
                         );
                         ( "file_hint",
                           tagged_value "Some"
                             (`String "server/routes/flags.ts") );
                       ];
                   ] );
               ( "suggestions",
                 `List
                   [
                     `String "Add screenshots to the rollout ticket.";
                     `String "Monitor slow queries after release.";
                   ] );
             ])
    | other -> Alcotest.failf "unexpected inline agent %s" other
  in
  let context =
    Camlflow.Runtime.Context.empty |> fun context ->
    Camlflow.Runtime.Context.with_skills_directory context skills_dir
    |> fun context ->
    Camlflow.Runtime.Context.with_prompt_skill_provider context
      prompt_skill_provider
    |> fun context ->
    Camlflow.Runtime.Context.with_inline_agent_provider context
      inline_agent_provider
  in
  let result = run_program ~context ~input program in
  Alcotest.(check int) "approved dev workflow steps" 4 result.steps_run;
  Alcotest.(check string)
    "first step kind" "local-skill" (List.nth result.effect_steps 0).step_kind;
  Alcotest.(check string)
    "second step name" "caveman" (List.nth result.effect_steps 1).step_name;
  Alcotest.(check string)
    "third step name" "the_engineer" (List.nth result.effect_steps 2).step_name;
  Alcotest.(check string)
    "fourth step name" "code_reviewer"
    (List.nth result.effect_steps 3).step_name;
  let output =
    match result.output with
    | Some json -> json
    | None -> Alcotest.fail "expected output"
  in
  expect_string_field "tag" "Completed" output;
  let report = expect_assoc_field "value" output in
  let review = expect_assoc_field "review_report" report in
  expect_string_field "summary" "Implementation matches the approved scope."
    review;
  let status = expect_assoc_field "status" review in
  expect_string_field "tag" "ReviewApproved" status;
  match expect_assoc_field "next_steps" report with
  | `List [ `String first; `String second; `String third ] ->
      Alcotest.(check string)
        "first next step"
        "Share the requirements, code package, and review report with the team."
        first;
      Alcotest.(check string)
        "second next step" "Merge or ship the approved change." second;
      Alcotest.(check string)
        "third next step" "Monitor validation signals after rollout." third
  | other ->
      Alcotest.failf "unexpected next_steps payload: %s"
        (Yojson.Safe.to_string other)

let test_invalid_provider_output_shape () =
  with_temp_dir "camlflow-provider-shape-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting
|};
  let program = check_file main in
  let context =
    Camlflow.Runtime.Context.with_agent_handler Camlflow.Runtime.Context.empty
      "greeter" (fun ~name:_ ~input:_ ~return_type:_ ~types:_ -> Ok (`Int 7))
  in
  expect_error_contains "invalid provider output shape"
    "provider output for agent greeter does not match declared return type \
     string"
    (Camlflow.Runtime.execute ~context ~input:(`String "Ada") program)

let test_provider_metadata_hooks () =
  with_temp_dir "camlflow-hooks-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  let skills_dir = Filename.concat dir "skills" in
  let caveman_dir = Filename.concat skills_dir "caveman" in
  let observed = ref [] in
  Unix.mkdir skills_dir 0o755;
  Unix.mkdir caveman_dir 0o755;
  write_file
    (Filename.concat caveman_dir "SKILL.md")
    "# Caveman\n\nHooked local skill.\n";
  write_file main
    {|
skill caveman : prompt:string -> string = Skill.bind "caveman"
agent reviewer : code:string -> string =
  Agent.define ~model:"stub" ~system_prompt:"review"

let main (prompt : string) : string =
  let* answer = caveman ~prompt:prompt in
  let* review = reviewer ~code:answer in
  review
|};
  let program = check_file main in
  let context =
    Camlflow.Runtime.Context.empty |> fun context ->
    Camlflow.Runtime.Context.with_skills_directory context skills_dir
    |> fun context ->
    Camlflow.Runtime.Context.with_prompt_skill_provider context
      (fun ~name:_ ~markdown:_ ~input:_ ~return_type:_ ~types:_ ->
        Ok (`String "prompt-output"))
    |> fun context ->
    Camlflow.Runtime.Context.with_inline_agent_provider context
      (fun ~name:_ ~definition:_ ~input:_ ~return_type:_ ~types:_ ->
        Ok (`String "inline-output"))
    |> fun context ->
    Camlflow.Runtime.Context.with_effect_observer context
      (fun invocation ~output:_ -> observed := invocation :: !observed)
  in
  let result = run_program ~context ~input:(`String "hello") program in
  Alcotest.(check string)
    "hooked output" "inline-output"
    (get_output_string result.output);
  match List.rev !observed with
  | [ skill_invocation; inline_invocation ] ->
      Alcotest.(check string)
        "skill observer kind" "local-prompt-skill"
        (match skill_invocation.Camlflow.Runtime.Context.invocation_kind with
        | Camlflow.Runtime.Context.Local_prompt_skill -> "local-prompt-skill"
        | _ -> "unexpected");
      Alcotest.(check bool)
        "skill markdown captured" true
        (Option.is_some skill_invocation.invocation_markdown);
      Alcotest.(check string)
        "inline observer kind" "inline-agent"
        (match inline_invocation.Camlflow.Runtime.Context.invocation_kind with
        | Camlflow.Runtime.Context.Inline_agent -> "inline-agent"
        | _ -> "unexpected");
      Alcotest.(check bool)
        "inline definition captured" true
        (Option.is_some inline_invocation.invocation_definition)
  | _ -> Alcotest.fail "expected exactly two observed invocations"

let test_cli_lsp_command () =
  let parsed = parse_cli [ "lsp" ] in
  (match parsed.Camlflow.Cli.command with
  | Camlflow.Cli.Lsp -> ()
  | _ -> Alcotest.fail "expected lsp command");
  match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error -> Alcotest.failf "lsp validate failed: %s" error

let test_lsp_definition_hover_and_rename () =
  with_temp_dir "camlflow-lsp-feature-" @@ fun dir ->
  let helpers = Filename.concat dir "helpers.cml" in
  let main = Filename.concat dir "main.cml" in
  let helpers_text =
    {|
type payload = { name : string }

let make (name : string) : payload =
  { name = name }
|}
  in
  let main_text =
    {|
let main (name : string) : string =
  let payload : Helpers.payload = Helpers.make name in
  payload.name
|}
  in
  write_file helpers helpers_text;
  write_file main main_text;
  let main_uri = Camlflow.Lsp_analysis.uri_of_path main in
  let helper_uri = Camlflow.Lsp_analysis.uri_of_path helpers in
  let lines = String.split_on_char '\n' main_text in
  let make_line = List.nth lines 2 in
  let payload_line = List.nth lines 3 in
  let make_character = substring_index make_line "Helpers.make" + 8 in
  let payload_character = substring_index payload_line "payload" + 1 in
  let messages =
    run_lsp_server_with_messages
      [
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
          "initialize" ~params:(`Assoc []);
        Camlflow.Rpc_protocol.request "textDocument/didOpen"
          ~params:
            (`Assoc
               [
                 ( "textDocument",
                   `Assoc
                     [
                       ("uri", `String main_uri);
                       ("version", `Int 1);
                       ("text", `String main_text);
                     ] );
               ]);
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
          "textDocument/definition"
          ~params:
            (`Assoc
               [
                 ("textDocument", `Assoc [ ("uri", `String main_uri) ]);
                 ( "position",
                   `Assoc
                     [ ("line", `Int 2); ("character", `Int make_character) ] );
               ]);
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 3)
          "textDocument/hover"
          ~params:
            (`Assoc
               [
                 ("textDocument", `Assoc [ ("uri", `String main_uri) ]);
                 ( "position",
                   `Assoc
                     [ ("line", `Int 2); ("character", `Int make_character) ] );
               ]);
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 4)
          "textDocument/prepareRename"
          ~params:
            (`Assoc
               [
                 ("textDocument", `Assoc [ ("uri", `String main_uri) ]);
                 ( "position",
                   `Assoc
                     [ ("line", `Int 3); ("character", `Int payload_character) ]
                 );
               ]);
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 5)
          "textDocument/rename"
          ~params:
            (`Assoc
               [
                 ("textDocument", `Assoc [ ("uri", `String main_uri) ]);
                 ( "position",
                   `Assoc
                     [ ("line", `Int 3); ("character", `Int payload_character) ]
                 );
                 ("newName", `String "result");
               ]);
      ]
  in
  let definition = find_rpc_response_by_id "2" messages in
  let definition_json =
    match definition.Camlflow.Rpc_protocol.response_result with
    | Some json -> json
    | None -> Alcotest.fail "missing definition result"
  in
  expect_string_field "uri" helper_uri definition_json;
  let hover = find_rpc_response_by_id "3" messages in
  let hover_json =
    match hover.Camlflow.Rpc_protocol.response_result with
    | Some json -> json
    | None -> Alcotest.fail "missing hover result"
  in
  let contents = expect_assoc_field "contents" hover_json in
  let hover_value =
    match expect_assoc_field "value" contents with
    | `String value -> value
    | other ->
        Alcotest.failf "unexpected hover payload %s"
          (Yojson.Safe.to_string other)
  in
  Alcotest.(check bool) "hover non-empty" true (String.length hover_value > 0);
  let prepare = find_rpc_response_by_id "4" messages in
  let prepare_json =
    match prepare.Camlflow.Rpc_protocol.response_result with
    | Some json -> json
    | None -> Alcotest.fail "missing prepareRename result"
  in
  expect_string_field "placeholder" "payload" prepare_json;
  let rename = find_rpc_response_by_id "5" messages in
  let rename_json =
    match rename.Camlflow.Rpc_protocol.response_result with
    | Some json -> json
    | None -> Alcotest.fail "missing rename result"
  in
  match expect_assoc_field "changes" rename_json with
  | `Assoc changes -> (
      match List.assoc_opt main_uri changes with
      | Some (`List edits) ->
          Alcotest.(check int) "rename edit count" 2 (List.length edits);
          List.iter
            (fun edit -> expect_string_field "newText" "result" edit)
            edits
      | _ -> Alcotest.fail "rename did not include main file edits")
  | other ->
      Alcotest.failf "unexpected rename payload %s"
        (Yojson.Safe.to_string other)

let test_lsp_prepare_rename_uses_occurrence_range_for_qualified_symbol () =
  with_temp_dir "camlflow-lsp-rename-qualified-" @@ fun dir ->
  let helpers = Filename.concat dir "helpers.cml" in
  let main = Filename.concat dir "main.cml" in
  let helpers_text =
    {|
type payload = { name : string }

let make (name : string) : payload =
  { name = name }
|}
  in
  let main_text =
    {|
let main (name : string) : Helpers.payload =
  Helpers.make name
|}
  in
  write_file helpers helpers_text;
  write_file main main_text;
  let main_uri = Camlflow.Lsp_analysis.uri_of_path main in
  let helper_uri = Camlflow.Lsp_analysis.uri_of_path helpers in
  let lines = String.split_on_char '\n' main_text in
  let make_line = List.nth lines 2 in
  let make_start =
    substring_index make_line "Helpers.make" + String.length "Helpers."
  in
  let make_character = make_start + 1 in
  let messages =
    run_lsp_server_with_messages
      [
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
          "initialize" ~params:(`Assoc []);
        Camlflow.Rpc_protocol.request "textDocument/didOpen"
          ~params:
            (`Assoc
               [
                 ( "textDocument",
                   `Assoc
                     [
                       ("uri", `String main_uri);
                       ("version", `Int 1);
                       ("text", `String main_text);
                     ] );
               ]);
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
          "textDocument/prepareRename"
          ~params:
            (`Assoc
               [
                 ("textDocument", `Assoc [ ("uri", `String main_uri) ]);
                 ( "position",
                   `Assoc
                     [ ("line", `Int 2); ("character", `Int make_character) ] );
               ]);
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 3)
          "textDocument/rename"
          ~params:
            (`Assoc
               [
                 ("textDocument", `Assoc [ ("uri", `String main_uri) ]);
                 ( "position",
                   `Assoc
                     [ ("line", `Int 2); ("character", `Int make_character) ] );
                 ("newName", `String "build");
               ]);
      ]
  in
  let prepare = find_rpc_response_by_id "2" messages in
  let prepare_json =
    match prepare.Camlflow.Rpc_protocol.response_result with
    | Some json -> json
    | None -> Alcotest.fail "missing prepareRename result"
  in
  expect_string_field "placeholder" "make" prepare_json;
  let prepare_range = expect_assoc_field "range" prepare_json in
  let prepare_start = expect_assoc_field "start" prepare_range in
  let prepare_end = expect_assoc_field "end" prepare_range in
  expect_int_field "line" 2 prepare_start;
  expect_int_field "character" make_start prepare_start;
  expect_int_field "line" 2 prepare_end;
  expect_int_field "character" (make_start + String.length "make") prepare_end;
  let rename = find_rpc_response_by_id "3" messages in
  let rename_json =
    match rename.Camlflow.Rpc_protocol.response_result with
    | Some json -> json
    | None -> Alcotest.fail "missing rename result"
  in
  match expect_assoc_field "changes" rename_json with
  | `Assoc changes -> (
      match
        (List.assoc_opt main_uri changes, List.assoc_opt helper_uri changes)
      with
      | Some (`List [ main_edit ]), Some (`List [ helper_edit ]) ->
          expect_string_field "newText" "build" main_edit;
          expect_string_field "newText" "build" helper_edit;
          let main_range = expect_assoc_field "range" main_edit in
          let main_start = expect_assoc_field "start" main_range in
          let main_end = expect_assoc_field "end" main_range in
          expect_int_field "line" 2 main_start;
          expect_int_field "character" make_start main_start;
          expect_int_field "line" 2 main_end;
          expect_int_field "character"
            (make_start + String.length "make")
            main_end
      | _ ->
          Alcotest.failf "unexpected rename changes payload %s"
            (Yojson.Safe.to_string (`Assoc changes)))
  | other ->
      Alcotest.failf "unexpected rename payload %s"
        (Yojson.Safe.to_string other)

let test_lsp_diagnostics_for_unbound_value () =
  with_temp_dir "camlflow-lsp-diagnostics-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  let main_text = {|
let main : string =
  missing
|} in
  write_file main main_text;
  let main_uri = Camlflow.Lsp_analysis.uri_of_path main in
  let messages =
    run_lsp_server_with_messages
      [
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
          "initialize" ~params:(`Assoc []);
        Camlflow.Rpc_protocol.request "textDocument/didOpen"
          ~params:
            (`Assoc
               [
                 ( "textDocument",
                   `Assoc
                     [
                       ("uri", `String main_uri);
                       ("version", `Int 1);
                       ("text", `String main_text);
                     ] );
               ]);
      ]
  in
  let diagnostics =
    find_rpc_request "textDocument/publishDiagnostics" messages
  in
  let params =
    match diagnostics.Camlflow.Rpc_protocol.request_params with
    | Some params -> params
    | None -> Alcotest.fail "missing diagnostics params"
  in
  expect_string_field "uri" main_uri params;
  match expect_assoc_field "diagnostics" params with
  | `List diagnostics ->
      Alcotest.(check bool) "diagnostics emitted" true (diagnostics <> []);
      let messages =
        List.map
          (fun diagnostic ->
            match expect_assoc_field "message" diagnostic with
            | `String value -> value
            | other ->
                Alcotest.failf "unexpected diagnostic payload %s"
                  (Yojson.Safe.to_string other))
          diagnostics
      in
      Alcotest.(check bool)
        "diagnostic mentions missing" true
        (List.exists
           (fun message -> contains_substring message "missing")
           messages)
  | other ->
      Alcotest.failf "unexpected diagnostics payload %s"
        (Yojson.Safe.to_string other)

let test_lsp_references_and_document_symbols () =
  with_temp_dir "camlflow-lsp-refs-symbols-" @@ fun dir ->
  let helpers = Filename.concat dir "helpers.cml" in
  let main = Filename.concat dir "main.cml" in
  let helpers_text =
    {|
type payload = { name : string }

let make (name : string) : payload =
  { name = name }
|}
  in
  let main_text =
    {|
open Helpers

let main (name : string) : string =
  let payload : payload = make name in
  payload.name
|}
  in
  write_file helpers helpers_text;
  write_file main main_text;
  let helper_uri = Camlflow.Lsp_analysis.uri_of_path helpers in
  let main_uri = Camlflow.Lsp_analysis.uri_of_path main in
  let lines = String.split_on_char '\n' main_text in
  let make_line = List.nth lines 4 in
  let make_character = substring_index make_line "make" + 1 in
  let messages =
    run_lsp_server_with_messages
      [
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
          "initialize" ~params:(`Assoc []);
        Camlflow.Rpc_protocol.request "textDocument/didOpen"
          ~params:
            (`Assoc
               [
                 ( "textDocument",
                   `Assoc
                     [
                       ("uri", `String main_uri);
                       ("version", `Int 1);
                       ("text", `String main_text);
                     ] );
               ]);
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
          "textDocument/references"
          ~params:
            (`Assoc
               [
                 ("textDocument", `Assoc [ ("uri", `String main_uri) ]);
                 ( "position",
                   `Assoc
                     [ ("line", `Int 4); ("character", `Int make_character) ] );
                 ("context", `Assoc [ ("includeDeclaration", `Bool false) ]);
               ]);
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 3)
          "textDocument/references"
          ~params:
            (`Assoc
               [
                 ("textDocument", `Assoc [ ("uri", `String main_uri) ]);
                 ( "position",
                   `Assoc
                     [ ("line", `Int 4); ("character", `Int make_character) ] );
                 ("context", `Assoc [ ("includeDeclaration", `Bool true) ]);
               ]);
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 4)
          "textDocument/documentSymbol"
          ~params:
            (`Assoc [ ("textDocument", `Assoc [ ("uri", `String helper_uri) ]) ]);
      ]
  in
  let references_without_declaration = find_rpc_response_by_id "2" messages in
  (match
     references_without_declaration.Camlflow.Rpc_protocol.response_result
   with
  | Some (`List [ reference ]) -> expect_string_field "uri" main_uri reference
  | Some other ->
      Alcotest.failf "unexpected references without declaration payload %s"
        (Yojson.Safe.to_string other)
  | None -> Alcotest.fail "missing references without declaration result");
  let references_with_declaration = find_rpc_response_by_id "3" messages in
  (match references_with_declaration.Camlflow.Rpc_protocol.response_result with
  | Some (`List references) ->
      Alcotest.(check int)
        "references with declaration count" 2 (List.length references);
      let uris =
        List.map
          (fun reference ->
            match expect_assoc_field "uri" reference with
            | `String uri -> uri
            | other ->
                Alcotest.failf "unexpected reference payload %s"
                  (Yojson.Safe.to_string other))
          references
      in
      Alcotest.(check bool)
        "includes helper declaration" true (List.mem helper_uri uris);
      Alcotest.(check bool)
        "includes main reference" true (List.mem main_uri uris)
  | Some other ->
      Alcotest.failf "unexpected references with declaration payload %s"
        (Yojson.Safe.to_string other)
  | None -> Alcotest.fail "missing references with declaration result");
  let document_symbols = find_rpc_response_by_id "4" messages in
  match document_symbols.Camlflow.Rpc_protocol.response_result with
  | Some (`List [ payload_symbol; make_symbol ]) ->
      expect_string_field "name" "payload" payload_symbol;
      expect_int_field "kind" 23 payload_symbol;
      (match expect_assoc_field "children" payload_symbol with
      | `List [ field_symbol ] ->
          expect_string_field "name" "name" field_symbol;
          expect_int_field "kind" 8 field_symbol
      | other ->
          Alcotest.failf "unexpected payload children %s"
            (Yojson.Safe.to_string other));
      expect_string_field "name" "make" make_symbol;
      expect_int_field "kind" 12 make_symbol
  | Some other ->
      Alcotest.failf "unexpected document symbol payload %s"
        (Yojson.Safe.to_string other)
  | None -> Alcotest.fail "missing document symbols result"

let test_lsp_did_change_republishes_diagnostics () =
  with_temp_dir "camlflow-lsp-did-change-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  let invalid_text = {|
let main : string =
  missing
|} in
  let fixed_text = {|
let main : string =
  "ok"
|} in
  write_file main fixed_text;
  let main_uri = Camlflow.Lsp_analysis.uri_of_path main in
  let messages =
    run_lsp_server_with_messages
      [
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
          "initialize" ~params:(`Assoc []);
        Camlflow.Rpc_protocol.request "textDocument/didOpen"
          ~params:
            (`Assoc
               [
                 ( "textDocument",
                   `Assoc
                     [
                       ("uri", `String main_uri);
                       ("version", `Int 1);
                       ("text", `String invalid_text);
                     ] );
               ]);
        Camlflow.Rpc_protocol.request "textDocument/didChange"
          ~params:
            (`Assoc
               [
                 ( "textDocument",
                   `Assoc [ ("uri", `String main_uri); ("version", `Int 2) ] );
                 ( "contentChanges",
                   `List [ `Assoc [ ("text", `String fixed_text) ] ] );
               ]);
      ]
  in
  match find_rpc_requests "textDocument/publishDiagnostics" messages with
  | [ first; second ] -> (
      let first_params =
        match first.Camlflow.Rpc_protocol.request_params with
        | Some params -> params
        | None -> Alcotest.fail "missing first diagnostics params"
      in
      let second_params =
        match second.Camlflow.Rpc_protocol.request_params with
        | Some params -> params
        | None -> Alcotest.fail "missing second diagnostics params"
      in
      expect_string_field "uri" main_uri first_params;
      expect_int_field "version" 1 first_params;
      (match expect_assoc_field "diagnostics" first_params with
      | `List diagnostics ->
          Alcotest.(check bool)
            "initial diagnostics emitted" true (diagnostics <> [])
      | other ->
          Alcotest.failf "unexpected first diagnostics payload %s"
            (Yojson.Safe.to_string other));
      expect_string_field "uri" main_uri second_params;
      expect_int_field "version" 2 second_params;
      match expect_assoc_field "diagnostics" second_params with
      | `List diagnostics ->
          Alcotest.(check int)
            "changed diagnostics cleared" 0 (List.length diagnostics)
      | other ->
          Alcotest.failf "unexpected second diagnostics payload %s"
            (Yojson.Safe.to_string other))
  | other ->
      Alcotest.failf "expected two publishDiagnostics notifications, got %d"
        (List.length other)

let test_lsp_did_close_reverts_to_on_disk_analysis () =
  with_temp_dir "camlflow-lsp-did-close-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  let invalid_text = {|
let main : string =
  missing
|} in
  let fixed_text = {|
let main : string =
  "ok"
|} in
  write_file main fixed_text;
  let main_uri = Camlflow.Lsp_analysis.uri_of_path main in
  let messages =
    run_lsp_server_with_messages
      [
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
          "initialize" ~params:(`Assoc []);
        Camlflow.Rpc_protocol.request "textDocument/didOpen"
          ~params:
            (`Assoc
               [
                 ( "textDocument",
                   `Assoc
                     [
                       ("uri", `String main_uri);
                       ("version", `Int 1);
                       ("text", `String invalid_text);
                     ] );
               ]);
        Camlflow.Rpc_protocol.request "textDocument/didClose"
          ~params:
            (`Assoc [ ("textDocument", `Assoc [ ("uri", `String main_uri) ]) ]);
      ]
  in
  match find_rpc_requests "textDocument/publishDiagnostics" messages with
  | [ first; second ] -> (
      let first_params =
        match first.Camlflow.Rpc_protocol.request_params with
        | Some params -> params
        | None -> Alcotest.fail "missing first diagnostics params"
      in
      let second_params =
        match second.Camlflow.Rpc_protocol.request_params with
        | Some params -> params
        | None -> Alcotest.fail "missing second diagnostics params"
      in
      expect_string_field "uri" main_uri first_params;
      expect_int_field "version" 1 first_params;
      (match expect_assoc_field "diagnostics" first_params with
      | `List diagnostics ->
          Alcotest.(check bool)
            "opened diagnostics emitted" true (diagnostics <> [])
      | other ->
          Alcotest.failf "unexpected first diagnostics payload %s"
            (Yojson.Safe.to_string other));
      expect_string_field "uri" main_uri second_params;
      Alcotest.(check bool)
        "closed diagnostics omit version" true
        (Option.is_none (assoc_field "version" second_params));
      match expect_assoc_field "diagnostics" second_params with
      | `List diagnostics ->
          Alcotest.(check int)
            "closed diagnostics cleared" 0 (List.length diagnostics)
      | other ->
          Alcotest.failf "unexpected second diagnostics payload %s"
            (Yojson.Safe.to_string other))
  | other ->
      Alcotest.failf "expected two publishDiagnostics notifications, got %d"
        (List.length other)

let test_lsp_rename_rejects_nonrenameable_field () =
  with_temp_dir "camlflow-lsp-rename-field-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  let main_text =
    {|
type payload = { name : string }

let main (name : string) : string =
  let payload : payload = { name = name } in
  payload.name
|}
  in
  write_file main main_text;
  let main_uri = Camlflow.Lsp_analysis.uri_of_path main in
  let lines = String.split_on_char '\n' main_text in
  let field_line = List.nth lines 5 in
  let field_character = substring_index field_line ".name" + 2 in
  let messages =
    run_lsp_server_with_messages
      [
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 1)
          "initialize" ~params:(`Assoc []);
        Camlflow.Rpc_protocol.request "textDocument/didOpen"
          ~params:
            (`Assoc
               [
                 ( "textDocument",
                   `Assoc
                     [
                       ("uri", `String main_uri);
                       ("version", `Int 1);
                       ("text", `String main_text);
                     ] );
               ]);
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 2)
          "textDocument/prepareRename"
          ~params:
            (`Assoc
               [
                 ("textDocument", `Assoc [ ("uri", `String main_uri) ]);
                 ( "position",
                   `Assoc
                     [ ("line", `Int 5); ("character", `Int field_character) ]
                 );
               ]);
        Camlflow.Rpc_protocol.request ~id:(Camlflow.Rpc_protocol.Int 3)
          "textDocument/rename"
          ~params:
            (`Assoc
               [
                 ("textDocument", `Assoc [ ("uri", `String main_uri) ]);
                 ( "position",
                   `Assoc
                     [ ("line", `Int 5); ("character", `Int field_character) ]
                 );
                 ("newName", `String "label");
               ]);
      ]
  in
  let prepare = find_rpc_response_by_id "2" messages in
  (match prepare.Camlflow.Rpc_protocol.response_result with
  | Some `Null -> ()
  | Some other ->
      Alcotest.failf "expected null prepareRename result, got %s"
        (Yojson.Safe.to_string other)
  | None -> Alcotest.fail "missing prepareRename result");
  let rename = find_rpc_response_by_id "3" messages in
  match rename.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int) "rename error code" (-32801) error.error_code;
      Alcotest.(check string)
        "rename error message" "symbol at position is not renameable"
        error.error_message
  | None -> Alcotest.fail "missing rename error"

let () =
  Alcotest.run "camlflow"
    [
      ( "mvp",
        [
          Alcotest.test_case "parse source" `Quick test_parse_source;
          Alcotest.test_case
            "multiline quoted strings preserve agent skill text" `Quick
            test_multiline_quoted_strings_preserve_agent_skill_text;
          Alcotest.test_case
            "return-annotated function without param annotations fails cleanly"
            `Quick
            test_return_annotated_function_without_param_annotations_fails_cleanly;
          Alcotest.test_case "cli help alias" `Quick test_cli_help_alias;
          Alcotest.test_case "cli help subcommand" `Quick
            test_cli_help_subcommand;
          Alcotest.test_case "cli missing flag value" `Quick
            test_cli_missing_flag_value;
          Alcotest.test_case "cli conflicting run inputs" `Quick
            test_cli_run_rejects_conflicting_inputs;
          Alcotest.test_case "cli check rejects run flags" `Quick
            test_cli_check_rejects_run_flags;
          Alcotest.test_case "cli completion command" `Quick
            test_cli_completion_command;
          Alcotest.test_case "cli completion script" `Quick
            test_cli_completion_script_mentions_commands;
          Alcotest.test_case "cli serve stdio parse" `Quick
            test_cli_serve_stdio_parse;
          Alcotest.test_case "cli serve requires stdio" `Quick
            test_cli_serve_requires_stdio;
          Alcotest.test_case "cli lsp command" `Quick test_cli_lsp_command;
          Alcotest.test_case "cli run provider flags parse" `Quick
            test_cli_run_provider_flags_parse;
          Alcotest.test_case "cli provider flags require provider" `Quick
            test_cli_provider_flags_require_provider;
          Alcotest.test_case "cli run opencode provider parse" `Quick
            test_cli_run_opencode_provider_parse;
          Alcotest.test_case "cli run claude-code provider parse" `Quick
            test_cli_run_claude_code_provider_parse;
          Alcotest.test_case "cli run claude-cli provider parse" `Quick
            test_cli_run_claude_cli_provider_parse;
          Alcotest.test_case "cli unknown provider rejected" `Quick
            test_cli_unknown_provider_rejected;
          Alcotest.test_case "cli invalid provider config rejected" `Quick
            test_cli_invalid_provider_config_rejected;
          Alcotest.test_case "cli check rejects provider flags" `Quick
            test_cli_check_rejects_provider_flags;
          Alcotest.test_case "project config loads nearest and resolves paths"
            `Quick test_project_config_loads_nearest_and_resolves_paths;
          Alcotest.test_case
            "project config load_file normalizes relative and absolute paths"
            `Quick
            test_project_config_load_file_normalizes_relative_and_absolute_paths;
          Alcotest.test_case
            "project config invalid enum includes path and field" `Quick
            test_project_config_invalid_enum_includes_path_and_field;
          Alcotest.test_case
            "project config wrong shape includes path and field" `Quick
            test_project_config_wrong_shape_includes_path_and_field;
          Alcotest.test_case
            "project config invalid provider config key rejected" `Quick
            test_project_config_invalid_provider_config_key_rejected;
          Alcotest.test_case "project config bad path includes path and field"
            `Quick test_project_config_bad_path_value_includes_path_and_field;
          Alcotest.test_case "project config unknown field rejected" `Quick
            test_project_config_unknown_field_rejected;
          Alcotest.test_case "cli run uses project config defaults" `Quick
            test_cli_run_uses_project_config_defaults;
          Alcotest.test_case "cli explicit run flags override project config"
            `Quick test_cli_explicit_run_flags_override_project_config;
          Alcotest.test_case "cli precedence is cli then config then defaults"
            `Quick test_cli_project_config_precedence_cli_config_defaults;
          Alcotest.test_case "cli explicit program overrides config program"
            `Quick test_cli_explicit_program_overrides_project_config_program;
          Alcotest.test_case
            "cli explicit provider setting overrides config setting" `Quick
            test_cli_explicit_provider_setting_overrides_project_config_setting;
          Alcotest.test_case "cli config-backed run keeps input validation"
            `Quick test_cli_project_config_keeps_run_input_validation;
          Alcotest.test_case
            "cli check uses project program without run-only defaults" `Quick
            test_cli_check_uses_project_program_without_run_only_defaults;
          Alcotest.test_case "rpc protocol request roundtrip" `Quick
            test_rpc_protocol_request_roundtrip;
          Alcotest.test_case "rpc protocol notification includes params" `Quick
            test_rpc_protocol_notification_includes_params;
          Alcotest.test_case "rpc stdio parse content length" `Quick
            test_rpc_stdio_parse_content_length;
          Alcotest.test_case "rpc server run request parse" `Quick
            test_rpc_server_run_request_parse;
          Alcotest.test_case "IR program JSON includes version" `Quick
            test_ir_program_json_includes_version;
          Alcotest.test_case "rpc server initialize advertises trace" `Quick
            test_rpc_server_initialize_advertises_trace;
          Alcotest.test_case "rpc server diagnostic payload" `Quick
            test_rpc_server_diagnostic_payload;
          Alcotest.test_case "rpc server progress payload" `Quick
            test_rpc_server_progress_payload;
          Alcotest.test_case "rpc server output chunk payload" `Quick
            test_rpc_server_output_chunk_payload;
          Alcotest.test_case "rpc server trace payload" `Quick
            test_rpc_server_trace_payload;
          Alcotest.test_case "rpc server end-to-end run" `Quick
            test_rpc_server_end_to_end_run;
          Alcotest.test_case "rpc server end-to-end progress notifications"
            `Quick test_rpc_server_end_to_end_progress_notifications;
          Alcotest.test_case "rpc server initialize notification preferences"
            `Quick test_rpc_server_initialize_notification_preferences;
          Alcotest.test_case "rpc server initialize can disable diagnostics"
            `Quick test_rpc_server_initialize_can_disable_diagnostics;
          Alcotest.test_case "rpc server end-to-end requires initialize" `Quick
            test_rpc_server_end_to_end_requires_initialize;
          Alcotest.test_case "rpc server compile includes IR version" `Quick
            test_rpc_server_compile_includes_ir_version;
          Alcotest.test_case "rpc server invalid request error" `Quick
            test_rpc_server_invalid_request_error;
          Alcotest.test_case "rpc server method not found error" `Quick
            test_rpc_server_method_not_found_error;
          Alcotest.test_case "lsp definition hover and rename" `Quick
            test_lsp_definition_hover_and_rename;
          Alcotest.test_case
            "lsp prepareRename uses occurrence range for qualified symbol"
            `Quick
            test_lsp_prepare_rename_uses_occurrence_range_for_qualified_symbol;
          Alcotest.test_case "lsp diagnostics for unbound value" `Quick
            test_lsp_diagnostics_for_unbound_value;
          Alcotest.test_case "lsp references and document symbols" `Quick
            test_lsp_references_and_document_symbols;
          Alcotest.test_case "lsp didChange republishes diagnostics" `Quick
            test_lsp_did_change_republishes_diagnostics;
          Alcotest.test_case "lsp didClose reverts to on-disk analysis" `Quick
            test_lsp_did_close_reverts_to_on_disk_analysis;
          Alcotest.test_case "lsp rename rejects nonrenameable field" `Quick
            test_lsp_rename_rejects_nonrenameable_field;
          Alcotest.test_case "rpc server check failure error" `Quick
            test_rpc_server_check_failure_error;
          Alcotest.test_case "rpc server compile failure error" `Quick
            test_rpc_server_compile_failure_error;
          Alcotest.test_case "rpc server run failure error" `Quick
            test_rpc_server_run_failure_error;
          Alcotest.test_case "rpc server effect error propagation" `Quick
            test_rpc_server_effect_error_propagation;
          Alcotest.test_case "rpc server cancellation returns request cancelled"
            `Quick test_rpc_server_cancellation_returns_request_cancelled;
          Alcotest.test_case
            "rpc server cancellation after effect response before run finish"
            `Quick
            test_rpc_server_cancellation_after_effect_response_before_run_finish;
          Alcotest.test_case
            "rpc server cancellation before next effect request" `Quick
            test_rpc_server_cancellation_before_next_effect_request;
          Alcotest.test_case "rpc server relays output chunk notifications"
            `Quick test_rpc_server_relays_output_chunk_notifications;
          Alcotest.test_case "provider schema for tuple and option" `Quick
            test_provider_schema_for_tuple_and_option;
          Alcotest.test_case "provider schema for named types" `Quick
            test_provider_schema_for_named_types;
          Alcotest.test_case "provider prompt for bound agent" `Quick
            test_provider_prompt_for_bound_agent;
          Alcotest.test_case "provider prompt for local skill" `Quick
            test_provider_prompt_for_local_skill;
          Alcotest.test_case "provider prompt for inline agent" `Quick
            test_provider_prompt_for_inline_agent;
          Alcotest.test_case
            "provider prompt derives structured response contract" `Quick
            test_provider_prompt_derives_structured_response_contract;
          Alcotest.test_case "effect request for local skill" `Quick
            test_effect_request_for_local_skill;
          Alcotest.test_case "effect request for inline agent" `Quick
            test_effect_request_for_inline_agent;
          Alcotest.test_case "effect bridge executes with effect request" `Quick
            test_effect_bridge_executes_with_effect_request;
          Alcotest.test_case "effect bridge validation error" `Quick
            test_effect_bridge_validation_error;
          Alcotest.test_case "codex build exec args" `Quick
            test_codex_build_exec_args;
          Alcotest.test_case "codex preflight validation" `Quick
            test_codex_preflight_validation;
          Alcotest.test_case "codex wrapped response schema" `Quick
            test_codex_wrapped_response_schema;
          Alcotest.test_case "provider wrapped response unwraps result" `Quick
            test_provider_wrapped_response_json_unwraps_result;
          Alcotest.test_case "provider wrapped response rejects extra fields"
            `Quick test_provider_wrapped_response_json_rejects_extra_fields;
          Alcotest.test_case
            "provider wrapped response rejects duplicate result fields" `Quick
            test_provider_wrapped_response_json_rejects_duplicate_result_fields;
          Alcotest.test_case "codex inline temperature fails fast" `Quick
            test_codex_inline_temperature_fails_fast;
          Alcotest.test_case "opencode build exec args" `Quick
            test_opencode_build_exec_args;
          Alcotest.test_case "opencode preflight validation" `Quick
            test_opencode_preflight_validation;
          Alcotest.test_case "opencode parse wrapped response" `Quick
            test_opencode_parse_wrapped_response;
          Alcotest.test_case
            "opencode parse wrapped response rejects extra fields" `Quick
            test_opencode_parse_wrapped_response_rejects_extra_fields;
          Alcotest.test_case "opencode error event message" `Quick
            test_opencode_error_event_message;
          Alcotest.test_case "opencode inline temperature fails fast" `Quick
            test_opencode_inline_temperature_fails_fast;
          Alcotest.test_case "claude-code build exec args" `Quick
            test_claude_code_build_exec_args;
          Alcotest.test_case "claude-code preflight validation" `Quick
            test_claude_code_preflight_validation;
          Alcotest.test_case "claude-code parse structured response" `Quick
            test_claude_code_parse_structured_response;
          Alcotest.test_case
            "claude-code parse structured response rejects extra fields" `Quick
            test_claude_code_parse_structured_response_rejects_extra_fields;
          Alcotest.test_case "claude-code inline temperature fails fast" `Quick
            test_claude_code_inline_temperature_fails_fast;
          Alcotest.test_case "claude-cli build request body" `Quick
            test_claude_cli_build_request_body;
          Alcotest.test_case "claude-cli preflight validation" `Quick
            test_claude_cli_preflight_validation;
          Alcotest.test_case "claude-cli parse wrapped response" `Quick
            test_claude_cli_parse_wrapped_response;
          Alcotest.test_case "claude-cli missing model fails fast" `Quick
            test_claude_cli_missing_model_fails_fast;
          Alcotest.test_case "wrong argument labels fail" `Quick
            test_wrong_argument_labels_fail;
          Alcotest.test_case "unsupported library/module call fails" `Quick
            test_unsupported_library_module_call_fails;
          Alcotest.test_case "zero-arg main runs" `Quick test_zero_arg_main_runs;
          Alcotest.test_case "check ignores unrelated broken files" `Quick
            test_check_ignores_unrelated_broken_files;
          Alcotest.test_case "check run and IR roundtrip" `Quick
            test_check_run_and_ir_roundtrip;
          Alcotest.test_case "local skill resolution" `Quick
            test_local_skill_resolution;
          Alcotest.test_case "unresolved open fails" `Quick
            test_unresolved_open_fails;
          Alcotest.test_case "non-exhaustive match fails" `Quick
            test_non_exhaustive_match_fails;
          Alcotest.test_case "wildcard match is exhaustive" `Quick
            test_wildcard_match_is_exhaustive;
          Alcotest.test_case "ctor then wildcard match is exhaustive" `Quick
            test_ctor_then_wildcard_match_is_exhaustive;
          Alcotest.test_case "effectful call requires let*" `Quick
            test_effectful_call_requires_let_star;
          Alcotest.test_case "unsaturated agent call fails" `Quick
            test_unsaturated_agent_call_fails;
          Alcotest.test_case "unsaturated skill call fails" `Quick
            test_unsaturated_skill_call_fails;
          Alcotest.test_case "qualified refs without open" `Quick
            test_qualified_refs_without_open;
          Alcotest.test_case "recursion and int builtins" `Quick
            test_recursion_and_int_builtins;
          Alcotest.test_case "option helper builtins" `Quick
            test_option_helper_builtins;
          Alcotest.test_case "bool match patterns" `Quick
            test_bool_match_patterns;
          Alcotest.test_case "float operators" `Quick test_float_operators;
          Alcotest.test_case "default provider hook for bound agent" `Quick
            test_default_provider_hook_for_bound_agent;
          Alcotest.test_case
            "inline agent typed response branches with if and match" `Quick
            test_inline_agent_typed_response_branches_with_if_and_match;
          Alcotest.test_case "inline agent typed response retries recursively"
            `Quick test_inline_agent_typed_response_retries_recursively;
          Alcotest.test_case "dev workflow example awaits clarification" `Quick
            test_dev_workflow_example_awaits_clarification;
          Alcotest.test_case "dev workflow example waits for approval" `Quick
            test_dev_workflow_example_waits_for_approval;
          Alcotest.test_case "dev workflow example completes after approval"
            `Quick test_dev_workflow_example_completes_after_approval;
          Alcotest.test_case "invalid provider output shape" `Quick
            test_invalid_provider_output_shape;
          Alcotest.test_case "provider metadata hooks" `Quick
            test_provider_metadata_hooks;
        ] );
    ]
