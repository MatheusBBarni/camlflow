let ( let* ) = Result.bind
let provider_name = Provider.Claude_cli
let default_max_tokens = 4096

let read_text_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error message ->
    Error (Printf.sprintf "failed to read file %s: %s" path message)

let write_text_file path content =
  try
    Out_channel.with_open_bin path (fun channel ->
        output_string channel content);
    Ok ()
  with Sys_error message ->
    Error (Printf.sprintf "failed to write file %s: %s" path message)

let remove_if_exists path = if Sys.file_exists path then Sys.remove path
let command_ok command = Sys.command command = 0

let api_key_present () =
  match Sys.getenv_opt "ANTHROPIC_API_KEY" with
  | Some value -> not (String.equal (String.trim value) "")
  | None -> false

let validate_preflight_status ~ant_available ~api_key_present =
  if not ant_available then
    Error
      "provider claude-cli is not available; install Anthropic CLI and ensure \
       `ant` is on PATH"
  else if not api_key_present then
    Error "provider claude-cli requires ANTHROPIC_API_KEY in environment"
  else Ok ()

let unsupported_cli_flags (settings : Provider.settings) =
  let flags =
    List.filter_map Fun.id
      [
        Option.map (Fun.const "--provider-profile") settings.provider_profile;
        (match settings.provider_configs with
        | [] -> None
        | _ -> Some "--provider-config");
        (if settings.sandbox = Provider.default_sandbox then None
         else Some "--sandbox");
        (match settings.allow_write_dirs with
        | [] -> None
        | _ -> Some "--allow-write-dir");
      ]
  in
  match flags with
  | [] -> Ok ()
  | flags ->
      Error
        (Printf.sprintf "provider claude-cli does not support %s"
           (String.concat ", " flags))

let preflight ~working_directory:_ ~settings =
  let* () = unsupported_cli_flags settings in
  validate_preflight_status
    ~ant_available:(command_ok "ant --version >/dev/null 2>&1")
    ~api_key_present:(api_key_present ())

let trace_start settings ~step ~kind ~name ~model =
  if settings.Provider.trace_provider then
    Printf.eprintf
      "provider[%d] start provider=claude-cli kind=%s name=%s model=%s\n%!" step
      kind name
      (match model with Some model -> model | None -> "(provider default)")

let trace_end settings ~step ~status ~elapsed =
  if settings.Provider.trace_provider then
    Printf.eprintf "provider[%d] %s elapsed=%.2fs\n%!" step status elapsed

let process_status_message = function
  | Unix.WEXITED code -> Printf.sprintf "exit code %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped by signal %d" signal

let claude_effort_value = function
  | Provider.Low -> "low"
  | Provider.Medium -> "medium"
  | Provider.High -> "high"
  | Provider.Max -> "max"

let build_exec_args () = [ "ant"; "messages"; "create"; "--format"; "json" ]

