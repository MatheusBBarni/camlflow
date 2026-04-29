module Context = Runtime.Context

let ( let* ) = Result.bind
let protocol_version = "0.1.0"
let effect_method = "camlflow/executeEffect"
let trace_method = "camlflow/trace"
let diagnostic_method = "camlflow/diagnostic"
let progress_method = "camlflow/progress"
let output_chunk_method = "camlflow/outputChunk"
let cancel_method = "$/cancelRequest"
let request_cancelled_code = -32800
let cancellation_message = "run cancelled by host"

type active_run = {
  request_id : Rpc_protocol.id option;
  mutable run_id : string option;
  mutable current_step : int option;
  mutable completed_steps : int;
  mutable waiting_effect_id : Rpc_protocol.id option;
  mutable cancellation_requested : bool;
  mutable cancellation_emitted : bool;
}

type server = {
  input : in_channel;
  output : out_channel;
  mutable initialized : bool;
  mutable shutdown_requested : bool;
  mutable next_run : int;
  mutable active_run : active_run option;
  mutable pending_message : Yojson.Safe.t option;
  mutable trace_enabled : bool;
  mutable diagnostics_enabled : bool;
  mutable progress_enabled : bool;
}

type program_ref = {
  program_path : string;
  program_include_paths : string list;
  program_skills_dir : string option;
}

type run_request = {
  run_program : program_ref;
  run_entry : string;
  run_input : Yojson.Safe.t option;
}

type loop_control = Continue | Stop

type notification_preferences = {
  trace_enabled : bool;
  diagnostics_enabled : bool;
  progress_enabled : bool;
}

type output_chunk = {
  output_chunk_run_id : string option;
  output_chunk_step : int option;
  output_chunk_stream_id : string;
  output_chunk_format : string;
  output_chunk_delta : Yojson.Safe.t;
  output_chunk_done : bool;
}

type run_error = Run_failed of string | Run_cancelled of string

let id_matches left right =
  match (left, right) with
  | Rpc_protocol.Int left, Rpc_protocol.Int right -> left = right
  | Rpc_protocol.String left, Rpc_protocol.String right ->
      String.equal left right
  | _ -> false

let string_field fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error (Printf.sprintf "field %s must be a string" name)
  | None -> Error (Printf.sprintf "missing field %s" name)

let optional_string_field fields name =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (Printf.sprintf "field %s must be a string or null" name)

let optional_int_field fields name =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some _ -> Error (Printf.sprintf "field %s must be an int or null" name)

let string_list_field fields name =
  match List.assoc_opt name fields with
  | None -> Ok []
  | Some (`List items) ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | `String value :: rest -> loop (value :: acc) rest
        | _ -> Error (Printf.sprintf "field %s must be a list of strings" name)
      in
      loop [] items
  | Some _ -> Error (Printf.sprintf "field %s must be a list" name)

let program_ref_of_yojson = function
  | `Assoc fields ->
      let* program_path = string_field fields "path" in
      let* program_include_paths = string_list_field fields "includePaths" in
      let* program_skills_dir = optional_string_field fields "skillsDir" in
      Ok { program_path; program_include_paths; program_skills_dir }
  | _ -> Error "program must be a JSON object"

let run_request_of_yojson = function
  | `Assoc fields ->
      let* run_program =
        match List.assoc_opt "program" fields with
        | Some json -> program_ref_of_yojson json
        | None -> Error "missing field program"
      in
      let run_entry =
        match List.assoc_opt "entry" fields with
        | None -> Ok "main"
        | Some (`String value) -> Ok value
        | Some _ -> Error "field entry must be a string"
      in
      let* run_entry = run_entry in
      let run_input =
        match List.assoc_opt "input" fields with
        | None | Some `Null -> None
        | Some json -> Some json
      in
      Ok { run_program; run_entry; run_input }
  | _ -> Error "run params must be a JSON object"

let cancel_request_id_of_yojson = function
  | `Assoc fields -> (
      match List.assoc_opt "id" fields with
      | Some json -> Rpc_protocol.id_of_yojson json
      | None -> Error "missing field id")
  | _ -> Error "cancel params must be a JSON object"

let bool_field_with_default fields name default =
  match List.assoc_opt name fields with
  | None -> Ok default
  | Some (`Bool value) -> Ok value
  | Some _ -> Error (Printf.sprintf "field %s must be a bool" name)

let output_chunk_of_yojson = function
  | `Assoc fields ->
      let* output_chunk_run_id = optional_string_field fields "runId" in
      let* output_chunk_step = optional_int_field fields "step" in
      let* output_chunk_stream_id = string_field fields "streamId" in
      let* output_chunk_format = string_field fields "format" in
      let* output_chunk_delta =
        match List.assoc_opt "delta" fields with
        | Some json -> Ok json
        | None -> Error "missing field delta"
      in
      let* output_chunk_done =
        match List.assoc_opt "done" fields with
        | Some (`Bool value) -> Ok value
        | Some _ -> Error "field done must be a bool"
        | None -> Error "missing field done"
      in
      Ok
        {
          output_chunk_run_id;
          output_chunk_step;
          output_chunk_stream_id;
          output_chunk_format;
          output_chunk_delta;
          output_chunk_done;
        }
  | _ -> Error "output chunk params must be a JSON object"

