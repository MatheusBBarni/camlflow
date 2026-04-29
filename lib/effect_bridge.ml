type executor = Effect_request.t -> (Yojson.Safe.t, string) result
type execution = { request : Effect_request.t; output_json : Yojson.Safe.t }

let ( let* ) = Result.bind

let execute_request ~executor request =
  let* output_json = executor request in
  Ok { request; output_json }

let execute ?step_index ?run_id ~executor invocation =
  let* request = Effect_request.of_invocation ?step_index ?run_id invocation in
  execute_request ~executor request

let step_kind = function
  | Runtime_context.Bound_agent -> "agent"
  | Runtime_context.Bound_skill -> "skill"
  | Runtime_context.Local_prompt_skill -> "local-skill"
  | Runtime_context.Inline_agent -> "inline-agent"

let output_mismatch_message ?(source = "effect") invocation output_json error =
  Printf.sprintf
    "%s output for %s %s does not match declared return type %s: %s (output: \
     %s)"
    source
    (step_kind invocation.Runtime_context.invocation_kind)
    invocation.Runtime_context.invocation_name
    (Effect_request.string_of_typ
       invocation.Runtime_context.invocation_return_type)
    error
    (Yojson.Safe.to_string output_json)

let validate_output ?source invocation output_json =
  Value.of_json invocation.Runtime_context.invocation_types
    invocation.Runtime_context.invocation_return_type output_json
  |> Result.map_error (fun error ->
      output_mismatch_message ?source invocation output_json error)

let validate_execution ?source invocation execution =
  validate_output ?source invocation execution.output_json
