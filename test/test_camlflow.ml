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

let ensure_dir path =
  if Sys.file_exists path then ()
  else Unix.mkdir path 0o755

let write_file path content =
  Out_channel.with_open_bin path (fun channel -> output_string channel content)

let get_output_string = function
  | Some (`String value) -> value
  | Some json -> Alcotest.failf "expected JSON string output, got %s" (Yojson.Safe.to_string json)
  | None -> Alcotest.fail "expected output"

let get_output_int = function
  | Some (`Int value) -> value
  | Some json -> Alcotest.failf "expected JSON int output, got %s" (Yojson.Safe.to_string json)
  | None -> Alcotest.fail "expected output"

let get_output_float = function
  | Some (`Float value) -> value
  | Some (`Int value) -> float_of_int value
  | Some json -> Alcotest.failf "expected JSON float output, got %s" (Yojson.Safe.to_string json)
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
    ~finally:(fun () -> In_channel.close input; Out_channel.close output)
    (fun () ->
      match Camlflow.Rpc_server.run ~input ~output with
      | Ok () -> read_rpc_messages output_path
      | Error error -> Alcotest.failf "rpc server run failed: %s" error)

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
  | None -> Alcotest.failf "missing JSON field %s in %s" name (Yojson.Safe.to_string json)

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
        when String.equal request.Camlflow.Rpc_protocol.request_method method_ ->
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
        | Some response ->
            (match response.Camlflow.Rpc_protocol.response_id with
            | Some id -> String.equal (Camlflow.Rpc_protocol.string_of_id id) expected_id
            | None -> false)
        | None -> false)
      messages
  with
  | Some json ->
      (match rpc_response_message json with Some response -> response | None -> assert false)
  | None -> Alcotest.failf "rpc response %s not found" expected_id

let find_rpc_response_without_id messages =
  match
    List.find_opt
      (fun json ->
        match rpc_response_message json with
        | Some response -> Option.is_none response.Camlflow.Rpc_protocol.response_id
        | None -> false)
      messages
  with
  | Some json ->
      (match rpc_response_message json with Some response -> response | None -> assert false)
  | None -> Alcotest.fail "rpc response without id not found"

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
  match Camlflow.Effect_request.of_invocation ?step_index ?run_id invocation with
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
  write_file main
    "let main : string = {|\nagent hello\nskill bye\n|}\n";
  let program = check_file main in
  let result = run_program program in
  Alcotest.(check string) "quoted string preserved"
    "\nagent hello\nskill bye\n"
    (get_output_string result.output)

let test_return_annotated_function_without_param_annotations_fails_cleanly () =
  with_temp_dir "camlflow-return-annotation-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
let identity x : int = x
|};
  expect_error_contains
    "return annotation without parameter annotations"
    "function parameters require type annotations when using a return type annotation"
    (Camlflow.Typing.check_file ~include_paths:[] main)

let test_cli_help_alias () =
  let parsed = parse_cli [ "parse"; "--help" ] in
  Alcotest.(check string) "help command" "help"
    (Camlflow.Cli.command_name parsed.command);
  Alcotest.(check string) "help topic" "parse"
    (match parsed.help_topic with
    | Some command -> Camlflow.Cli.command_name command
    | None -> "none")

let test_cli_help_subcommand () =
  let parsed = parse_cli [ "help"; "run" ] in
  Alcotest.(check string) "help subcommand" "run"
    (match parsed.help_topic with
    | Some command -> Camlflow.Cli.command_name command
    | None -> "none")

let test_cli_missing_flag_value () =
  expect_error_contains "missing -o"
    "missing value for flag -o"
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
  Alcotest.(check string) "completion command" "completion"
    (Camlflow.Cli.command_name parsed.command);
  Alcotest.(check string) "completion shell" "bash"
    (match parsed.completion_shell with
    | Some shell -> Camlflow.Cli.shell_name shell
    | None -> "none");
  (match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error -> Alcotest.failf "completion validate failed: %s" error)

let test_cli_completion_script_mentions_commands () =
  let script = Camlflow.Cli.completion_script Camlflow.Cli.Bash in
  if not (contains_substring script "parse check compile run serve completion") then
    Alcotest.failf "unexpected completion script: %s" script;
  if not (contains_substring script "--provider --model --reasoning") then
    Alcotest.failf "provider flags missing from completion script: %s" script;
  if not (contains_substring script "codex opencode") then
    Alcotest.failf "provider completions missing adapter names: %s" script;
  if not (contains_substring script "--stdio") then
    Alcotest.failf "serve flags missing from completion script: %s" script

