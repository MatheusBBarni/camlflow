let ( let* ) = Result.bind
let provider_name = Provider.Claude_code

let read_text_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error message ->
    Error (Printf.sprintf "failed to read file %s: %s" path message)

let remove_if_exists path = if Sys.file_exists path then Sys.remove path
let command_ok command = Sys.command command = 0

let resolve_path ~working_directory path =
  if Filename.is_relative path then Filename.concat working_directory path
  else path

let validate_preflight_status ~claude_available ~logged_in =
  if not claude_available then
    Error
      "provider claude-code is not available; install Claude Code and ensure \
       `claude` is on PATH"
  else if not logged_in then
    Error "provider claude-code requires login; run `claude auth login` first"
  else Ok ()

let unsupported_cli_flags (settings : Provider.settings) =
  let flags =
    List.filter_map Fun.id
      [
        Option.map (Fun.const "--provider-profile") settings.provider_profile;
        (match settings.provider_configs with
        | [] -> None
        | _ -> Some "--provider-config");
        (match settings.sandbox with
        | Provider.Read_only -> Some "--sandbox"
        | Provider.Workspace_write | Provider.Danger_full_access -> None);
      ]
  in
  match flags with
  | [] -> Ok ()
  | flags ->
      Error
        (Printf.sprintf "provider claude-code does not support %s"
           (String.concat ", " flags))

let preflight ~working_directory:_ ~settings =
  let* () = unsupported_cli_flags settings in
  validate_preflight_status
    ~claude_available:(command_ok "claude --version >/dev/null 2>&1")
    ~logged_in:(command_ok "claude auth status >/dev/null 2>&1")

let trace_start settings ~step ~kind ~name ~model =
  if settings.Provider.trace_provider then
    Printf.eprintf
      "provider[%d] start provider=claude-code kind=%s name=%s model=%s\n%!"
      step kind name
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

let build_exec_args ~working_directory ~settings ~model ~schema ~prompt =
  let base_args =
    [
      "claude";
      "-p";
      "--output-format";
      "json";
      "--json-schema";
      Yojson.Safe.to_string schema;
      "--cwd";
      working_directory;
      "--bare";
      "--no-session-persistence";
      "--dangerously-skip-permissions";
    ]
  in
  let model_args =
    match model with Some model -> [ "--model"; model ] | None -> []
  in
  let reasoning_args =
    match settings.Provider.reasoning with
    | Some reasoning -> [ "--effort"; claude_effort_value reasoning ]
    | None -> []
  in
  let add_dir_args =
    List.concat
      (List.map
         (fun dir -> [ "--add-dir"; resolve_path ~working_directory dir ])
         settings.Provider.allow_write_dirs)
  in
  base_args @ model_args @ reasoning_args @ add_dir_args @ [ prompt ]

let parse_structured_response ~trace_kind ~trace_name text =
  let* response_json =
    try Ok (Yojson.Safe.from_string (String.trim text))
    with Yojson.Json_error message ->
      Error
        (Printf.sprintf
           "claude-code returned invalid JSON for %s %s: %s (output: %s)"
           trace_kind trace_name message (String.trim text))
  in
  let* wrapped_json =
    match response_json with
    | `Assoc fields -> (
        match List.assoc_opt "structured_output" fields with
        | Some json -> Ok json
        | None ->
            Error
              (Printf.sprintf
                 "claude-code returned no structured_output for %s %s (output: \
                  %s)"
                 trace_kind trace_name
                 (Yojson.Safe.to_string response_json)))
    | _ ->
        Error
          (Printf.sprintf
             "claude-code returned unexpected JSON payload for %s %s: %s"
             trace_kind trace_name
             (Yojson.Safe.to_string response_json))
  in
  Provider_schema.unwrap_wrapped_response_json wrapped_json
  |> Result.map_error (fun error ->
      Printf.sprintf
        "claude-code returned invalid model response for %s %s: %s (output: %s)"
        trace_kind trace_name error
        (Yojson.Safe.to_string wrapped_json))

let run_claude_exec ~working_directory ~settings ~prompt ~schema ~model =
  let stdout_path = Filename.temp_file "camlflow-claude-code-stdout-" ".log" in
  let stderr_path = Filename.temp_file "camlflow-claude-code-stderr-" ".log" in
  let temp_paths = [ stdout_path; stderr_path ] in
  Fun.protect
    ~finally:(fun () -> List.iter remove_if_exists temp_paths)
    (fun () ->
      let argv =
        Array.of_list
          (build_exec_args ~working_directory ~settings ~model ~schema ~prompt)
      in
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
            Unix.create_process_env "claude" argv (Unix.environment ())
              Unix.stdin stdout_fd stderr_fd
          in
          Unix.close stdout_fd;
          Unix.close stderr_fd;
          snd (Unix.waitpid [] pid)
        with error ->
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
            (Printf.sprintf "claude -p failed with %s\n%s"
               (process_status_message status)
               (if not (String.equal stderr "") then stderr else stdout)))

let unsupported_settings_error (request : Effect_request.t) settings =
  Printf.sprintf
    "provider claude-code does not support inline setting(s) %s for %s %s"
    (String.concat ", " settings)
    (match request.Effect_request.kind with
    | Runtime.Context.Inline_agent -> "agent"
    | Runtime.Context.Bound_agent -> "bound-agent"
    | Runtime.Context.Bound_skill -> "bound-skill"
    | Runtime.Context.Local_prompt_skill -> "local-prompt-skill")
    request.Effect_request.name

let execute_request ~working_directory ~settings ~step
    (request : Effect_request.t) =
  let* wrapped_schema =
    Provider_schema.wrapped_response_schema request.Effect_request.output_schema
  in
  let model =
    match request.Effect_request.requested_model with
    | Some model -> Some model
    | None -> settings.Provider.model
  in
  let trace_kind = Effect_request.kind_to_string request.Effect_request.kind in
  let trace_name = request.Effect_request.name in
  trace_start settings ~step ~kind:trace_kind ~name:trace_name ~model;
  let started_at = Unix.gettimeofday () in
  let result =
    let* () = unsupported_cli_flags settings in
    let* () =
      match request.Effect_request.unsupported_settings with
      | [] -> Ok ()
      | settings -> Error (unsupported_settings_error request settings)
    in
    let effective_working_directory =
      match request.Effect_request.working_directory with
      | Some working_directory -> working_directory
      | None -> working_directory
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
    let* stdout, _stderr =
      run_claude_exec ~working_directory:effective_working_directory ~settings
        ~prompt:wrapped_prompt ~schema:wrapped_schema ~model
    in
    parse_structured_response ~trace_kind ~trace_name stdout
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
