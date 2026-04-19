let ( let* ) = Result.bind
let provider_name = Provider.Opencode

let read_text_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error message ->
    Error (Printf.sprintf "failed to read file %s: %s" path message)

let remove_if_exists path = if Sys.file_exists path then Sys.remove path
let command_ok command = Sys.command command = 0

let validate_preflight_status ~opencode_available =
  if not opencode_available then
    Error
      "provider opencode is not available; install OpenCode CLI and ensure \
       `opencode` is on PATH"
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
        (Printf.sprintf "provider opencode does not support %s"
           (String.concat ", " flags))

let preflight ~working_directory:_ ~settings =
  let* () = unsupported_cli_flags settings in
  validate_preflight_status
    ~opencode_available:(command_ok "opencode --version >/dev/null 2>&1")

let trace_start settings ~step ~kind ~name ~model =
  if settings.Provider.trace_provider then
    Printf.eprintf
      "provider[%d] start provider=opencode kind=%s name=%s model=%s\n%!" step
      kind name
      (match model with Some model -> model | None -> "(provider default)")

let trace_end settings ~step ~status ~elapsed =
  if settings.Provider.trace_provider then
    Printf.eprintf "provider[%d] %s elapsed=%.2fs\n%!" step status elapsed

let process_status_message = function
  | Unix.WEXITED code -> Printf.sprintf "exit code %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped by signal %d" signal

let opencode_reasoning_value = function
  | Provider.Low -> "minimal"
  | Provider.Medium -> "medium"
  | Provider.High -> "high"
  | Provider.Max -> "max"

let build_exec_args ~working_directory ~settings ~model ~prompt =
  let base_args =
    [
      "opencode";
      "run";
      "--format";
      "json";
      "--pure";
      "--dir";
      working_directory;
      "--dangerously-skip-permissions";
    ]
  in
  let model_args =
    match model with Some model -> [ "--model"; model ] | None -> []
  in
  let reasoning_args =
    match settings.Provider.reasoning with
    | Some reasoning -> [ "--variant"; opencode_reasoning_value reasoning ]
    | None -> []
  in
  base_args @ model_args @ reasoning_args @ [ prompt ]

let json_line_events stdout =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | line :: rest when String.trim line = "" -> loop acc rest
    | line :: rest ->
        let* json =
          try Ok (Yojson.Safe.from_string line)
          with Yojson.Json_error message ->
            Error
              (Printf.sprintf
                 "opencode returned invalid JSON event: %s (line: %s)" message
                 line)
        in
        loop (json :: acc) rest
  in
  loop [] (String.split_on_char '\n' stdout)

let assoc_string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | _ -> None

let rec nested_message = function
  | `Assoc fields -> (
      match assoc_string_field "message" fields with
      | Some message -> Some message
      | None -> List.find_map (fun (_, value) -> nested_message value) fields)
  | `List items -> List.find_map nested_message items
  | _ -> None

let last_error_message events =
  List.rev events
  |> List.find_map (function
    | `Assoc fields -> (
        match assoc_string_field "type" fields with
        | Some "error" -> (
            match List.assoc_opt "error" fields with
            | Some error -> nested_message error
            | None -> nested_message (`Assoc fields))
        | _ -> None)
    | _ -> None)

let text_chunks events =
  List.filter_map
    (function
      | `Assoc fields -> (
          match assoc_string_field "type" fields with
          | Some "text" -> (
              match List.assoc_opt "part" fields with
              | Some (`Assoc part_fields) ->
                  assoc_string_field "text" part_fields
              | _ -> None)
          | _ -> None)
      | _ -> None)
    events

let combined_text_response events =
  match text_chunks events with
  | [] -> None
  | chunks -> Some (String.concat "" chunks)

let response_text_or_error ~trace_kind ~trace_name events =
  match last_error_message events with
  | Some message ->
      Error
        (Printf.sprintf "opencode returned error for %s %s: %s" trace_kind
           trace_name message)
  | None -> (
      match combined_text_response events with
      | Some text -> Ok text
      | None ->
          Error
            (Printf.sprintf "opencode returned no final text response for %s %s"
               trace_kind trace_name))

let parse_wrapped_response ~trace_kind ~trace_name text =
  let* wrapped_json =
    try Ok (Yojson.Safe.from_string (String.trim text))
    with Yojson.Json_error message ->
      Error
        (Printf.sprintf
           "opencode returned invalid JSON for %s %s: %s (output: %s)"
           trace_kind trace_name message (String.trim text))
  in
  Provider_schema.unwrap_wrapped_response_json wrapped_json
  |> Result.map_error (fun error ->
      Printf.sprintf
        "opencode returned invalid model response for %s %s: %s (output: %s)"
        trace_kind trace_name error
        (Yojson.Safe.to_string wrapped_json))

let run_opencode_exec ~working_directory ~settings ~prompt ~schema:_ ~model =
  let stdout_path = Filename.temp_file "camlflow-opencode-stdout-" ".log" in
  let stderr_path = Filename.temp_file "camlflow-opencode-stderr-" ".log" in
  let temp_paths = [ stdout_path; stderr_path ] in
  Fun.protect
    ~finally:(fun () -> List.iter remove_if_exists temp_paths)
    (fun () ->
      let argv =
        Array.of_list
          (build_exec_args ~working_directory ~settings ~model ~prompt)
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
            Unix.create_process_env "opencode" argv (Unix.environment ())
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
          let error_message =
            match json_line_events stdout with
            | Ok events -> last_error_message events
            | Error _ -> None
          in
          Error
            (Printf.sprintf "opencode run failed with %s\n%s"
               (process_status_message status)
               (match error_message with
               | Some message -> message
               | None ->
                   let stderr = String.trim stderr in
                   if String.equal stderr "" then String.trim stdout else stderr)))

let unsupported_settings_error (request : Effect_request.t) settings =
  Printf.sprintf
    "provider opencode does not support inline setting(s) %s for %s %s"
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
      run_opencode_exec ~working_directory:effective_working_directory ~settings
        ~prompt:wrapped_prompt ~schema:wrapped_schema ~model
    in
    let* events = json_line_events stdout in
    let* text = response_text_or_error ~trace_kind ~trace_name events in
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
