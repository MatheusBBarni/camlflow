type executor = Effect_request.t -> (Yojson.Safe.t, string) result

type execution = {
  request : Effect_request.t;
  output_json : Yojson.Safe.t;
}

let ( let* ) = Result.bind

let execute_request ~executor request =
  let* output_json = executor request in
  Ok { request; output_json }

let execute ?step_index ?run_id ~executor invocation =
  let* request = Effect_request.of_invocation ?step_index ?run_id invocation in
  execute_request ~executor request

let step_kind = function
  | Runtime.Context.Bound_agent -> "agent"
  | Runtime.Context.Bound_skill -> "skill"
  | Runtime.Context.Local_prompt_skill -> "local-skill"
  | Runtime.Context.Inline_agent -> "inline-agent"

let output_mismatch_message ?(source = "effect") invocation output_json error =
  Printf.sprintf
    "%s output for %s %s does not match declared return type %s: %s (output: %s)"
    source (step_kind invocation.Runtime.Context.invocation_kind)
    invocation.Runtime.Context.invocation_name
    (Effect_request.string_of_typ invocation.Runtime.Context.invocation_return_type)
    error (Yojson.Safe.to_string output_json)

let validate_output ?source invocation output_json =
  Value.of_json invocation.Runtime.Context.invocation_types
    invocation.Runtime.Context.invocation_return_type output_json
  |> Result.map_error (fun error ->
         output_mismatch_message ?source invocation output_json error)

let validate_execution ?source invocation execution =
  validate_output ?source invocation execution.output_json