let notification_preferences_of_yojson = function
  | `Assoc fields -> (
      match List.assoc_opt "notifications" fields with
      | None ->
          Ok
            {
              trace_enabled = true;
              diagnostics_enabled = true;
              progress_enabled = true;
            }
      | Some (`Assoc notification_fields) ->
          let* trace_enabled =
            bool_field_with_default notification_fields "trace" true
          in
          let* diagnostics_enabled =
            bool_field_with_default notification_fields "diagnostic" true
          in
          let* progress_enabled =
            bool_field_with_default notification_fields "progress" true
          in
          Ok { trace_enabled; diagnostics_enabled; progress_enabled }
      | Some _ -> Error "field notifications must be an object")
  | _ -> Error "initialize params must be a JSON object"

let ensure_file label path =
  if not (Sys.file_exists path) then
    Error (Printf.sprintf "%s does not exist: %s" label path)
  else if Sys.is_directory path then
    Error (Printf.sprintf "%s must be a file, got directory: %s" label path)
  else Ok ()

let read_text_file label path =
  let* () = ensure_file label path in
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error message ->
    Error (Printf.sprintf "failed to read %s %s: %s" label path message)

let load_program include_paths path =
  let* () = ensure_file "program path" path in
  if Filename.check_suffix path ".json" then
    let* source = read_text_file "JSON IR artifact" path in
    Ir.of_json_string source
    |> Result.map_error (fun error ->
        Printf.sprintf "failed to decode JSON IR artifact %s: %s" path error)
  else
    Typing.check_file ~include_paths path
    |> Result.map_error (fun error ->
        Printf.sprintf "failed to type-check source program %s: %s" path error)

let ensure_directory label path =
  if not (Sys.file_exists path) then
    Error (Printf.sprintf "%s does not exist: %s" label path)
  else if Sys.is_directory path then Ok ()
  else Error (Printf.sprintf "%s must be a directory, got file: %s" label path)

let resolve_path ~working_directory path =
  if Filename.is_relative path then Filename.concat working_directory path
  else path

let initialized_result () =
  `Assoc
    [
      ("protocolVersion", `String protocol_version);
      ("irVersion", `String Ir.ir_version);
      ( "capabilities",
        `Assoc
          [
            ("check", `Bool true);
            ("compile", `Bool true);
            ("run", `Bool true);
            ("executeEffect", `Bool true);
            ("trace", `Bool true);
            ("diagnostic", `Bool true);
            ("progress", `Bool true);
            ("streaming", `Bool true);
            ("cancelRequest", `Bool true);
            ("renderedPrompt", `Bool true);
            ("outputSchema", `Bool true);
          ] );
      ( "effectKinds",
        `List
          [
            `String "bound-agent";
            `String "bound-skill";
            `String "local-prompt-skill";
            `String "inline-agent";
          ] );
    ]

let check_result program =
  `Assoc
    [
      ("modules", `Int (List.length program.Ir.modules));
      ("rootModule", `String (Syntax.Ast.string_of_qname program.Ir.root_module));
    ]

let compile_result program =
  `Assoc
    [
      ("irVersion", `String Ir.ir_version);
      ("artifact", Ir.program_to_yojson program);
    ]

let run_result run_id (result : Runtime.execution_result) =
  `Assoc
    [
      ("runId", `String run_id);
      ("stepsRun", `Int result.steps_run);
      ("output", match result.output with Some json -> json | None -> `Null);
      ( "traceNodes",
        `List (List.map Workflow_trace.to_yojson result.trace_nodes) );
    ]

let write_json server json = Rpc_stdio.write_message server.output json

let notify server method_ params =
  write_json server (Rpc_protocol.request ?params:(Some params) method_)

let string_option_field name = function
  | Some value -> (name, `String value)
  | None -> (name, `Null)

let int_option_field name = function
  | Some value -> (name, `Int value)
  | None -> (name, `Null)

let bool_option_field name = function
  | Some value -> (name, `Bool value)
  | None -> (name, `Null)

let effect_summary_field = function
  | None -> ("effect", `Null)
  | Some (request : Effect_request.t) ->
      ( "effect",
        `Assoc
          [
            ("kind", `String (Effect_request.kind_to_string request.kind));
            ("name", `String request.name);
          ] )

let trace_payload ?run_id ?step ?request ?details event =
  `Assoc
    ([
       ("event", `String event);
       string_option_field "runId" run_id;
       int_option_field "step" step;
       effect_summary_field request;
     ]
    @ match details with None -> [] | Some details -> [ ("details", details) ])

