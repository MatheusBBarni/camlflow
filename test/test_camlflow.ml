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
  if not (contains_substring script "parse check compile run completion") then
    Alcotest.failf "unexpected completion script: %s" script

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
      (fun ~definition:_ ~input:_ ~return_type:_ ~types:_ ->
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
          Alcotest.test_case "wrong argument labels fail" `Quick
            test_wrong_argument_labels_fail;
          Alcotest.test_case "unsupported library/module call fails" `Quick
            test_unsupported_library_module_call_fails;
          Alcotest.test_case "check run and IR roundtrip" `Quick
            test_check_run_and_ir_roundtrip;
          Alcotest.test_case "local skill resolution" `Quick
            test_local_skill_resolution;
          Alcotest.test_case "unresolved open fails" `Quick
            test_unresolved_open_fails;
          Alcotest.test_case "non-exhaustive match fails" `Quick
            test_non_exhaustive_match_fails;
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
