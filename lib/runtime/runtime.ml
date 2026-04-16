module Context = Runtime_context

type execution_result = { steps_run : int }

let execute ?(context = Context.empty) (program : Syntax.Ast.program) :
    (execution_result, string) result =
  let _ = context in
  Ok { steps_run = List.length program }
