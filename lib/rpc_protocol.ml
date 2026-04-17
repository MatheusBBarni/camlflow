type id =
  | Int of int
  | String of string

let ( let* ) = Result.bind

let id_to_yojson = function
  | Int value -> `Int value
  | String value -> `String value

let id_of_yojson = function
  | `Int value -> Ok (Int value)
  | `String value -> Ok (String value)
  | _ -> Error "expected JSON-RPC id to be string or int"

let string_of_id = function
  | Int value -> string_of_int value
  | String value -> value

let request ?id ?params method_ =
  `Assoc
    ([ ("jsonrpc", `String "2.0"); ("method", `String method_) ]
    @
    match id with None -> [] | Some id -> [ ("id", id_to_yojson id) ]
    @
    match params with None -> [] | Some params -> [ ("params", params) ])

let success id result =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", id_to_yojson id);
      ("result", result);
    ]

let error ?id ?data ~code ~message () =
  let id_field =
    match id with
    | Some id -> id_to_yojson id
    | None -> `Null
  in
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", id_field);
      ( "error",
        `Assoc
          ([ ("code", `Int code); ("message", `String message) ]
          @ match data with None -> [] | Some data -> [ ("data", data) ]) );
    ]

type request_message = {
  request_id : id option;
  request_method : string;
  request_params : Yojson.Safe.t option;
}

type error_message = {
  error_code : int;
  error_message : string;
  error_data : Yojson.Safe.t option;
}

type response_message = {
  response_id : id option;
  response_result : Yojson.Safe.t option;
  response_error : error_message option;
}

let request_of_yojson = function
  | `Assoc fields ->
      let* version =
        match List.assoc_opt "jsonrpc" fields with
        | Some (`String version) -> Ok version
        | _ -> Error "missing jsonrpc version"
      in
      let* () = if String.equal version "2.0" then Ok () else Error "unsupported jsonrpc version" in
      let* request_method =
        match List.assoc_opt "method" fields with
        | Some (`String method_) -> Ok method_
        | _ -> Error "missing request method"
      in
      let request_id =
        match List.assoc_opt "id" fields with
        | None -> Ok None
        | Some value -> id_of_yojson value |> Result.map Option.some
      in
      let* request_id = request_id in
      let request_params = List.assoc_opt "params" fields in
      Ok { request_id; request_method; request_params }
  | _ -> Error "expected JSON-RPC request object"

let response_of_yojson = function
  | `Assoc fields ->
      let* version =
        match List.assoc_opt "jsonrpc" fields with
        | Some (`String version) -> Ok version
        | _ -> Error "missing jsonrpc version"
      in
      let* () = if String.equal version "2.0" then Ok () else Error "unsupported jsonrpc version" in
      let response_id =
        match List.assoc_opt "id" fields with
        | None | Some `Null -> Ok None
        | Some value -> id_of_yojson value |> Result.map Option.some
      in
      let* response_id = response_id in
      let response_result = List.assoc_opt "result" fields in
      let response_error =
        match List.assoc_opt "error" fields with
        | None -> Ok None
        | Some (`Assoc error_fields) ->
            let* error_code =
              match List.assoc_opt "code" error_fields with
              | Some (`Int code) -> Ok code
              | _ -> Error "JSON-RPC error missing code"
            in
            let* error_message =
              match List.assoc_opt "message" error_fields with
              | Some (`String message) -> Ok message
              | _ -> Error "JSON-RPC error missing message"
            in
            Ok
              (Some
                 {
                   error_code;
                   error_message;
                   error_data = List.assoc_opt "data" error_fields;
                 })
        | Some _ -> Error "JSON-RPC error field must be an object"
      in
      let* response_error = response_error in
      Ok { response_id; response_result; response_error }
  | _ -> Error "expected JSON-RPC response object"
