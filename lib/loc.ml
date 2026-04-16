type position = {
  line : int;
  column : int;
  offset : int;
}

type t = {
  file : string;
  start_pos : position;
  end_pos : position;
}

let ( let* ) = Result.bind

let make_position (pos : Lexing.position) : position =
  {
    line = pos.pos_lnum;
    column = pos.pos_cnum - pos.pos_bol;
    offset = pos.pos_cnum;
  }

let of_location (loc : Location.t) : t =
  {
    file = loc.loc_start.pos_fname;
    start_pos = make_position loc.loc_start;
    end_pos = make_position loc.loc_end;
  }

let none : t =
  {
    file = "";
    start_pos = { line = 0; column = 0; offset = 0 };
    end_pos = { line = 0; column = 0; offset = 0 };
  }

let to_string (loc : t) : string =
  Printf.sprintf "%s:%d:%d-%d:%d" loc.file loc.start_pos.line loc.start_pos.column
    loc.end_pos.line loc.end_pos.column

let position_to_yojson (pos : position) : Yojson.Safe.t =
  `Assoc
    [
      ("line", `Int pos.line);
      ("column", `Int pos.column);
      ("offset", `Int pos.offset);
    ]

let to_yojson (loc : t) : Yojson.Safe.t =
  `Assoc
    [
      ("file", `String loc.file);
      ("start", position_to_yojson loc.start_pos);
      ("end", position_to_yojson loc.end_pos);
    ]

let position_of_yojson = function
  | `Assoc fields ->
      let find_int name =
        match List.assoc_opt name fields with
        | Some (`Int value) -> Ok value
        | _ -> Error (Printf.sprintf "missing integer field %s" name)
      in
      let* line = find_int "line" in
      let* column = find_int "column" in
      let* offset = find_int "offset" in
      Ok { line; column; offset }
  | _ -> Error "expected JSON object for location position"

let of_yojson = function
  | `Assoc fields ->
      let find_string name =
        match List.assoc_opt name fields with
        | Some (`String value) -> Ok value
        | _ -> Error (Printf.sprintf "missing string field %s" name)
      in
      let find_pos name =
        match List.assoc_opt name fields with
        | Some value -> position_of_yojson value
        | None -> Error (Printf.sprintf "missing location field %s" name)
      in
      let* file = find_string "file" in
      let* start_pos = find_pos "start" in
      let* end_pos = find_pos "end" in
      Ok { file; start_pos; end_pos }
  | _ -> Error "expected JSON object for location"