let test_cli_serve_stdio_parse () =
  let parsed = parse_cli [ "serve"; "--stdio" ] in
  Alcotest.(check string) "serve command" "serve"
    (Camlflow.Cli.command_name parsed.command);
  Alcotest.(check bool) "serve stdio flag" true parsed.options.rpc_stdio;
  (match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error -> Alcotest.failf "serve validate failed: %s" error)

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
  Alcotest.(check string) "provider" "codex"
    (match settings.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none");
  Alcotest.(check string) "model" "gpt-5.4-mini"
    (match settings.model with
    | Some model -> model
    | None -> "none");
  Alcotest.(check string) "reasoning" "high"
    (match settings.reasoning with
    | Some reasoning -> Camlflow.Provider.reasoning_to_string reasoning
    | None -> "none");
  Alcotest.(check string) "provider profile" "daily"
    (match settings.provider_profile with
    | Some profile -> profile
    | None -> "none");
  Alcotest.(check string) "provider config" "foo=bar"
    (match settings.provider_configs with
    | [ config ] -> Camlflow.Provider.config_to_string config
    | _ -> "unexpected");
  Alcotest.(check string) "sandbox" "read-only"
    (Camlflow.Provider.sandbox_to_string settings.sandbox);
  Alcotest.(check (list string)) "write dirs" [ "tmp" ]
    settings.allow_write_dirs;
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
  Alcotest.(check string) "provider" "opencode"
    (match settings.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none");
  Alcotest.(check string) "model" "openai/gpt-5.4-mini"
    (match settings.model with
    | Some model -> model
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
  write_file (Filename.concat dir Camlflow.Project_config.filename)
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
  Alcotest.(check (option string)) "program"
    (Some (Filename.concat dir "flows/main.cml"))
    config.Camlflow.Project_config.program;
  Alcotest.(check (option string)) "entry" (Some "workflow") config.entry;
  Alcotest.(check (option (list string))) "include paths"
    (Some [ dir; Filename.concat dir "lib" ])
    config.include_paths;
  Alcotest.(check (option string)) "skills dir"
    (Some (Filename.concat dir "skills"))
    config.skills_dir;
  Alcotest.(check string) "provider" "codex"
    (match config.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none");
  Alcotest.(check (option string)) "model" (Some "gpt-5.4-mini") config.model;
  Alcotest.(check string) "reasoning" "low"
    (match config.reasoning with
    | Some reasoning -> Camlflow.Provider.reasoning_to_string reasoning
    | None -> "none");
  Alcotest.(check (option string)) "provider profile" (Some "daily")
    config.provider_profile;
  Alcotest.(check (option string)) "provider config"
    (Some "foo=bar")
    (match config.provider_configs with
    | Some [ item ] -> Some (Camlflow.Provider.config_to_string item)
    | _ -> None);
  Alcotest.(check string) "sandbox" "read-only"
    (match config.sandbox with
    | Some sandbox -> Camlflow.Provider.sandbox_to_string sandbox
    | None -> "none");
  Alcotest.(check (option (list string))) "allow write dirs"
    (Some [ Filename.concat dir "tmp" ])
    config.allow_write_dirs;
  Alcotest.(check (option bool)) "trace provider" (Some true)
    config.trace_provider

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
      ~sandbox:Camlflow.Provider.Read_only
      ~allow_write_dirs:[ "/tmp/out" ] ~trace_provider:true ()
  in
  let parsed = Camlflow.Cli.apply_project_config parsed config in
  (match Camlflow.Cli.validate parsed with
  | Ok () -> ()
  | Error error -> Alcotest.failf "run validate with config failed: %s" error);
  Alcotest.(check (list string)) "config program applied" [ "/tmp/workflow.cml" ]
    parsed.positionals;
  Alcotest.(check string) "config entry applied" "workflow"
    parsed.options.entry;
  Alcotest.(check (list string)) "config include paths applied" [ "/tmp/lib" ]
    parsed.options.include_paths;
  Alcotest.(check (option string)) "config skills dir applied"
    (Some "/tmp/skills") parsed.options.skills_dir;
  Alcotest.(check string) "config provider applied" "codex"
    (match parsed.options.provider_options.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none");
  Alcotest.(check (option string)) "config model applied"
    (Some "gpt-5.4-mini") parsed.options.provider_options.model;
  Alcotest.(check string) "config reasoning applied" "low"
    (match parsed.options.provider_options.reasoning with
    | Some reasoning -> Camlflow.Provider.reasoning_to_string reasoning
    | None -> "none");
  Alcotest.(check (option string)) "config provider profile applied"
    (Some "daily") parsed.options.provider_options.provider_profile;
  Alcotest.(check (list string)) "config allow write dirs applied"
    [ "/tmp/out" ] parsed.options.provider_options.allow_write_dirs;
  Alcotest.(check bool) "config trace provider applied" true
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
      ~sandbox:Camlflow.Provider.Read_only
      ~allow_write_dirs:[ "/tmp/out" ] ~trace_provider:false ()
  in
  let parsed = Camlflow.Cli.apply_project_config parsed config in
  Alcotest.(check (list string)) "cli program preserved" [ "cli.cml" ]
    parsed.positionals;
  Alcotest.(check string) "cli entry preserved" "main" parsed.options.entry;
  Alcotest.(check (option string)) "cli skills preserved" (Some "cli-skills")
    parsed.options.skills_dir;
  Alcotest.(check string) "cli provider preserved" "opencode"
    (match parsed.options.provider_options.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none");
  Alcotest.(check (option string)) "cli model preserved"
    (Some "openai/gpt-5.4-mini") parsed.options.provider_options.model;
  Alcotest.(check string) "cli reasoning preserved" "high"
    (match parsed.options.provider_options.reasoning with
    | Some reasoning -> Camlflow.Provider.reasoning_to_string reasoning
    | None -> "none");
  Alcotest.(check (option string)) "cli provider profile preserved"
    (Some "cli-profile") parsed.options.provider_options.provider_profile;
  Alcotest.(check (option string)) "cli provider config preserved"
    (Some "alpha=beta")
    (match parsed.options.provider_options.provider_configs with
    | [ item ] -> Some (Camlflow.Provider.config_to_string item)
    | _ -> None);
  Alcotest.(check string) "cli sandbox preserved" "danger-full-access"
    (Camlflow.Provider.sandbox_to_string
       parsed.options.provider_options.sandbox);
  Alcotest.(check (list string)) "cli allow write dirs preserved" [ "cli-out" ]
    parsed.options.provider_options.allow_write_dirs;
  Alcotest.(check bool) "cli trace provider preserved" true
    parsed.options.provider_options.trace_provider

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
  Alcotest.(check (list string)) "check config program applied"
    [ "/tmp/workflow.cml" ] parsed.positionals;
  Alcotest.(check (list string)) "check include paths applied" [ "/tmp/lib" ]
    parsed.options.include_paths;
  Alcotest.(check string) "check entry unchanged" "main" parsed.options.entry;
  Alcotest.(check (option string)) "check skills ignored" None
    parsed.options.skills_dir;
  Alcotest.(check string) "check provider ignored" "none"
    (match parsed.options.provider_options.provider with
    | Some provider -> Camlflow.Provider.name_to_string provider
    | None -> "none")

let test_rpc_protocol_request_roundtrip () =
  let json =
    Camlflow.Rpc_protocol.request
      ~id:(Camlflow.Rpc_protocol.String "1") ~params:(`Assoc [ ("x", `Int 1) ])
      "camlflow/check"
  in
  match Camlflow.Rpc_protocol.request_of_yojson json with
  | Ok request ->
      Alcotest.(check string) "rpc method" "camlflow/check"
        request.Camlflow.Rpc_protocol.request_method;
      Alcotest.(check string) "rpc id" "1"
        (match request.request_id with
        | Some id -> Camlflow.Rpc_protocol.string_of_id id
        | None -> "none")
  | Error error -> Alcotest.failf "rpc request parse failed: %s" error

let test_rpc_protocol_notification_includes_params () =
  let json =
    Camlflow.Rpc_protocol.request ~params:(`Assoc [ ("event", `String "run-start") ])
      "camlflow/trace"
  in
  match Camlflow.Rpc_protocol.request_of_yojson json with
  | Ok request ->
      Alcotest.(check string) "rpc notification method" "camlflow/trace"
        request.Camlflow.Rpc_protocol.request_method;
      Alcotest.(check bool) "rpc notification params present" true
        (Option.is_some request.request_params)
  | Error error -> Alcotest.failf "rpc notification parse failed: %s" error

let test_rpc_stdio_parse_content_length () =
  match
    Camlflow.Rpc_stdio.parse_content_length
      [ "Content-Type: application/vscode-jsonrpc; charset=utf-8"; "Content-Length: 17" ]
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
      Alcotest.(check string) "run path" "examples/basic/main.cml"
        request.Camlflow.Rpc_server.run_program.program_path;
      Alcotest.(check (list string)) "run include paths" [ "lib" ]
        request.run_program.program_include_paths;
      Alcotest.(check (option string)) "run skills dir" (Some "skills")
        request.run_program.program_skills_dir;
      Alcotest.(check string) "run entry" "main" request.run_entry;
      Alcotest.(check bool) "run input present" true
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
  (match expect_assoc_field "capabilities" json with
  | `Assoc fields ->
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
      (match List.assoc_opt "cancelRequest" fields with
      | Some (`Bool true) -> ()
      | other ->
          Alcotest.failf "expected cancelRequest capability, got %s"
            (match other with
            | Some json -> Yojson.Safe.to_string json
            | None -> "null"))
  | other ->
      Alcotest.failf "expected capabilities object, got %s"
        (Yojson.Safe.to_string other))

