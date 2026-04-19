let ( let* ) = Result.bind

type t = {
  path : string;
  directory : string;
  program : string option;
  entry : string option;
  include_paths : string list option;
  skills_dir : string option;
  provider : Provider.name option;
  model : string option;
  reasoning : Provider.reasoning option;
  provider_profile : string option;
  provider_configs : Provider.config list option;
  sandbox : Provider.sandbox option;
  allow_write_dirs : string list option;
  trace_provider : bool option;
}

let filename = "camlflow.json"

let invalid_field path field message =
  Printf.sprintf "invalid field %s in %s: %s" field path message

let invalid_root path message =
  Printf.sprintf "invalid CamlFlow config %s: %s" path message

let known_fields =
  [
    "program";
    "entry";
    "includePaths";
    "skillsDir";
    "provider";
    "model";
    "reasoning";
    "providerProfile";
    "providerConfig";
    "sandbox";
    "allowWriteDirs";
    "traceProvider";
  ]

let resolve_path ~directory path =
  if Filename.is_relative path then
    if String.equal path "." then directory else Filename.concat directory path
  else path

let read_text_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error message ->
    Error (Printf.sprintf "failed to read CamlFlow config %s: %s" path message)

let decode_string path field = function
  | `String value -> Ok value
  | _ -> Error (invalid_field path field "expected string")

let decode_path_string path field json =
  let* value = decode_string path field json in
  if String.trim value = "" then
    Error (invalid_field path field "expected non-empty path")
  else Ok value

let decode_bool path field = function
  | `Bool value -> Ok value
  | _ -> Error (invalid_field path field "expected boolean")

let decode_provider path field json =
  let* value = decode_string path field json in
  Provider.name_of_string value
  |> Result.map_error (fun message -> invalid_field path field message)

let decode_reasoning path field json =
  let* value = decode_string path field json in
  Provider.reasoning_of_string value
  |> Result.map_error (fun message -> invalid_field path field message)

let decode_sandbox path field json =
  let* value = decode_string path field json in
  Provider.sandbox_of_string value
  |> Result.map_error (fun message -> invalid_field path field message)

let validate_known_fields path fields =
  match
    List.find_opt (fun (field, _) -> not (List.mem field known_fields)) fields
  with
  | Some (field, _) -> Error (invalid_field path field "unknown field")
  | None -> Ok ()

let provider_config_field field key =
  if String.equal key "" then field else Printf.sprintf "%s.%s" field key

let decode_provider_configs path field = function
  | `Assoc entries ->
      List.fold_left
        (fun acc (key, value) ->
          let* acc = acc in
          let item_field = provider_config_field field key in
          let* value =
            decode_string path item_field value
          in
          let* config =
            Provider.config_of_parts key value
            |> Result.map_error (fun message -> invalid_field path item_field message)
          in
          Ok (acc @ [ config ]))
        (Ok []) entries
  | _ -> Error (invalid_field path field "expected object")

let decode_path_list path field = function
  | `List values ->
      List.mapi
        (fun index value ->
          decode_path_string path (Printf.sprintf "%s[%d]" field index) value)
        values
      |> List.fold_left
           (fun acc item ->
             let* acc = acc in
             let* item = item in
             Ok (acc @ [ item ]))
           (Ok [])
  | _ -> Error (invalid_field path field "expected array")

let decode_optional fields path field decoder =
  match List.assoc_opt field fields with
  | None -> Ok None
  | Some value ->
      let* value = decoder path field value in
      Ok (Some value)

let decode_optional_path fields directory path field =
  let* value =
    decode_optional fields path field decode_path_string
  in
  Ok (Option.map (resolve_path ~directory) value)

let decode_optional_path_list fields directory path field =
  let* value =
    decode_optional fields path field decode_path_list
  in
  Ok (Option.map (List.map (resolve_path ~directory)) value)

let of_yojson ~path ~directory = function
  | `Assoc fields ->
      let* () = validate_known_fields path fields in
      let* program =
        decode_optional_path fields directory path "program"
      in
      let* entry = decode_optional fields path "entry" decode_string in
      let* include_paths =
        decode_optional_path_list fields directory path "includePaths"
      in
      let* skills_dir =
        decode_optional_path fields directory path "skillsDir"
      in
      let* provider = decode_optional fields path "provider" decode_provider in
      let* model = decode_optional fields path "model" decode_string in
      let* reasoning =
        decode_optional fields path "reasoning" decode_reasoning
      in
      let* provider_profile =
        decode_optional fields path "providerProfile" decode_string
      in
      let* provider_configs =
        decode_optional fields path "providerConfig" decode_provider_configs
      in
      let* sandbox = decode_optional fields path "sandbox" decode_sandbox in
      let* allow_write_dirs =
        decode_optional_path_list fields directory path "allowWriteDirs"
      in
      let* trace_provider =
        decode_optional fields path "traceProvider" decode_bool
      in
      Ok
        {
          path;
          directory;
          program;
          entry;
          include_paths;
          skills_dir;
          provider;
          model;
          reasoning;
          provider_profile;
          provider_configs;
          sandbox;
          allow_write_dirs;
          trace_provider;
        }
  | _ -> Error (invalid_root path "expected a JSON object")

let load_file path =
  let* source = read_text_file path in
  let* json =
    try Ok (Yojson.Safe.from_string source) with
    | Yojson.Json_error message ->
        Error
          (Printf.sprintf "failed to decode CamlFlow config %s: %s" path message)
  in
  of_yojson ~path ~directory:(Filename.dirname path) json

let rec find_nearest_path directory =
  let candidate = Filename.concat directory filename in
  if Sys.file_exists candidate then
    if Sys.is_directory candidate then
      Error
        (Printf.sprintf "CamlFlow config path must be a file, got directory: %s"
           candidate)
    else Ok (Some candidate)
  else
    let parent = Filename.dirname directory in
    if String.equal parent directory then Ok None else find_nearest_path parent

let load_nearest ~working_directory =
  let* path = find_nearest_path working_directory in
  match path with
  | None -> Ok None
  | Some path ->
      let* config = load_file path in
      Ok (Some config)
