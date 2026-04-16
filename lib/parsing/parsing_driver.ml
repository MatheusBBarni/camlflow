type error = string

let ( let* ) = Result.bind

let module_name_of_basename (path : string) : Syntax.Ast.qname =
  let base = path |> Filename.basename |> Filename.remove_extension in
  [ String.capitalize_ascii base ]

let parse_module ?(module_name = [ "Main" ]) ~path (source : string) :
    (Syntax.Ast.module_, error) result =
  let rewritten = Parsing_lower.rewrite_custom_declarations source in
  let lexbuf = Lexing.from_string rewritten in
  lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = path };
  try
    let structure = Parse.implementation lexbuf in
    Ok (Parsing_lower.lower_module ~module_name ~path structure)
  with
  | Parsing_lower.Error message -> Error message
  | exn -> Error (Printexc.to_string exn)

let parse_string ?(path = "<string>") (source : string) :
    (Syntax.Ast.program, error) result =
  let module_name = [ "Main" ] in
  let* module_ = parse_module ~module_name ~path source in
  Ok { Syntax.Ast.root_module = module_name; modules = [ module_ ] }

let parse_file ?module_name (path : string) : (Syntax.Ast.module_, error) result =
  let source = In_channel.with_open_bin path In_channel.input_all in
  parse_module ?module_name ~path source