let test_rpc_server_diagnostic_payload () =
  let request = build_effect_request ~step_index:2 ~run_id:"run-1" (make_invocation ~name:"greeter" ()) in
  let json =
    Camlflow.Rpc_server.diagnostic_payload ~run_id:"run-1" ~step:2
      ~method_:"camlflow/run" ~request "boom"
  in
  expect_string_field "severity" "error" json;
  expect_string_field "message" "boom" json;
  expect_string_field "method" "camlflow/run" json;
  (match expect_assoc_field "effect" json with
  | `Assoc fields ->
      (match List.assoc_opt "name" fields with
      | Some (`String name) ->
          Alcotest.(check string) "diagnostic effect name" "greeter" name
      | _ -> Alcotest.fail "missing diagnostic effect name")
  | other ->
      Alcotest.failf "expected effect object, got %s"
        (Yojson.Safe.to_string other))

let test_rpc_server_progress_payload () =
  let json =
    Camlflow.Rpc_server.progress_payload ~run_id:"run-1" ~step:2
      ~message:"Executing bound-agent greeter" ~completed_steps:1
      ~known_steps:3 ~cancellable:true "effect-start"
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
      ~stream_id:"stream-1" ~format:"text" ~delta:(`String "hello")
      ~done_:false ()
  in
  expect_string_field "runId" "run-1" json;
  expect_int_field "step" 2 json;
  expect_string_field "streamId" "stream-1" json;
  expect_string_field "format" "text" json;
  expect_string_field "delta" "hello" json;
  expect_bool_field "done" false json

let test_rpc_server_trace_payload () =
  let request = build_effect_request ~step_index:2 ~run_id:"run-1" (make_invocation ~name:"greeter" ()) in
  let json =
    Camlflow.Rpc_server.trace_payload ~run_id:"run-1" ~step:2 ~request
      ~details:(`Assoc [ ("status", `String "ok") ]) "effect-result"
  in
  expect_string_field "event" "effect-result" json;
  (match expect_assoc_field "effect" json with
  | `Assoc fields ->
      (match List.assoc_opt "kind" fields with
      | Some (`String kind) ->
          Alcotest.(check string) "trace kind" "bound-agent" kind
      | _ -> Alcotest.fail "missing trace effect kind");
      (match List.assoc_opt "name" fields with
      | Some (`String name) ->
          Alcotest.(check string) "trace name" "greeter" name
      | _ -> Alcotest.fail "missing trace effect name")
  | other ->
      Alcotest.failf "expected effect object, got %s"
        (Yojson.Safe.to_string other))

let test_rpc_server_end_to_end_run () =
  with_temp_dir "camlflow-rpc-e2e-" @@ fun dir ->
  let skills_dir = Filename.concat dir "skills" in
  let caveman_dir = Filename.concat skills_dir "caveman" in
  Unix.mkdir skills_dir 0o755;
  Unix.mkdir caveman_dir 0o755;
  write_file (Filename.concat caveman_dir "SKILL.md") "# Caveman\n\nReply tersely.\n";
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
  Alcotest.(check bool) "trace params present" true
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
  Alcotest.(check (list string)) "progress stages"
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
  (match run_finish.Camlflow.Rpc_protocol.request_params with
  | Some json ->
      expect_string_field "stage" "run-finish" json;
      expect_bool_field "cancellable" false json
  | None -> Alcotest.fail "missing run-finish progress params")

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
  Alcotest.(check int) "trace disabled" 0
    (List.length (find_rpc_requests "camlflow/trace" output));
  Alcotest.(check bool) "progress still enabled" true
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
  Alcotest.(check int) "diagnostics disabled" 0
    (List.length (find_rpc_requests "camlflow/diagnostic" output));
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int) "run failure still returned" (-32012)
        error.error_code
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
      Alcotest.(check string) "pre-init error message" "server not initialized"
        error.error_message
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
  | Some json ->
      expect_string_field "irVersion" Camlflow.Ir.ir_version json;
      (match expect_assoc_field "artifact" json with
      | `Assoc _ as artifact ->
          expect_string_field "version" Camlflow.Ir.ir_version artifact
      | other ->
          Alcotest.failf "expected artifact object, got %s"
            (Yojson.Safe.to_string other))
  | None -> Alcotest.fail "missing compile result"

let test_rpc_server_invalid_request_error () =
  let messages = [ `Assoc [ ("id", `Int 1); ("method", `String "initialize") ] ] in
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
      Alcotest.(check int) "invalid request error code" (-32600) error.error_code;
      Alcotest.(check string) "invalid request error message"
        "missing jsonrpc version" error.error_message
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
      Alcotest.(check int) "method not found error code" (-32601)
        error.error_code;
      Alcotest.(check string) "method not found error message"
        "method not found" error.error_message
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
  | Some (`Assoc fields as json) ->
      expect_string_field "method" "camlflow/check" json;
      (match List.assoc_opt "message" fields with
      | Some (`String message) ->
          Alcotest.(check bool) "check failure mentions missing program" true
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
      Alcotest.(check bool) "check failure response mentions missing program" true
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
  | Some (`Assoc fields as json) ->
      expect_string_field "method" "camlflow/compile" json;
      (match List.assoc_opt "message" fields with
      | Some (`String message) ->
          Alcotest.(check bool) "compile failure mentions missing program" true
            (contains_substring message "program path does not exist")
      | _ -> Alcotest.fail "missing compile failure message")
  | Some other ->
      Alcotest.failf "unexpected compile failure diagnostic params: %s"
        (Yojson.Safe.to_string other)
  | None -> Alcotest.fail "missing compile failure diagnostic params");
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int) "compile failure error code" (-32011)
        error.error_code;
      Alcotest.(check bool) "compile failure response mentions missing program"
        true (contains_substring error.error_message "program path does not exist")
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
  | Some (`Assoc fields as json) ->
      expect_string_field "method" "camlflow/run" json;
      (match List.assoc_opt "message" fields with
      | Some (`String message) ->
          Alcotest.(check bool) "run failure mentions missing input" true
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
      Alcotest.(check bool) "run failure response mentions missing input" true
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
      Camlflow.Rpc_protocol.error
        ~id:(Camlflow.Rpc_protocol.String "effect-1") ~code:(-32000)
        ~message:"model timeout" ();
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
  Alcotest.(check bool) "effect failure emits effect-error trace" true
    has_effect_error;
  let diagnostics = find_rpc_requests "camlflow/diagnostic" output in
  Alcotest.(check bool) "effect failure emits diagnostics" true
    (List.length diagnostics >= 2);
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int) "effect failure error code" (-32012)
        error.error_code;
      Alcotest.(check bool) "effect failure response mentions host timeout" true
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
        ~params:(`Assoc [ ("id", `Int 2) ]) "$/cancelRequest";
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
  Alcotest.(check bool) "cancellation emits run-cancelled trace" true
    has_run_cancelled;
  let diagnostics = find_rpc_requests "camlflow/diagnostic" output in
  let has_cancel_diagnostic =
    List.exists
      (fun request ->
        match request.Camlflow.Rpc_protocol.request_params with
        | Some (`Assoc fields) -> (
            match List.assoc_opt "message" fields with
            | Some (`String message) -> String.equal message "run cancelled by host"
            | _ -> false)
        | _ -> false)
      diagnostics
  in
  Alcotest.(check bool) "cancellation emits diagnostic" true has_cancel_diagnostic;
  let responses = List.filter_map rpc_response_message output in
  Alcotest.(check int) "late effect response is ignored" 2 (List.length responses);
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int) "cancellation error code" (-32800)
        error.error_code;
      Alcotest.(check string) "cancellation error message"
        "run cancelled by host" error.error_message
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
        ~params:(`Assoc [ ("id", `Int 2) ]) "$/cancelRequest";
    ]
  in
  let output = run_rpc_server_with_messages messages in
  Alcotest.(check int) "run-finish not emitted after late cancellation" 0
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
      Alcotest.(check int) "late cancellation error code" (-32800)
        error.error_code
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
        ~params:(`Assoc [ ("id", `Int 2) ]) "$/cancelRequest";
      Camlflow.Rpc_protocol.success (Camlflow.Rpc_protocol.String "effect-2")
        (`Assoc [ ("output", `String "me ada") ]);
    ]
  in
  let output = run_rpc_server_with_messages messages in
  let effect_requests = find_rpc_requests "camlflow/executeEffect" output in
  Alcotest.(check int) "second effect request is skipped after cancellation" 1
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
  Alcotest.(check bool) "cancellation emits run-cancelled progress" true
    has_run_cancelled_progress;
  let response = find_rpc_response_by_id "2" output in
  match response.Camlflow.Rpc_protocol.response_error with
  | Some error ->
      Alcotest.(check int) "between-effects cancellation error code" (-32800)
        error.error_code
  | None -> Alcotest.fail "missing between-effects cancellation response"

