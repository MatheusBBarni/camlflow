module Env = Typing_env

type typed_program = Syntax.Ast.program
type error = string

let check ?(env = Env.empty) (program : Syntax.Ast.program) :
    (typed_program, error) result =
  let _ = env in
  Ok program
