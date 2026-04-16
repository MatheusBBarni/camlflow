type options = {
  include_paths : string list;
  output : string option;
  entry : string;
  input_file : string option;
  input_json : string option;
  skills_dir : string option;
}

let default_options =
  {
    include_paths = [];
    output = None;
    entry = "main";
    input_file = None;
    input_json = None;
    skills_dir = None;
  }

let usage () =
  Printf.eprintf
    "Usage:\n  camlflow parse <file>\n  camlflow check <file> [-I dir]\n  camlflow compile <file> [-I dir] [-o out.json]\n  camlflow run <file|artifact.json> [-I dir] [--entry name] [--input file.json|--input-json json] [--skills dir]\n";
  exit 1

let parse_flags options args =
  let rec loop options positionals = function
    | [] -> (options, List.rev positionals)
    | "-I" :: dir :: rest -> loop { options with include_paths = options.include_paths @ [ dir ] } positionals rest
    | "-o" :: path :: rest -> loop { options with output = Some path } positionals rest
    | "--entry" :: name :: rest -> loop { options with entry = name } positionals rest
    | "--input" :: path :: rest -> loop { options with input_file = Some path } positionals rest
    | "--input-json" :: json :: rest -> loop { options with input_json = Some json } positionals rest
    | "--skills" :: dir :: rest -> loop { options with skills_dir = Some dir } positionals rest
    | flag :: _ when String.length flag > 0 && flag.[0] = '-' ->
        Printf.eprintf "unknown flag: %s\n" flag;
        usage ()
    | arg :: rest -> loop options (arg :: positionals) rest
  in
  loop options [] args

let read_json_source = function
  | Some path, None -> In_channel.with_open_bin path In_channel.input_all |> Yojson.Safe.from_string
  | None, Some json -> Yojson.Safe.from_string json
  | None, None -> raise Not_found
  | Some _, Some _ -> failwith "use either --input or --input-json, not both"

let load_program include_paths path =
  if Filename.check_suffix path ".json" then
    let source = In_channel.with_open_bin path In_channel.input_all in
    Camlflow.Ir.of_json_string source
  else Camlflow.Typing.check_file ~include_paths path

let print_parse file =
  match Camlflow.Parsing.parse_file file with
  | Ok module_ ->
      Printf.printf "parsed %s (%d declarations)\n"
        (String.concat "." module_.Camlflow.Syntax.Ast.module_name)
        (List.length module_.Camlflow.Syntax.Ast.module_decls)
  | Error error ->
      prerr_endline error;
      exit 1

let print_check include_paths file =
  match Camlflow.Typing.check_file ~include_paths file with
  | Ok program ->
      Printf.printf "checked %d module(s)\n" (List.length program.Camlflow.Ir.modules)
  | Error error ->
      prerr_endline error;
      exit 1

let print_compile include_paths output file =
  match Camlflow.Typing.check_file ~include_paths file with
  | Ok program ->
      let json = Camlflow.Ir.to_json_string program in
      (match output with
      | Some path -> Out_channel.with_open_bin path (fun channel -> output_string channel json)
      | None -> print_endline json);
      Printf.printf "compiled %d module(s)\n" (List.length program.Camlflow.Ir.modules)
  | Error error ->
      prerr_endline error;
      exit 1

let print_run options file =
  match load_program options.include_paths file with
  | Error error ->
      prerr_endline error;
      exit 1
  | Ok program ->
      let context =
        let context = Camlflow.Runtime.Context.empty in
        let context = Camlflow.Runtime.Context.with_working_directory context (Sys.getcwd ()) in
        match options.skills_dir with
        | Some dir -> Camlflow.Runtime.Context.with_skills_directory context dir
        | None -> context
      in
      let input =
        try Some (read_json_source (options.input_file, options.input_json)) with
        | Not_found -> None
        | Failure message ->
            prerr_endline message;
            exit 1
        | Yojson.Json_error message ->
            prerr_endline message;
            exit 1
      in
      (match Camlflow.Runtime.execute ~context ~entry:options.entry ?input program with
      | Ok result ->
          Printf.printf "steps: %d\n" result.Camlflow.Runtime.steps_run;
          (match result.Camlflow.Runtime.output with
          | Some json -> print_endline (Yojson.Safe.pretty_to_string json)
          | None -> print_endline "null")
      | Error error ->
          prerr_endline error;
          exit 1)

let () =
  match Array.to_list Sys.argv with
  | _ :: command :: rest ->
      let options, args = parse_flags default_options rest in
      (match (command, args) with
      | "parse", [ file ] -> print_parse file
      | "check", [ file ] -> print_check options.include_paths file
      | "compile", [ file ] -> print_compile options.include_paths options.output file
      | "run", [ file ] -> print_run options file
      | _ -> usage ())
  | _ ->
      Printf.printf "camlflow %s\n%s\n" Camlflow.version Camlflow.about;
      usage ()