let test_rpc_server_relays_output_chunk_notifications () =
  with_temp_dir "camlflow-rpc-output-chunk-" @@ fun dir ->
  let input_path = Filename.concat dir "input.rpc" in
  let output_path = Filename.concat dir "output.rpc" in
  write_rpc_messages input_path [];
  let input = In_channel.open_bin input_path in
  let output_channel = Out_channel.open_bin output_path in
  Fun.protect
    ~finally:(fun () -> In_channel.close input; Out_channel.close output_channel)
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
      | Ok () ->
          Out_channel.flush output_channel;
          let output = read_rpc_messages output_path in
          let chunks = find_rpc_requests "camlflow/outputChunk" output in
          Alcotest.(check int) "relayed chunk count" 1 (List.length chunks);
          (match chunks with
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
  (match expect_assoc_field "prefixItems" schema with
  | `List [ first; second; third ] ->
      expect_string_field "type" "string" first;
      (match expect_assoc_field "oneOf" second with
      | `List [ none_case; some_case ] ->
          expect_string_field "type" "object" none_case;
          expect_string_field "const" "None"
            (expect_assoc_field "tag" (expect_assoc_field "properties" none_case));
          expect_string_field "type" "object" some_case;
          expect_string_field "const" "Some"
            (expect_assoc_field "tag" (expect_assoc_field "properties" some_case));
          expect_string_field "type" "integer"
            (expect_assoc_field "value" (expect_assoc_field "properties" some_case))
      | other ->
          Alcotest.failf "unexpected option schema: %s"
            (Yojson.Safe.to_string other));
      expect_string_field "type" "array" third;
      expect_string_field "type" "boolean" (expect_assoc_field "items" third)
  | other ->
      Alcotest.failf "unexpected tuple schema: %s" (Yojson.Safe.to_string other))

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
  let report_key = Camlflow.Syntax.Ast.string_of_qname report_decl.Camlflow.Ir.type_name in
  let review_key = Camlflow.Syntax.Ast.string_of_qname review_decl.Camlflow.Ir.type_name in
  let schema =
    schema_for_type ~types (Camlflow.Ir.TRecord report_decl.Camlflow.Ir.type_name)
  in
  expect_string_field "$schema" "https://json-schema.org/draft/2020-12/schema"
    schema;
  expect_string_field "$ref" ("#/$defs/" ^ report_key) schema;
  (match expect_assoc_field "$defs" schema with
  | `Assoc defs ->
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
        (expect_assoc_field "review" (expect_assoc_field "properties" report_schema));
      (match expect_assoc_field "oneOf" review_schema with
      | `List [ approved; needs_changes ] ->
          expect_string_field "const" "Approved"
            (expect_assoc_field "tag" (expect_assoc_field "properties" approved));
          expect_string_field "const" "NeedsChanges"
            (expect_assoc_field "tag"
               (expect_assoc_field "properties" needs_changes));
          expect_string_field "type" "string"
            (expect_assoc_field "value"
               (expect_assoc_field "properties" needs_changes))
      | other ->
          Alcotest.failf "unexpected variant schema: %s"
            (Yojson.Safe.to_string other))
  | other -> Alcotest.failf "unexpected defs payload: %s" (Yojson.Safe.to_string other))

