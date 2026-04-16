type error = string

let parse_string (source : string) : (Syntax.Ast.program, error) result =
  let _ = source in
  Ok Syntax.Ast.empty