let build_request_body ~prompt ~schema ~model ~settings =
  let output_config_fields =
    [
      ("format", `Assoc [ ("type", `String "json_schema"); ("schema", schema) ]);
    ]
    @
    match settings.Provider.reasoning with
    | Some reasoning -> [ ("effort", `String (claude_effort_value reasoning)) ]
    | None -> []
  in
  `Assoc
    [
      ("model", `String model);
      ("max_tokens", `Int default_max_tokens);
      ( "messages",
        `List
          [ `Assoc [ ("role", `String "user"); ("content", `String prompt) ] ]
      );
      ("output_config", `Assoc output_config_fields);
    ]

let resolve_model request settings =
  match request.Effect_request.requested_model with
  | Some model -> Ok model
  | None -> (
      match settings.Provider.model with
      | Some model -> Ok model
      | None ->
          Error
            (Printf.sprintf
               "provider claude-cli requires --model or inline Agent.define \
                ~model for %s %s"
               (Effect_request.kind_to_string request.Effect_request.kind)
               request.Effect_request.name))

let assoc_string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | _ -> None

let extract_response_text ~trace_kind ~trace_name response_json =
  match response_json with
  | `Assoc fields -> (
      match List.assoc_opt "content" fields with
      | Some (`List items) -> (
          match
            List.find_map
              (function
                | `Assoc block_fields -> (
                    match assoc_string_field "type" block_fields with
                    | Some "text" -> assoc_string_field "text" block_fields
                    | _ -> None)
                | _ -> None)
              items
          with
          | Some text -> Ok text
          | None ->
              Error
                (Printf.sprintf
                   "claude-cli returned no text block for %s %s (output: %s)"
                   trace_kind trace_name
                   (Yojson.Safe.to_string response_json)))
      | _ ->
          Error
            (Printf.sprintf
               "claude-cli returned no content blocks for %s %s (output: %s)"
               trace_kind trace_name
               (Yojson.Safe.to_string response_json)))
  | _ ->
      Error
        (Printf.sprintf
           "claude-cli returned unexpected JSON payload for %s %s: %s"
           trace_kind trace_name
           (Yojson.Safe.to_string response_json))

let parse_wrapped_response ~trace_kind ~trace_name text =
  let* wrapped_json =
    try Ok (Yojson.Safe.from_string (String.trim text))
    with Yojson.Json_error message ->
      Error
        (Printf.sprintf
           "claude-cli returned invalid JSON for %s %s: %s (output: %s)"
           trace_kind trace_name message (String.trim text))
  in
  Provider_schema.unwrap_wrapped_response_json wrapped_json
  |> Result.map_error (fun error ->
      Printf.sprintf
        "claude-cli returned invalid model response for %s %s: %s (output: %s)"
        trace_kind trace_name error
        (Yojson.Safe.to_string wrapped_json))

let run_ant_exec ~request_body =
  let request_path =
    Filename.temp_file "camlflow-claude-cli-request-" ".json"
  in
  let stdout_path = Filename.temp_file "camlflow-claude-cli-stdout-" ".log" in
  let stderr_path = Filename.temp_file "camlflow-claude-cli-stderr-" ".log" in
  let temp_paths = [ request_path; stdout_path; stderr_path ] in
  Fun.protect
    ~finally:(fun () -> List.iter remove_if_exists temp_paths)
    (fun () ->
      let* () =
        write_text_file request_path (Yojson.Safe.to_string request_body)
      in
      let argv = Array.of_list (build_exec_args ()) in
      let request_fd = Unix.openfile request_path [ Unix.O_RDONLY ] 0 in
      let stdout_fd =
        Unix.openfile stdout_path
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
          0o644
      in
      let stderr_fd =
        Unix.openfile stderr_path
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
          0o644
      in
      let status =
        try
          let pid =
            Unix.create_process_env "ant" argv (Unix.environment ()) request_fd
              stdout_fd stderr_fd
          in
          Unix.close request_fd;
          Unix.close stdout_fd;
          Unix.close stderr_fd;
          snd (Unix.waitpid [] pid)
        with error ->
          Unix.close request_fd;
          Unix.close stdout_fd;
          Unix.close stderr_fd;
          raise error
      in
      let* stdout = read_text_file stdout_path in
      let* stderr = read_text_file stderr_path in
      match status with
      | Unix.WEXITED 0 -> Ok (stdout, stderr)
      | _ ->
          let stderr = String.trim stderr in
          let stdout = String.trim stdout in
          Error
            (Printf.sprintf "ant messages create failed with %s\n%s"
               (process_status_message status)
               (if not (String.equal stderr "") then stderr else stdout)))

let unsupported_settings_error (request : Effect_request.t) settings =
  Printf.sprintf
    "provider claude-cli does not support inline setting(s) %s for %s %s"
    (String.concat ", " settings)
    (match request.Effect_request.kind with
    | Runtime.Context.Inline_agent -> "agent"
    | Runtime.Context.Bound_agent -> "bound-agent"
    | Runtime.Context.Bound_skill -> "bound-skill"
    | Runtime.Context.Local_prompt_skill -> "local-prompt-skill")
    request.Effect_request.name

let execute_request ~working_directory:_ ~settings ~step
    (request : Effect_request.t) =
  let* wrapped_schema =
    Provider_schema.wrapped_response_schema request.Effect_request.output_schema
  in
  let* model = resolve_model request settings in
  let trace_kind = Effect_request.kind_to_string request.Effect_request.kind in
  let trace_name = request.Effect_request.name in
  trace_start settings ~step ~kind:trace_kind ~name:trace_name
    ~model:(Some model);
  let started_at = Unix.gettimeofday () in
  let result =
    let* () = unsupported_cli_flags settings in
    let* () =
      match request.Effect_request.unsupported_settings with
      | [] -> Ok ()
      | settings -> Error (unsupported_settings_error request settings)
    in
    let wrapped_prompt =
      String.concat "\n"
        [
          request.Effect_request.rendered_prompt;
          "";
          "Final response contract:";
          "Return a JSON object with exactly one field named result.";
          "The result field must contain the actual CamlFlow step output.";
          "Do not add any sibling fields.";
          Yojson.Safe.pretty_to_string wrapped_schema;
        ]
    in
    let request_body =
      build_request_body ~prompt:wrapped_prompt ~schema:wrapped_schema ~model
        ~settings
    in
    let* stdout, _stderr = run_ant_exec ~request_body in
    let* response_json =
      try Ok (Yojson.Safe.from_string (String.trim stdout))
      with Yojson.Json_error message ->
        Error
          (Printf.sprintf
             "claude-cli returned invalid JSON for %s %s: %s (output: %s)"
             trace_kind trace_name message (String.trim stdout))
    in
    let* text = extract_response_text ~trace_kind ~trace_name response_json in
    parse_wrapped_response ~trace_kind ~trace_name text
  in
  let elapsed = Unix.gettimeofday () -. started_at in
  trace_end settings ~step
    ~status:(match result with Ok _ -> "ok" | Error _ -> "error")
    ~elapsed;
  result

let execute_invocation ~working_directory ~settings ~step invocation =
  let* execution =
    Effect_bridge.execute ~step_index:step
      ~executor:(execute_request ~working_directory ~settings ~step)
      invocation
  in
  Ok execution.Effect_bridge.output_json

let build_runtime_context ~working_directory ~settings context =
  let step_counter = ref 0 in
  let run invocation =
    incr step_counter;
    execute_invocation ~working_directory ~settings ~step:!step_counter
      invocation
  in
  let context =
    Runtime.Context.with_default_provider context (fun invocation ->
        run invocation)
  in
  let context =
    Runtime.Context.with_prompt_skill_provider context
      (fun ~name ~markdown ~input ~return_type ~types ->
        run
          {
            Runtime.Context.invocation_kind = Runtime.Context.Local_prompt_skill;
            invocation_name = name;
            invocation_input = input;
            invocation_return_type = return_type;
            invocation_types = types;
            invocation_working_directory =
              context.Runtime.Context.working_directory;
            invocation_skills_directory =
              context.Runtime.Context.skills_directory;
            invocation_markdown = Some markdown;
            invocation_definition = None;
          })
  in
  let context =
    Runtime.Context.with_inline_agent_provider context
      (fun ~name ~definition ~input ~return_type ~types ->
        run
          {
            Runtime.Context.invocation_kind = Runtime.Context.Inline_agent;
            invocation_name = name;
            invocation_input = input;
            invocation_return_type = return_type;
            invocation_types = types;
            invocation_working_directory =
              context.Runtime.Context.working_directory;
            invocation_skills_directory =
              context.Runtime.Context.skills_directory;
            invocation_markdown = None;
            invocation_definition = Some definition;
          })
  in
  Ok context

let adapter : Provider.adapter =
  {
    provider_name;
    preflight;
    build_runtime_context =
      (fun ~working_directory ~settings context ->
        build_runtime_context ~working_directory ~settings context);
  }
