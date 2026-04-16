type declaration =
  | Placeholder of string

 type program = declaration list

let empty : program = []
