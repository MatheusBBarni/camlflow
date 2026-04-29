type validation = { status : string; message : string option }
type timing = { started_at : float; finished_at : float; elapsed_ms : float }

type provider = {
  name : string option;
  model : string option;
  reasoning : string option;
  profile : string option;
  sandbox : string option;
  unsupported_settings : string list;
}

type t = {
  id : string;
  run_id : string option;
  step : int option;
  kind : string;
  role : string;
  name : string;
  input : Yojson.Safe.t;
  declared_return_type : string;
  output_schema : Yojson.Safe.t;
  rendered_prompt : string;
  requested_model : string option;
  provider : provider;
  output : Yojson.Safe.t option;
  validation : validation;
  timing : timing;
}

let null_or to_json = function None -> `Null | Some value -> to_json value
let string_option = null_or (fun value -> `String value)
let output_option = null_or Fun.id

let id_for_request (request : Effect_request.t) =
  match request.step_index with
  | Some step -> Printf.sprintf "step-%d" step
  | None ->
      Printf.sprintf "%s-%s"
        (Effect_request.kind_to_string request.kind)
        request.name

let provider ?name ?reasoning ?profile ?sandbox (request : Effect_request.t) =
  {
    name;
    model = request.requested_model;
    reasoning;
    profile;
    sandbox;
    unsupported_settings = request.unsupported_settings;
  }

let timing ~started_at ~finished_at =
  {
    started_at;
    finished_at;
    elapsed_ms = max 0.0 ((finished_at -. started_at) *. 1000.0);
  }

let validation_ok = { status = "ok"; message = None }
let validation_error message = { status = "error"; message = Some message }

let create ?provider:provider_ ~request ~output ~validation ~timing () =
  {
    id = id_for_request request;
    run_id = request.run_id;
    step = request.step_index;
    kind = Effect_request.kind_to_string request.kind;
    role = Effect_request.role_label request.kind;
    name = request.name;
    input = request.input_json;
    declared_return_type = request.declared_return_type;
    output_schema = request.output_schema;
    rendered_prompt = request.rendered_prompt;
    requested_model = request.requested_model;
    provider =
      (match provider_ with
      | Some provider -> provider
      | None -> provider request);
    output;
    validation;
    timing;
  }

let validation_to_yojson validation =
  `Assoc
    [
      ("status", `String validation.status);
      ("message", string_option validation.message);
    ]

let timing_to_yojson timing =
  `Assoc
    [
      ("startedAt", `Float timing.started_at);
      ("finishedAt", `Float timing.finished_at);
      ("elapsedMs", `Float timing.elapsed_ms);
    ]

let provider_to_yojson (provider : provider) =
  `Assoc
    [
      ("name", string_option provider.name);
      ("model", string_option provider.model);
      ("reasoning", string_option provider.reasoning);
      ("profile", string_option provider.profile);
      ("sandbox", string_option provider.sandbox);
      ( "unsupportedSettings",
        `List
          (List.map (fun value -> `String value) provider.unsupported_settings)
      );
    ]

let to_yojson node =
  `Assoc
    [
      ("id", `String node.id);
      ("runId", string_option node.run_id);
      ("step", null_or (fun value -> `Int value) node.step);
      ("kind", `String node.kind);
      ("role", `String node.role);
      ("name", `String node.name);
      ("input", node.input);
      ("declaredReturnType", `String node.declared_return_type);
      ("outputSchema", node.output_schema);
      ("renderedPrompt", `String node.rendered_prompt);
      ("requestedModel", string_option node.requested_model);
      ("provider", provider_to_yojson node.provider);
      ("output", output_option node.output);
      ("validation", validation_to_yojson node.validation);
      ("timing", timing_to_yojson node.timing);
    ]