let send_trace (server : server) ?run_id ?step ?request ?details event =
  if server.trace_enabled then
    notify server trace_method
      (trace_payload ?run_id ?step ?request ?details event)
  else Ok ()

let progress_payload ?run_id ?step ?message ?completed_steps ?known_steps
    ?cancellable stage =
  `Assoc
    [
      string_option_field "runId" run_id;
      ("stage", `String stage);
      int_option_field "step" step;
      string_option_field "message" message;
      int_option_field "completedSteps" completed_steps;
      int_option_field "knownSteps" known_steps;
      bool_option_field "cancellable" cancellable;
    ]

let send_progress (server : server) ?run_id ?step ?message ?completed_steps
    ?known_steps ?cancellable stage =
  if server.progress_enabled then
    notify server progress_method
      (progress_payload ?run_id ?step ?message ?completed_steps ?known_steps
         ?cancellable stage)
  else Ok ()

let output_chunk_payload ?run_id ?step ~stream_id ~format ~delta ~done_ () =
  `Assoc
    [
      string_option_field "runId" run_id;
      int_option_field "step" step;
      ("streamId", `String stream_id);
      ("format", `String format);
      ("delta", delta);
      ("done", `Bool done_);
    ]

let send_output_chunk server ?run_id ?step ~stream_id ~format ~delta ~done_ () =
  notify server output_chunk_method
    (output_chunk_payload ?run_id ?step ~stream_id ~format ~delta ~done_ ())

