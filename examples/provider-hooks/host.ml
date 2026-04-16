let ( let* ) = Result.bind

let workflow_path = "examples/provider-hooks/workflow.cml"
let skills_dir = "examples/provider-hooks/skills"

let or_fail = function
  | Ok value -> value
  | Error error -> failwith error

let string_of_kind = function
  | Camlflow.Runtime.Context.Bound_agent -> "bound-agent"
  | Camlflow.Runtime.Context.Bound_skill -> "bound-skill"
  | Camlflow.Runtime.Context.Local_prompt_skill -> "local-prompt-skill"
  | Camlflow.Runtime.Context.Inline_agent -> "inline-agent"

let () =
  let program = or_fail (Camlflow.Typing.check_file workflow_path) in
  let observed = ref [] in
  let context =
    let context = Camlflow.Runtime.Context.empty in
    let context =
      Camlflow.Runtime.Context.with_working_directory context (Sys.getcwd ())
    in
    let context =
      Camlflow.Runtime.Context.with_skills_directory context skills_dir
    in
    let context =
      Camlflow.Runtime.Context.with_default_provider context (fun invocation ->
          match invocation.Camlflow.Runtime.Context.invocation_kind with
          | Camlflow.Runtime.Context.Bound_agent ->
              Ok (`String ("agent:" ^ invocation.invocation_name))
          | Camlflow.Runtime.Context.Bound_skill ->
              Ok (`String ("skill:" ^ invocation.invocation_name))
          | Camlflow.Runtime.Context.Local_prompt_skill
          | Camlflow.Runtime.Context.Inline_agent ->
              Error "default provider should not handle this invocation kind")
    in
    let context =
      Camlflow.Runtime.Context.with_prompt_skill_provider context
        (fun ~name ~markdown:_ ~input:_ ~return_type:_ ~types:_ ->
          Ok (`String ("prompt-skill:" ^ name)))
    in
    let context =
      Camlflow.Runtime.Context.with_inline_agent_provider context
        (fun ~name:_ ~definition:_ ~input:_ ~return_type:_ ~types:_ ->
          Ok (`String "inline-review"))
    in
    Camlflow.Runtime.Context.with_effect_observer context
      (fun invocation ~output:_ ->
        observed :=
          ( string_of_kind invocation.Camlflow.Runtime.Context.invocation_kind,
            invocation.invocation_name )
          :: !observed)
  in
  let result =
    or_fail (Camlflow.Runtime.execute ~context ~input:(`String "Ada") program)
  in
  Printf.printf "steps: %d\n" result.steps_run;
  (match result.output with
  | Some json -> print_endline (Yojson.Safe.pretty_to_string json)
  | None -> print_endline "null");
  List.rev !observed
  |> List.iter (fun (kind, name) ->
         Printf.printf "observed: %s %s\n" kind name)