let test_provider_prompt_for_bound_agent () =
  let rendered =
    render_prompt
      (make_invocation ~name:"greeter"
         ~input:(`Assoc [ ("name", `String "Ada") ])
         ~working_directory:"/workspace" ())
  in
  Alcotest.(check (option string)) "requested model" None
    rendered.requested_model;
  Alcotest.(check (list string)) "unsupported settings" []
    rendered.unsupported_settings;
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
  if not
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
  Alcotest.(check (option string)) "requested model" (Some "gpt-5.4-mini")
    rendered.requested_model;
  Alcotest.(check (list string)) "unsupported settings" [ "temperature" ]
    rendered.unsupported_settings;
  if not (contains_substring rendered.prompt "Inline agent system prompt:") then
    Alcotest.failf "missing inline system prompt section: %s" rendered.prompt;
  if not (contains_substring rendered.prompt "Review tersely") then
    Alcotest.failf "missing inline system prompt body: %s" rendered.prompt;
  if not (contains_substring rendered.prompt "Inline agent metadata (JSON):") then
    Alcotest.failf "missing inline metadata section: %s" rendered.prompt;
  if not (contains_substring rendered.prompt "\"tone\"") then
    Alcotest.failf "missing inline metadata payload: %s" rendered.prompt

let test_effect_request_for_local_skill () =
  let invocation =
    make_invocation ~kind:Camlflow.Runtime.Context.Local_prompt_skill
      ~name:"caveman" ~input:(`Assoc [ ("prompt", `String "hello") ])
      ~return_type:Camlflow.Ir.TString ~skills_directory:"/workspace/skills"
      ~markdown:"# Caveman\n\nReply tersely." ()
  in
  let request = build_effect_request ~step_index:7 ~run_id:"run-1" invocation in
  Alcotest.(check string) "kind" "local-prompt-skill"
    (Camlflow.Effect_request.kind_to_string request.kind);
  Alcotest.(check string) "name" "caveman" request.name;
  Alcotest.(check string) "declared return type" "string"
    request.declared_return_type;
  Alcotest.(check (option string)) "skills directory"
    (Some "/workspace/skills") request.skills_directory;
  Alcotest.(check (option string)) "skill markdown"
    (Some "# Caveman\n\nReply tersely.") request.skill_markdown;
  Alcotest.(check (option int)) "step index" (Some 7) request.step_index;
  Alcotest.(check (option string)) "run id" (Some "run-1") request.run_id;
  Alcotest.(check (option string)) "requested model" None request.requested_model;
  Alcotest.(check (list string)) "unsupported settings" []
    request.unsupported_settings;
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
    make_invocation ~kind:Camlflow.Runtime.Context.Inline_agent
      ~name:"reviewer" ~definition ~working_directory:"/workspace" ()
  in
  let request = build_effect_request invocation in
  Alcotest.(check string) "kind" "inline-agent"
    (Camlflow.Effect_request.kind_to_string request.kind);
  Alcotest.(check (option string)) "requested model" (Some "gpt-5.4-mini")
    request.requested_model;
  Alcotest.(check (list string)) "unsupported settings" [ "temperature" ]
    request.unsupported_settings;
  Alcotest.(check (option string)) "working directory" (Some "/workspace")
    request.working_directory;
  Alcotest.(check bool) "inline definition present" true
    (Option.is_some request.inline_definition);
  if not (contains_substring request.rendered_prompt "Review tersely") then
    Alcotest.failf "missing inline prompt in rendered request: %s"
      request.rendered_prompt;
  let json = Camlflow.Effect_request.to_yojson request in
  expect_string_field "kind" "inline-agent" json;
  expect_string_field "role" "agent" json;
  (match expect_assoc_field "inlineDefinition" json with
  | `Assoc _ -> ()
  | other ->
      Alcotest.failf "expected inlineDefinition object, got %s"
        (Yojson.Safe.to_string other))

let test_effect_bridge_executes_with_effect_request () =
  let invocation =
    make_invocation ~kind:Camlflow.Runtime.Context.Local_prompt_skill
      ~name:"caveman" ~input:(`Assoc [ ("prompt", `String "hello") ])
      ~skills_directory:"/workspace/skills"
      ~markdown:"# Caveman\n\nReply tersely." ()
  in
  let execution =
    run_effect_bridge ~step_index:3 ~run_id:"run-2"
      ~executor:(fun request ->
        Alcotest.(check string) "executor request name" "caveman" request.name;
        Alcotest.(check (option int)) "executor step" (Some 3)
          request.step_index;
        Alcotest.(check (option string)) "executor run id" (Some "run-2")
          request.run_id;
        Ok (`String request.name))
      invocation
  in
  Alcotest.(check string) "bridge request name" "caveman"
    execution.request.name;
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
  (match
     Camlflow.Providers_codex.validate_preflight_status ~codex_available:true
       ~logged_in:true
   with
  | Ok () -> ()
  | Error error -> Alcotest.failf "unexpected preflight error: %s" error)

let test_codex_wrapped_response_schema () =
  let wrapped =
    match
      Camlflow.Providers_codex.wrapped_response_schema
        (`Assoc [ ("$schema", `String "https://json-schema.org/draft/2020-12/schema"); ("type", `String "string") ])
    with
    | Ok schema -> schema
    | Error error -> Alcotest.failf "wrapped schema failed: %s" error
  in
  expect_string_field "type" "object" wrapped;
  expect_string_field "$schema" "https://json-schema.org/draft/2020-12/schema"
    wrapped;
  expect_string_field "type" "string"
    (expect_assoc_field "result" (expect_assoc_field "properties" wrapped))

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
    Camlflow.Runtime.Context.empty
    |> fun context -> Camlflow.Runtime.Context.with_working_directory context dir
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
  (match
     Camlflow.Providers_opencode.validate_preflight_status
       ~opencode_available:true
   with
  | Ok () -> ()
  | Error error -> Alcotest.failf "unexpected preflight error: %s" error)

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
  | Ok (`String value) -> Alcotest.(check string) "opencode parsed result" "hello" value
  | Ok json ->
      Alcotest.failf "unexpected opencode parsed JSON: %s"
        (Yojson.Safe.to_string json)
  | Error error -> Alcotest.failf "opencode parse failed: %s" error

let test_opencode_error_event_message () =
  let events =
    match
      Camlflow.Providers_opencode.json_line_events
        "{\"type\":\"error\",\"error\":{\"name\":\"UnknownError\",\"data\":{\"message\":\"Model not found\"}}}"
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
      Alcotest.(check bool) "opencode error message extracted" true
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
    Camlflow.Runtime.Context.empty
    |> fun context -> Camlflow.Runtime.Context.with_working_directory context dir
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
  write_file main
    {|
let main : int =
  List.length []
|};
  expect_error_contains "unsupported library/module call"
    "qualified library/module calls such as List.<value> are unsupported"
    (Camlflow.Typing.check_file main)

let test_zero_arg_main_runs () =
  with_temp_dir "camlflow-zero-arg-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  write_file main
    {|
let main : string =
  "ready"
|};
  let program = check_file main in
  let result = run_program program in
  Alcotest.(check int) "zero-arg steps" 0 result.steps_run;
  Alcotest.(check string) "zero-arg output" "ready"
    (get_output_string result.output)

let test_check_ignores_unrelated_broken_files () =
  with_temp_dir "camlflow-ignore-broken-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  let broken = Filename.concat dir "broken.cml" in
  write_file main "let main : int = 1\n";
  write_file broken "let broken =\n";
  let program = check_file main in
  let result = run_program program in
  Alcotest.(check int) "unrelated broken file ignored" 1
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
  Alcotest.(check string) "roundtrip output" "!" (get_output_string result.output)

let test_local_skill_resolution () =
  with_temp_dir "camlflow-skill-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  let skills_dir = Filename.concat dir "skills" in
  let caveman_dir = Filename.concat skills_dir "caveman" in
  Unix.mkdir skills_dir 0o755;
  Unix.mkdir caveman_dir 0o755;
  write_file (Filename.concat caveman_dir "SKILL.md") "# Caveman\n\nPrompt-backed test skill.\n";
  write_file main
    {|
skill caveman : prompt:string -> string = Skill.bind "caveman"

let main (prompt : string) : string =
  let* answer = caveman ~prompt:prompt in
  answer
|};
  let program = check_file main in
  let context =
    Camlflow.Runtime.Context.with_skills_directory Camlflow.Runtime.Context.empty
      skills_dir
  in
  let result = run_program ~context ~input:(`String "hello") program in
  Alcotest.(check int) "local skill step count" 1 result.steps_run;
  Alcotest.(check string) "local skill kind" "local-skill"
    (List.hd result.effect_steps).step_kind;
  Alcotest.(check string) "local skill output" ""
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
  Alcotest.(check int) "wildcard true branch" 1
    (get_output_int true_result.output);
  Alcotest.(check int) "wildcard false branch" 1
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
  Alcotest.(check int) "ctor wildcard true branch" 1
    (get_output_int true_result.output);
  Alcotest.(check int) "ctor wildcard false branch" 0
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
  Alcotest.(check string) "qualified module output" "Ada"
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
  write_file main
    {|
let main (x : float) : float =
  (x +. 1.5) *. 2.0
|};
  let program = check_file main in
  let result = run_program ~input:(`Float 2.0) program in
  Alcotest.(check (float 0.0001)) "float result" 7.0
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
    Camlflow.Runtime.Context.with_default_provider Camlflow.Runtime.Context.empty
      (fun invocation ->
        match invocation.Camlflow.Runtime.Context.invocation_kind with
        | Camlflow.Runtime.Context.Bound_agent ->
            Ok (`String invocation.invocation_name)
        | _ -> Error "unexpected invocation kind")
  in
  let result = run_program ~context ~input:(`String "Ada") program in
  Alcotest.(check string) "default provider result" "greeter"
    (get_output_string result.output)

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
      "greeter"
      (fun ~name:_ ~input:_ ~return_type:_ ~types:_ -> Ok (`Int 7))
  in
  expect_error_contains "invalid provider output shape"
    "provider output for agent greeter does not match declared return type string"
    (Camlflow.Runtime.execute ~context ~input:(`String "Ada") program)

let test_provider_metadata_hooks () =
  with_temp_dir "camlflow-hooks-" @@ fun dir ->
  let main = Filename.concat dir "main.cml" in
  let skills_dir = Filename.concat dir "skills" in
  let caveman_dir = Filename.concat skills_dir "caveman" in
  let observed = ref [] in
  Unix.mkdir skills_dir 0o755;
  Unix.mkdir caveman_dir 0o755;
  write_file (Filename.concat caveman_dir "SKILL.md") "# Caveman\n\nHooked local skill.\n";
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
    Camlflow.Runtime.Context.empty
    |> fun context ->
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
  Alcotest.(check string) "hooked output" "inline-output"
    (get_output_string result.output);
  match List.rev !observed with
  | [ skill_invocation; inline_invocation ] ->
      Alcotest.(check string) "skill observer kind" "local-prompt-skill"
        (match skill_invocation.Camlflow.Runtime.Context.invocation_kind with
        | Camlflow.Runtime.Context.Local_prompt_skill -> "local-prompt-skill"
        | _ -> "unexpected");
      Alcotest.(check bool) "skill markdown captured" true
        (Option.is_some skill_invocation.invocation_markdown);
      Alcotest.(check string) "inline observer kind" "inline-agent"
        (match inline_invocation.Camlflow.Runtime.Context.invocation_kind with
        | Camlflow.Runtime.Context.Inline_agent -> "inline-agent"
        | _ -> "unexpected");
      Alcotest.(check bool) "inline definition captured" true
        (Option.is_some inline_invocation.invocation_definition)
  | _ -> Alcotest.fail "expected exactly two observed invocations"

let () =
  Alcotest.run "camlflow"
    [
      ( "mvp",
        [
          Alcotest.test_case "parse source" `Quick test_parse_source;
          Alcotest.test_case "multiline quoted strings preserve agent skill text" `Quick
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
          Alcotest.test_case "cli run provider flags parse" `Quick
            test_cli_run_provider_flags_parse;
          Alcotest.test_case "cli provider flags require provider" `Quick
            test_cli_provider_flags_require_provider;
          Alcotest.test_case "cli run opencode provider parse" `Quick
            test_cli_run_opencode_provider_parse;
          Alcotest.test_case "cli unknown provider rejected" `Quick
            test_cli_unknown_provider_rejected;
          Alcotest.test_case "cli invalid provider config rejected" `Quick
            test_cli_invalid_provider_config_rejected;
          Alcotest.test_case "cli check rejects provider flags" `Quick
            test_cli_check_rejects_provider_flags;
          Alcotest.test_case "project config loads nearest and resolves paths"
            `Quick test_project_config_loads_nearest_and_resolves_paths;
          Alcotest.test_case "cli run uses project config defaults" `Quick
            test_cli_run_uses_project_config_defaults;
          Alcotest.test_case "cli explicit run flags override project config"
            `Quick test_cli_explicit_run_flags_override_project_config;
          Alcotest.test_case
            "cli check uses project program without run-only defaults"
            `Quick
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
          Alcotest.test_case "rpc server end-to-end progress notifications" `Quick
            test_rpc_server_end_to_end_progress_notifications;
          Alcotest.test_case "rpc server initialize notification preferences" `Quick
            test_rpc_server_initialize_notification_preferences;
          Alcotest.test_case "rpc server initialize can disable diagnostics" `Quick
            test_rpc_server_initialize_can_disable_diagnostics;
          Alcotest.test_case "rpc server end-to-end requires initialize" `Quick
            test_rpc_server_end_to_end_requires_initialize;
          Alcotest.test_case "rpc server compile includes IR version" `Quick
            test_rpc_server_compile_includes_ir_version;
          Alcotest.test_case "rpc server invalid request error" `Quick
            test_rpc_server_invalid_request_error;
          Alcotest.test_case "rpc server method not found error" `Quick
            test_rpc_server_method_not_found_error;
          Alcotest.test_case "rpc server check failure error" `Quick
            test_rpc_server_check_failure_error;
          Alcotest.test_case "rpc server compile failure error" `Quick
            test_rpc_server_compile_failure_error;
          Alcotest.test_case "rpc server run failure error" `Quick
            test_rpc_server_run_failure_error;
          Alcotest.test_case "rpc server effect error propagation" `Quick
            test_rpc_server_effect_error_propagation;
          Alcotest.test_case "rpc server cancellation returns request cancelled" `Quick
            test_rpc_server_cancellation_returns_request_cancelled;
          Alcotest.test_case
            "rpc server cancellation after effect response before run finish"
            `Quick
            test_rpc_server_cancellation_after_effect_response_before_run_finish;
          Alcotest.test_case "rpc server cancellation before next effect request" `Quick
            test_rpc_server_cancellation_before_next_effect_request;
          Alcotest.test_case "rpc server relays output chunk notifications" `Quick
            test_rpc_server_relays_output_chunk_notifications;
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
          Alcotest.test_case "codex inline temperature fails fast" `Quick
            test_codex_inline_temperature_fails_fast;
          Alcotest.test_case "opencode build exec args" `Quick
            test_opencode_build_exec_args;
          Alcotest.test_case "opencode preflight validation" `Quick
            test_opencode_preflight_validation;
          Alcotest.test_case "opencode parse wrapped response" `Quick
            test_opencode_parse_wrapped_response;
          Alcotest.test_case "opencode error event message" `Quick
            test_opencode_error_event_message;
          Alcotest.test_case "opencode inline temperature fails fast" `Quick
            test_opencode_inline_temperature_fails_fast;
          Alcotest.test_case "wrong argument labels fail" `Quick
            test_wrong_argument_labels_fail;
          Alcotest.test_case "unsupported library/module call fails" `Quick
            test_unsupported_library_module_call_fails;
          Alcotest.test_case "zero-arg main runs" `Quick
            test_zero_arg_main_runs;
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
          Alcotest.test_case "bool match patterns" `Quick
            test_bool_match_patterns;
          Alcotest.test_case "float operators" `Quick
            test_float_operators;
          Alcotest.test_case "default provider hook for bound agent" `Quick
            test_default_provider_hook_for_bound_agent;
          Alcotest.test_case "invalid provider output shape" `Quick
            test_invalid_provider_output_shape;
          Alcotest.test_case "provider metadata hooks" `Quick
            test_provider_metadata_hooks;
        ] );
    ]