let diagnostic_payload ?run_id ?step ?method_ ?request message =
  `Assoc
    [
      ("severity", `String "error");
      ("message", `String message);
      string_option_field "method" method_;
      string_option_field "runId" run_id;
      int_option_field "step" step;
      effect_summary_field request;
    ]

let send_diagnostic (server : server) ?run_id ?step ?method_ ?request message =
  if server.diagnostics_enabled then
    notify server diagnostic_method
      (diagnostic_payload ?run_id ?step ?method_ ?request message)
  else Ok ()

let reply_success_message server request_id json =
  match request_id with
  | Some id -> write_json server (Rpc_protocol.success id json)
  | None -> Ok ()

let reply_error_message server request_id ?data ~code message =
  match request_id with
  | Some id ->
      write_json server (Rpc_protocol.error ~id ?data ~code ~message ())
  | None -> Ok ()

let progress_message_for_effect action (request : Effect_request.t) =
  Printf.sprintf "%s %s %s" action
    (Effect_request.kind_to_string request.kind)
    request.name

let output_chunk_matches_request (request : Effect_request.t)
    (chunk : output_chunk) =
  request.Effect_request.run_id = chunk.output_chunk_run_id
  && request.Effect_request.step_index = chunk.output_chunk_step

let relay_output_chunk server (chunk : output_chunk) =
  send_output_chunk server ?run_id:chunk.output_chunk_run_id
    ?step:chunk.output_chunk_step ~stream_id:chunk.output_chunk_stream_id
    ~format:chunk.output_chunk_format ~delta:chunk.output_chunk_delta
    ~done_:chunk.output_chunk_done ()

let handle_in_run_output_chunk server (request : Effect_request.t) params =
  match output_chunk_of_yojson params with
  | Error error ->
      send_diagnostic server ?run_id:request.run_id ?step:request.step_index
        ~method_:output_chunk_method ~request error
  | Ok chunk ->
      if output_chunk_matches_request request chunk then
        relay_output_chunk server chunk
      else
        send_diagnostic server ?run_id:request.run_id ?step:request.step_index
          ~method_:output_chunk_method ~request
          "output chunk runId/step must match the active effect request"

let active_run_matches_request active request_id =
  match active.request_id with
  | Some active_request_id -> id_matches active_request_id request_id
  | None -> false

let active_run_matches_effect_request active request_id =
  match active.waiting_effect_id with
  | Some active_request_id -> id_matches active_request_id request_id
  | None -> false

let request_cancellation server request_id =
  match server.active_run with
  | Some active
    when active_run_matches_request active request_id
         || active_run_matches_effect_request active request_id ->
      active.cancellation_requested <- true;
      Ok true
  | _ -> Ok false

let emit_cancellation server active ?step ?request () =
  if active.cancellation_emitted then Ok ()
  else
    let cancellation_step =
      match step with Some step -> Some step | None -> active.current_step
    in
    let* () =
      send_trace server ?run_id:active.run_id ?step:cancellation_step ?request
        ~details:(`Assoc [ ("reason", `String "host-cancelled") ])
        "run-cancelled"
    in
    let* () =
      send_progress server ?run_id:active.run_id ?step:cancellation_step
        ~message:cancellation_message ~completed_steps:active.completed_steps
        ?known_steps:None ~cancellable:false "run-cancelled"
    in
    let* () =
      send_diagnostic server ?run_id:active.run_id ?step:cancellation_step
        ~method_:"camlflow/run" ?request cancellation_message
    in
    active.cancellation_emitted <- true;
    Ok ()

let ensure_run_not_cancelled server ?step ?request () =
  match server.active_run with
  | Some active when active.cancellation_requested ->
      let* () = emit_cancellation server active ?step ?request () in
      Error cancellation_message
  | _ -> Ok ()

let read_json server =
  match server.pending_message with
  | Some message ->
      server.pending_message <- None;
      Ok message
  | None -> (
      let* message = Rpc_stdio.read_message server.input in
      match message with
      | Some message -> Ok message
      | None -> Error "unexpected EOF while waiting for JSON-RPC message")

let input_has_pending_message server =
  match server.pending_message with
  | Some _ -> true
  | None -> (
      let fd = Unix.descr_of_in_channel server.input in
      match Unix.select [ fd ] [] [] 0.0 with ready, _, _ -> ready <> [])

let handle_in_run_cancel_request server request =
  let params =
    match request.Rpc_protocol.request_params with
    | Some params -> params
    | None -> `Assoc []
  in
  match cancel_request_id_of_yojson params with
  | Ok cancel_id ->
      let* _matched = request_cancellation server cancel_id in
      reply_success_message server request.Rpc_protocol.request_id `Null
  | Error error ->
      let* () = send_diagnostic server ~method_:request.request_method error in
      let* () =
        reply_error_message server request.Rpc_protocol.request_id
          ~code:(-32600) error
      in
      Ok ()

let rec drain_in_run_control_messages server =
  if not (input_has_pending_message server) then Ok ()
  else
    match read_json server with
    | Error error
      when String.equal error
             "unexpected EOF while waiting for JSON-RPC message" ->
        Ok ()
    | Error error -> Error error
    | Ok message -> (
        match Rpc_protocol.request_of_yojson message with
        | Ok request
          when String.equal request.Rpc_protocol.request_method cancel_method ->
            let* () = handle_in_run_cancel_request server request in
            if
              match server.active_run with
              | Some active -> active.cancellation_requested
              | None -> false
            then Ok ()
            else drain_in_run_control_messages server
        | Ok request when Option.is_none request.Rpc_protocol.request_id ->
            drain_in_run_control_messages server
        | Ok request ->
            let message =
              Printf.sprintf "request is not accepted while a run is active: %s"
                request.Rpc_protocol.request_method
            in
            let* () =
              send_diagnostic server ~method_:request.request_method message
            in
            let* () =
              reply_error_message server request.Rpc_protocol.request_id
                ~code:(-32600) message
            in
            drain_in_run_control_messages server
        | Error _ -> (
            match Rpc_protocol.response_of_yojson message with
            | Ok _ ->
                server.pending_message <- Some message;
                Ok ()
            | Error error ->
                let* () =
                  send_diagnostic server ~method_:"(invalid-in-run-message)"
                    error
                in
                drain_in_run_control_messages server))

let drain_and_ensure_run_not_cancelled server ?step ?request () =
  let* () = drain_in_run_control_messages server in
  ensure_run_not_cancelled server ?step ?request ()

let send_effect_request server (request : Effect_request.t) =
  let request_id =
    Rpc_protocol.String
      (Printf.sprintf "effect-%d"
         (match request.Effect_request.step_index with
         | Some step -> step
         | None -> 0))
  in
  (match server.active_run with
  | Some active -> active.waiting_effect_id <- Some request_id
  | None -> ());
  let step = request.Effect_request.step_index in
  let params =
    `Assoc
      [
        ( "runId",
          match request.Effect_request.run_id with
          | Some run_id -> `String run_id
          | None -> `Null );
        ( "step",
          match request.Effect_request.step_index with
          | Some step -> `Int step
          | None -> `Null );
        ("effect", Effect_request.to_yojson request);
      ]
  in
  let rec wait_for_response () =
    let* message = read_json server in
    match Rpc_protocol.response_of_yojson message with
    | Ok response -> (
        let* () =
          match response.Rpc_protocol.response_id with
          | Some id when id_matches id request_id -> Ok ()
          | Some id ->
              Error
                (Printf.sprintf
                   "unexpected JSON-RPC response id while waiting for effect \
                    response: %s"
                   (Rpc_protocol.string_of_id id))
          | None -> Error "missing JSON-RPC response id for effect response"
        in
        match response.Rpc_protocol.response_error with
        | Some error when error.Rpc_protocol.error_code = request_cancelled_code
          ->
            (match server.active_run with
            | Some active -> active.cancellation_requested <- true
            | None -> ());
            let* () = ensure_run_not_cancelled server ?step ~request () in
            Error cancellation_message
        | Some error ->
            Error
              (Printf.sprintf "host returned JSON-RPC error %d for %s: %s"
                 error.Rpc_protocol.error_code request.Effect_request.name
                 error.Rpc_protocol.error_message)
        | None -> (
            match response.Rpc_protocol.response_result with
            | Some (`Assoc fields) -> (
                match List.assoc_opt "output" fields with
                | Some json -> Ok json
                | None ->
                    Error "effect response result must contain output field")
            | Some _ -> Error "effect response result must be an object"
            | None -> Error "effect response missing result payload"))
    | Error _ -> (
        match Rpc_protocol.request_of_yojson message with
        | Ok incoming
          when String.equal incoming.Rpc_protocol.request_method cancel_method
          ->
            let cancel_params =
              match incoming.Rpc_protocol.request_params with
              | Some params -> params
              | None -> `Assoc []
            in
            let* cancel_id = cancel_request_id_of_yojson cancel_params in
            let* matched = request_cancellation server cancel_id in
            let* () =
              if matched then ensure_run_not_cancelled server ?step ~request ()
              else Ok ()
            in
            wait_for_response ()
        | Ok incoming
          when String.equal incoming.Rpc_protocol.request_method
                 output_chunk_method
               && Option.is_none incoming.Rpc_protocol.request_id ->
            let output_chunk_params =
              match incoming.Rpc_protocol.request_params with
              | Some params -> params
              | None -> `Assoc []
            in
            let* () =
              handle_in_run_output_chunk server request output_chunk_params
            in
            wait_for_response ()
        | Ok incoming when Option.is_none incoming.Rpc_protocol.request_id ->
            wait_for_response ()
        | Ok incoming ->
            Error
              (Printf.sprintf
                 "unexpected JSON-RPC request while waiting for effect \
                  response: %s"
                 incoming.Rpc_protocol.request_method)
        | Error error ->
            Error
              (Printf.sprintf
                 "unexpected JSON-RPC message while waiting for effect \
                  response: %s"
                 error))
  in
  Fun.protect
    ~finally:(fun () ->
      match server.active_run with
      | Some active -> active.waiting_effect_id <- None
      | None -> ())
    (fun () ->
      let* () =
        write_json server
          (Rpc_protocol.request ~id:request_id ~params effect_method)
      in
      wait_for_response ())

let build_host_context server ~working_directory ~skills_dir run_id =
  let step_counter = ref 0 in
  let run invocation =
    incr step_counter;
    let step = !step_counter in
    (match server.active_run with
    | Some active -> active.current_step <- Some step
    | None -> ());
    let* () = drain_and_ensure_run_not_cancelled server ~step () in
    let* request =
      Effect_request.of_invocation ~step_index:step ~run_id invocation
    in
    let* () = drain_and_ensure_run_not_cancelled server ~step ~request () in
    let completed_steps =
      match server.active_run with
      | Some active -> active.completed_steps
      | None -> step - 1
    in
    let* () =
      send_progress server ~run_id ~step
        ~message:(progress_message_for_effect "Executing" request)
        ~completed_steps ?known_steps:None ~cancellable:true "effect-start"
    in
    let* () = send_trace server ~run_id ~step ~request "effect-request" in
    let started_at = Unix.gettimeofday () in
    let execution_result =
      Effect_bridge.execute_request
        ~executor:(send_effect_request server)
        request
    in
    let* execution =
      match execution_result with
      | Ok execution -> Ok execution
      | Error error when String.equal error cancellation_message -> Error error
      | Error error ->
          let finished_at = Unix.gettimeofday () in
          let trace_node =
            Workflow_trace.create ~request ~output:None
              ~validation:(Workflow_trace.validation_error error)
              ~timing:(Workflow_trace.timing ~started_at ~finished_at)
              ()
          in
          let* () =
            send_trace server ~run_id ~step ~request
              ~details:
                (`Assoc
                   [
                     ("message", `String error);
                     ("traceNode", Workflow_trace.to_yojson trace_node);
                   ])
              "effect-error"
          in
          let* () = send_diagnostic server ~run_id ~step ~request error in
          Error error
    in
    let* () = drain_and_ensure_run_not_cancelled server ~step ~request () in
    let validation =
      Effect_bridge.validate_execution ~source:"host" invocation execution
    in
    let finished_at = Unix.gettimeofday () in
    let trace_node validation =
      Workflow_trace.create ~request ~output:(Some execution.output_json)
        ~validation
        ~timing:(Workflow_trace.timing ~started_at ~finished_at)
        ()
    in
    let* () =
      match validation with
      | Ok _ ->
          let trace_node = trace_node Workflow_trace.validation_ok in
          let* () =
            drain_and_ensure_run_not_cancelled server ~step ~request ()
          in
          (match server.active_run with
          | Some active -> active.completed_steps <- step
          | None -> ());
          let completed_steps =
            match server.active_run with
            | Some active -> active.completed_steps
            | None -> step
          in
          let* () =
            send_progress server ~run_id ~step
              ~message:(progress_message_for_effect "Finished" request)
              ~completed_steps ?known_steps:None ~cancellable:true
              "effect-finish"
          in
          send_trace server ~run_id ~step ~request
            ~details:
              (`Assoc
                 [
                   ("status", `String "ok");
                   ("traceNode", Workflow_trace.to_yojson trace_node);
                 ])
            "effect-result"
      | Error error ->
          let trace_node = trace_node (Workflow_trace.validation_error error) in
          let* () =
            send_trace server ~run_id ~step ~request
              ~details:
                (`Assoc
                   [
                     ("message", `String error);
                     ("traceNode", Workflow_trace.to_yojson trace_node);
                   ])
              "effect-error"
          in
          send_diagnostic server ~run_id ~step ~request error
    in
    let* _ = validation in
    Ok execution.Effect_bridge.output_json
  in
  let context =
    Context.empty |> fun context ->
    Context.with_run_id context run_id |> fun context ->
    Context.with_working_directory context working_directory
  in
  let context =
    match skills_dir with
    | Some dir -> Context.with_skills_directory context dir
    | None -> context
  in
  let context =
    Context.with_cancellation_check context (fun () ->
        drain_and_ensure_run_not_cancelled server ())
  in
  let context = Context.with_default_provider context run in
  let context =
    Context.with_prompt_skill_provider context
      (fun ~name ~markdown ~input ~return_type ~types ->
        run
          {
            Context.invocation_kind = Context.Local_prompt_skill;
            invocation_name = name;
            invocation_input = input;
            invocation_return_type = return_type;
            invocation_types = types;
            invocation_working_directory = context.Context.working_directory;
            invocation_skills_directory = context.Context.skills_directory;
            invocation_markdown = Some markdown;
            invocation_definition = None;
          })
  in
  Context.with_inline_agent_provider context
    (fun ~name ~definition ~input ~return_type ~types ->
      run
        {
          Context.invocation_kind = Context.Inline_agent;
          invocation_name = name;
          invocation_input = input;
          invocation_return_type = return_type;
          invocation_types = types;
          invocation_working_directory = context.Context.working_directory;
          invocation_skills_directory = context.Context.skills_directory;
          invocation_markdown = None;
          invocation_definition = Some definition;
        })

let handle_check params =
  let* request = run_request_of_yojson params in
  let* program =
    load_program request.run_program.program_include_paths
      request.run_program.program_path
  in
  Ok (check_result program)

let handle_compile params =
  let* request = run_request_of_yojson params in
  let* program =
    load_program request.run_program.program_include_paths
      request.run_program.program_path
  in
  Ok (compile_result program)

let handle_run server params =
  let lift result = Result.map_error (fun error -> Run_failed error) result in
  let* request = lift (run_request_of_yojson params) in
  let working_directory = Sys.getcwd () in
  let* () =
    lift
      (match request.run_program.program_skills_dir with
      | Some dir -> ensure_directory "skills directory" dir
      | None -> Ok ())
  in
  let* program =
    lift
      (load_program request.run_program.program_include_paths
         request.run_program.program_path)
  in
  server.next_run <- server.next_run + 1;
  let run_id = Printf.sprintf "run-%d" server.next_run in
  (match server.active_run with
  | Some active -> active.run_id <- Some run_id
  | None -> ());
  let* () =
    lift
      (send_trace server ~run_id
         ~details:
           (`Assoc
              [
                ("programPath", `String request.run_program.program_path);
                ("entry", `String request.run_entry);
              ])
         "run-start")
  in
  let* () =
    lift
      (send_progress server ~run_id ?step:None
         ~message:(Printf.sprintf "Running %s" request.run_entry)
         ~completed_steps:0 ?known_steps:None ~cancellable:true "run-start")
  in
  let* () =
    match drain_and_ensure_run_not_cancelled server () with
    | Ok () -> Ok ()
    | Error error -> Error (Run_cancelled error)
  in
  let context =
    build_host_context server ~working_directory
      ~skills_dir:request.run_program.program_skills_dir run_id
  in
  let result =
    match
      Runtime.execute ~context ~entry:request.run_entry ?input:request.run_input
        program
    with
    | Ok result -> Ok result
    | Error error when String.equal error cancellation_message ->
        Error (Run_cancelled cancellation_message)
    | Error error ->
        Error
          (Run_failed
             (Printf.sprintf "run failed for %s: %s"
                request.run_program.program_path error))
  in
  let* result =
    match result with
    | Ok result ->
        let* () =
          match drain_and_ensure_run_not_cancelled server () with
          | Ok () -> Ok ()
          | Error error -> Error (Run_cancelled error)
        in
        let* () =
          lift
            (send_trace server ~run_id
               ~details:(`Assoc [ ("stepsRun", `Int result.Runtime.steps_run) ])
               "run-finish")
        in
        let* () =
          lift
            (send_progress server ~run_id ?step:None ~message:"Run finished"
               ~completed_steps:result.Runtime.steps_run ?known_steps:None
               ~cancellable:false "run-finish")
        in
        Ok result
    | Error (Run_cancelled error) ->
        let* () =
          lift
            (match server.active_run with
            | Some active -> emit_cancellation server active ()
            | None -> Ok ())
        in
        Error (Run_cancelled error)
    | Error (Run_failed error) ->
        let completed_steps =
          match server.active_run with
          | Some active -> active.completed_steps
          | None -> 0
        in
        let* () =
          lift
            (send_trace server ~run_id
               ~details:(`Assoc [ ("message", `String error) ])
               "run-error")
        in
        let* () =
          lift
            (send_progress server ~run_id ?step:None ~message:error
               ~completed_steps ?known_steps:None ~cancellable:false "run-error")
        in
        let* () =
          lift (send_diagnostic server ~run_id ~method_:"camlflow/run" error)
        in
        Error (Run_failed error)
  in
  Ok (run_result run_id result)

let method_requires_init = function
  | "initialize" | "exit" | "$/cancelRequest" -> false
  | _ -> true

let handle_request server (request : Rpc_protocol.request_message) =
  let request_id = request.Rpc_protocol.request_id in
  let reply_success json =
    match request_id with
    | Some id -> write_json server (Rpc_protocol.success id json)
    | None -> Ok ()
  in
  let reply_error ?data ~code message =
    write_json server
      (Rpc_protocol.error ?id:request_id ?data ~code ~message ())
  in
  let params =
    match request.Rpc_protocol.request_params with
    | Some params -> params
    | None -> `Assoc []
  in
  if method_requires_init request.request_method && not server.initialized then
    let* () =
      send_diagnostic server ~method_:request.request_method
        "server not initialized"
    in
    let* () = reply_error ~code:(-32002) "server not initialized" in
    Ok Continue
  else
    match request.request_method with
    | "initialize" ->
        let result = notification_preferences_of_yojson params in
        let* () =
          match result with
          | Ok preferences ->
              server.initialized <- true;
              server.trace_enabled <- preferences.trace_enabled;
              server.diagnostics_enabled <- preferences.diagnostics_enabled;
              server.progress_enabled <- preferences.progress_enabled;
              reply_success (initialized_result ())
          | Error error ->
              let* () =
                send_diagnostic server ~method_:request.request_method error
              in
              reply_error ~code:(-32600) error
        in
        Ok Continue
    | "shutdown" ->
        server.shutdown_requested <- true;
        let* () = reply_success `Null in
        Ok Continue
    | "exit" -> Ok Stop
    | "$/cancelRequest" ->
        let result =
          let* cancel_id = cancel_request_id_of_yojson params in
          request_cancellation server cancel_id
        in
        let* () =
          match result with
          | Ok _ -> reply_success `Null
          | Error error ->
              let* () =
                send_diagnostic server ~method_:request.request_method error
              in
              reply_error ~code:(-32600) error
        in
        Ok Continue
    | "camlflow/outputChunk" ->
        let* () =
          match request_id with
          | None -> Ok ()
          | Some _ ->
              let message =
                "camlflow/outputChunk is only accepted as a notification \
                 during effect execution"
              in
              let* () =
                send_diagnostic server ~method_:request.request_method message
              in
              reply_error ~code:(-32600) message
        in
        Ok Continue
    | "camlflow/check" ->
        let* () =
          send_progress server ?run_id:None ?step:None
            ~message:"Checking program" ~completed_steps:0 ?known_steps:None
            ~cancellable:false "check-start"
        in
        let result = handle_check params in
        let* () =
          match result with
          | Ok json ->
              let* () =
                send_progress server ?run_id:None ?step:None
                  ~message:"Check finished" ~completed_steps:0 ?known_steps:None
                  ~cancellable:false "check-finish"
              in
              reply_success json
          | Error error ->
              let* () =
                send_diagnostic server ~method_:request.request_method error
              in
              reply_error ~code:(-32010) error
        in
        Ok Continue
    | "camlflow/compile" ->
        let* () =
          send_progress server ?run_id:None ?step:None
            ~message:"Compiling program" ~completed_steps:0 ?known_steps:None
            ~cancellable:false "compile-start"
        in
        let result = handle_compile params in
        let* () =
          match result with
          | Ok json ->
              let* () =
                send_progress server ?run_id:None ?step:None
                  ~message:"Compile finished" ~completed_steps:0
                  ?known_steps:None ~cancellable:false "compile-finish"
              in
              reply_success json
          | Error error ->
              let* () =
                send_diagnostic server ~method_:request.request_method error
              in
              reply_error ~code:(-32011) error
        in
        Ok Continue
    | "camlflow/run" ->
        server.active_run <-
          Some
            {
              request_id;
              run_id = None;
              current_step = None;
              completed_steps = 0;
              waiting_effect_id = None;
              cancellation_requested = false;
              cancellation_emitted = false;
            };
        let result =
          Fun.protect
            ~finally:(fun () -> server.active_run <- None)
            (fun () -> handle_run server params)
        in
        let* () =
          match result with
          | Ok json -> reply_success json
          | Error (Run_cancelled error) ->
              reply_error ~code:request_cancelled_code error
          | Error (Run_failed error) -> reply_error ~code:(-32012) error
        in
        Ok Continue
    | _ ->
        let* () =
          send_diagnostic server ~method_:request.request_method
            "method not found"
        in
        let* () = reply_error ~code:(-32601) "method not found" in
        Ok Continue

let run ~input ~output =
  let server =
    {
      input;
      output;
      initialized = false;
      shutdown_requested = false;
      next_run = 0;
      active_run = None;
      pending_message = None;
      trace_enabled = true;
      diagnostics_enabled = true;
      progress_enabled = true;
    }
  in
  let rec loop () =
    let* message = Rpc_stdio.read_message server.input in
    match message with
    | None -> Ok ()
    | Some message -> (
        let parsed = Rpc_protocol.request_of_yojson message in
        let* control =
          match parsed with
          | Ok request -> handle_request server request
          | Error error -> (
              match Rpc_protocol.response_of_yojson message with
              | Ok _ -> Ok Continue
              | Error _ ->
                  let* () =
                    send_diagnostic server ~method_:"(invalid-request)" error
                  in
                  let* () =
                    write_json server
                      (Rpc_protocol.error ~code:(-32600) ~message:error ())
                  in
                  Ok Continue)
        in
        match control with Continue -> loop () | Stop -> Ok ())
  in
  loop ()

let run_stdio () = run ~input:stdin ~output:stdout
