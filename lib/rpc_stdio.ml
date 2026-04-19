let ( let* ) = Result.bind

let trim_trailing_cr line =
  let len = String.length line in
  if len > 0 && line.[len - 1] = '\r' then String.sub line 0 (len - 1) else line

let parse_content_length headers =
  let rec find = function
    | [] -> Error "missing Content-Length header"
    | header :: rest ->
        let normalized = String.lowercase_ascii header in
        let prefix = "content-length:" in
        if
          String.length normalized >= String.length prefix
          && String.sub normalized 0 (String.length prefix) = prefix
        then
          let raw =
            String.sub header (String.length prefix)
              (String.length header - String.length prefix)
            |> String.trim
          in
          try Ok (int_of_string raw)
          with Failure _ -> Error "invalid Content-Length header"
        else find rest
  in
  find headers

let read_headers channel =
  let rec loop acc =
    try
      let line = input_line channel |> trim_trailing_cr in
      if String.equal line "" then Ok (Some (List.rev acc))
      else loop (line :: acc)
    with End_of_file -> (
      match acc with
      | [] -> Ok None
      | _ -> Error "unexpected EOF while reading JSON-RPC headers")
  in
  loop []

let read_message channel =
  let* headers = read_headers channel in
  match headers with
  | None -> Ok None
  | Some headers -> (
      let* content_length = parse_content_length headers in
      let payload = really_input_string channel content_length in
      try Ok (Some (Yojson.Safe.from_string payload))
      with Yojson.Json_error message ->
        Error (Printf.sprintf "invalid JSON-RPC payload: %s" message))

let write_message channel json =
  let payload = Yojson.Safe.to_string json in
  output_string channel
    (Printf.sprintf "Content-Length: %d\r\n\r\n%s" (String.length payload)
       payload);
  flush channel;
  Ok ()
