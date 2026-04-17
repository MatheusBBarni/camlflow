module Context = Runtime.Context

let ( let* ) = Result.bind

let protocol_version = "0.1.0"
let effect_method = "camlflow/executeEffect"
let trace_method = "camlflow/trace"
let diagnostic_method = "camlflow/diagnostic"

type server = {
  input : in_channel;
  output : out_channel;
  mutable initialized : bool;
  mutable shutdown_requested : bool;
  mutable next_run : int;
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
  if Filename.is_relative path then Filename.concat working_directory path else path

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
  `Assoc [ ("irVersion", `String Ir.ir_version); ("artifact", Ir.program_to_yojson program) ]

let run_result run_id (result : Runtime.execution_result) =
  `Assoc
    [
      ("runId", `String run_id);
      ("stepsRun", `Int result.steps_run);
      ("output", match result.output with Some json -> json | None -> `Null);
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
    ([ ("event", `String event); string_option_field "runId" run_id; int_option_field "step" step; effect_summary_field request ]
    @ match details with None -> [] | Some details -> [ ("details", details) ])

let send_trace server ?run_id ?step ?request ?details event =
  notify server trace_method (trace_payload ?run_id ?step ?request ?details event)

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

let send_diagnostic server ?run_id ?step ?method_ ?request message =
  notify server diagnostic_method
    (diagnostic_payload ?run_id ?step ?method_ ?request message)

let read_json server =
  let* message = Rpc_stdio.read_message server.input in
  match message with
  | Some message -> Ok message
  | None -> Error "unexpected EOF while waiting for JSON-RPC message"

let send_effect_request server (request : Effect_request.t) =
  let request_id =
    Rpc_protocol.String
      (Printf.sprintf "effect-%d"
         (match request.Effect_request.step_index with Some step -> step | None -> 0))
  in
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
  let* () =
    write_json server (Rpc_protocol.request ~id:request_id ~params effect_method)
  in
  let* message = read_json server in
  let* response = Rpc_protocol.response_of_yojson message in
  let* () =
    match response.Rpc_protocol.response_id with
    | Some id when String.equal (Rpc_protocol.string_of_id id) (Rpc_protocol.string_of_id request_id) -> Ok ()
    | Some id ->
        Error
          (Printf.sprintf "unexpected JSON-RPC response id while waiting for effect response: %s"
             (Rpc_protocol.string_of_id id))
    | None -> Error "missing JSON-RPC response id for effect response"
  in
  match response.Rpc_protocol.response_error with
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
          | None -> Error "effect response result must contain output field")
      | Some _ -> Error "effect response result must be an object"
      | None -> Error "effect response missing result payload")

let build_host_context server ~working_directory ~skills_dir run_id =
  let step_counter = ref 0 in
  let run invocation =
    incr step_counter;
    let step = !step_counter in
    let* request = Effect_request.of_invocation ~step_index:step ~run_id invocation in
    let* () = send_trace server ~run_id ~step ~request "effect-request" in
    let execution_result =
      Effect_bridge.execute_request ~executor:(send_effect_request server) request
    in
    let* execution =
      match execution_result with
      | Ok execution -> Ok execution
      | Error error ->
          let* () =
            send_trace server ~run_id ~step ~request
              ~details:(`Assoc [ ("message", `String error) ])
              "effect-error"
          in
          let* () = send_diagnostic server ~run_id ~step ~request error in
          Error error
    in
    let validation =
      Effect_bridge.validate_execution ~source:"host" invocation execution
    in
    let* () =
      match validation with
      | Ok _ ->
          send_trace server ~run_id ~step ~request
            ~details:(`Assoc [ ("status", `String "ok") ])
            "effect-result"
      | Error error ->
          let* () =
            send_trace server ~run_id ~step ~request
              ~details:(`Assoc [ ("message", `String error) ])
              "effect-error"
          in
          send_diagnostic server ~run_id ~step ~request error
    in
    let* _ = validation in
    Ok execution.Effect_bridge.output_json
  in
  let context = Context.with_working_directory Context.empty working_directory in
  let context =
    match skills_dir with Some dir -> Context.with_skills_directory context dir | None -> context
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
  let* request = run_request_of_yojson params in
  let working_directory = Sys.getcwd () in
  let* () =
    match request.run_program.program_skills_dir with
    | Some dir -> ensure_directory "skills directory" dir
    | None -> Ok ()
  in
  let* program =
    load_program request.run_program.program_include_paths
      request.run_program.program_path
  in
  server.next_run <- server.next_run + 1;
  let run_id = Printf.sprintf "run-%d" server.next_run in
  let* () =
    send_trace server ~run_id
      ~details:
        (`Assoc
          [
            ("programPath", `String request.run_program.program_path);
            ("entry", `String request.run_entry);
          ])
      "run-start"
  in
  let context =
    build_host_context server ~working_directory
      ~skills_dir:request.run_program.program_skills_dir run_id
  in
  let result =
    Runtime.execute ~context ~entry:request.run_entry ?input:request.run_input program
    |> Result.map_error (fun error ->
           Printf.sprintf "run failed for %s: %s"
             request.run_program.program_path error)
  in
  let* result =
    match result with
    | Ok result ->
        let* () =
          send_trace server ~run_id
            ~details:(`Assoc [ ("stepsRun", `Int result.Runtime.steps_run) ])
            "run-finish"
        in
        Ok result
    | Error error ->
        let* () =
          send_trace server ~run_id
            ~details:(`Assoc [ ("message", `String error) ])
            "run-error"
        in
        let* () = send_diagnostic server ~run_id ~method_:"camlflow/run" error in
        Error error
  in
  Ok (run_result run_id result)

let method_requires_init = function
  | "initialize" | "exit" -> false
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
  let params = match request.Rpc_protocol.request_params with Some params -> params | None -> `Assoc [] in
  if method_requires_init request.request_method && not server.initialized then
    let* () = send_diagnostic server ~method_:request.request_method "server not initialized" in
    let* () = reply_error ~code:(-32002) "server not initialized" in
    Ok Continue
  else
    match request.request_method with
    | "initialize" ->
        server.initialized <- true;
        let* () = reply_success (initialized_result ()) in
        Ok Continue
    | "shutdown" ->
        server.shutdown_requested <- true;
        let* () = reply_success `Null in
        Ok Continue
    | "exit" -> Ok Stop
    | "camlflow/check" ->
        let result = handle_check params in
        let* () =
          match result with
          | Ok json -> reply_success json
          | Error error ->
              let* () = send_diagnostic server ~method_:request.request_method error in
              reply_error ~code:(-32010) error
        in
        Ok Continue
    | "camlflow/compile" ->
        let result = handle_compile params in
        let* () =
          match result with
          | Ok json -> reply_success json
          | Error error ->
              let* () = send_diagnostic server ~method_:request.request_method error in
              reply_error ~code:(-32011) error
        in
        Ok Continue
    | "camlflow/run" ->
        let result = handle_run server params in
        let* () =
          match result with
          | Ok json -> reply_success json
          | Error error ->
              let* () = send_diagnostic server ~method_:request.request_method error in
              reply_error ~code:(-32012) error
        in
        Ok Continue
    | _ ->
        let* () = send_diagnostic server ~method_:request.request_method "method not found" in
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
    }
  in
  let rec loop () =
    let* message = Rpc_stdio.read_message server.input in
    match message with
    | None -> Ok ()
    | Some message ->
        let parsed = Rpc_protocol.request_of_yojson message in
        let* control =
          match parsed with
          | Ok request -> handle_request server request
          | Error error ->
              let* () = send_diagnostic server ~method_:"(invalid-request)" error in
              let* () =
                write_json server
                  (Rpc_protocol.error ~code:(-32600) ~message:error ())
              in
              Ok Continue
        in
        match control with Continue -> loop () | Stop -> Ok ()
  in
  loop ()

let run_stdio () = run ~input:stdin ~output:stdout
