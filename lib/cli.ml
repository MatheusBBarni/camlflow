type command =
  | Help
  | Parse
  | Check
  | Compile
  | Run
  | Completion

type shell = Bash | Zsh | Fish

type options = {
  include_paths : string list;
  output : string option;
  entry : string;
  input_file : string option;
  input_json : string option;
  skills_dir : string option;
}

type parsed = {
  command : command;
  options : options;
  positionals : string list;
  help_topic : command option;
  completion_shell : shell option;
}

type flag_parse = {
  options : options;
  positionals : string list;
  help_requested : bool;
}

let ( let* ) = Result.bind

let default_options =
  {
    include_paths = [];
    output = None;
    entry = "main";
    input_file = None;
    input_json = None;
    skills_dir = None;
  }

let command_name = function
  | Help -> "help"
  | Parse -> "parse"
  | Check -> "check"
  | Compile -> "compile"
  | Run -> "run"
  | Completion -> "completion"

let shell_name = function Bash -> "bash" | Zsh -> "zsh" | Fish -> "fish"

let all_commands = [ Help; Parse; Check; Compile; Run; Completion ]
let public_commands = [ Parse; Check; Compile; Run; Completion ]
let public_command_names = List.map command_name public_commands
let shell_names = [ "bash"; "zsh"; "fish" ]

let usage_text =
  String.concat "\n"
    [
      "CamlFlow CLI";
      "";
      "Usage:";
      "  camlflow help [command]";
      "  camlflow parse <file.cml>";
      "  camlflow check <file.cml> [-I dir]...";
      "  camlflow compile <file.cml> [-I dir]... [-o artifact.json]";
      "  camlflow run <file.cml|artifact.json> [-I dir]... [--entry name]";
      "               [--input file.json | --input-json json] [--skills dir]";
      "  camlflow completion <bash|zsh|fish>";
      "";
      "Commands:";
      "  parse        Parse one CamlFlow source file and report declaration count";
      "  check        Load, resolve, and type-check a CamlFlow program";
      "  compile      Type-check and emit JSON IR";
      "  run          Execute from source or compiled JSON IR";
      "  completion   Emit a shell completion script";
      "";
      "Common options:";
      "  -h, --help        Show help text";
      "  -I <dir>          Add an include path for module resolution";
      "";
      "Run options:";
      "  --entry <name>    Entrypoint to run (default: main)";
      "  --input <path>    Read entrypoint JSON input from a file";
      "  --input-json <j>  Read entrypoint JSON input from an inline JSON string";
      "  --skills <dir>    Resolve local skills from <dir>/<name>/SKILL.md";
      "";
      "Examples:";
      "  camlflow help run";
      "  camlflow parse examples/basic/main.cml";
      "  camlflow check examples/qualified-imports/main.cml";
      "  camlflow compile examples/basic/main.cml -o /tmp/basic.ir.json";
      "  camlflow run examples/basic/main.cml --input-json '\"Ada\"'";
      "  camlflow completion bash > /tmp/camlflow.bash";
    ]

let parse_help_text =
  String.concat "\n"
    [
      "Command: parse";
      "";
      "Usage:";
      "  camlflow parse <file.cml>";
      "";
      "Description:";
      "  Parse a single CamlFlow source file and report the module name and";
      "  declaration count.";
      "";
      "Accepted flags:";
      "  -h, --help";
      "";
      "Example:";
      "  camlflow parse examples/basic/main.cml";
    ]

let check_help_text =
  String.concat "\n"
    [
      "Command: check";
      "";
      "Usage:";
      "  camlflow check <file.cml> [-I dir]...";
      "";
      "Description:";
      "  Load, resolve, and type-check a CamlFlow program rooted at the given";
      "  source file.";
      "";
      "Accepted flags:";
      "  -h, --help";
      "  -I <dir>";
      "";
      "Example:";
      "  camlflow check examples/qualified-imports/main.cml";
    ]

let compile_help_text =
  String.concat "\n"
    [
      "Command: compile";
      "";
      "Usage:";
      "  camlflow compile <file.cml> [-I dir]... [-o artifact.json]";
      "";
      "Description:";
      "  Type-check a source program and emit JSON IR to stdout or a file.";
      "";
      "Accepted flags:";
      "  -h, --help";
      "  -I <dir>";
      "  -o <path>";
      "";
      "Example:";
      "  camlflow compile examples/basic/main.cml -o /tmp/basic.ir.json";
    ]

let run_help_text =
  String.concat "\n"
    [
      "Command: run";
      "";
      "Usage:";
      "  camlflow run <file.cml|artifact.json> [-I dir]... [--entry name]";
      "               [--input file.json | --input-json json] [--skills dir]";
      "";
      "Description:";
      "  Execute a CamlFlow program from source or a compiled JSON IR artifact.";
      "";
      "Accepted flags:";
      "  -h, --help";
      "  -I <dir>";
      "  --entry <name>";
      "  --input <path>";
      "  --input-json <json>";
      "  --skills <dir>";
      "";
      "Examples:";
      "  camlflow run examples/basic/main.cml --input-json '\"Ada\"'";
      "  camlflow run /tmp/basic.ir.json --input-json '\"Ada\"'";
    ]

let completion_help_text =
  String.concat "\n"
    [
      "Command: completion";
      "";
      "Usage:";
      "  camlflow completion <bash|zsh|fish>";
      "";
      "Description:";
      "  Emit a shell completion script for the requested shell.";
      "";
      "Examples:";
      "  camlflow completion bash > ~/.local/share/bash-completion/completions/camlflow";
      "  camlflow completion zsh > ~/.zfunc/_camlflow";
      "  camlflow completion fish > ~/.config/fish/completions/camlflow.fish";
    ]

let help_text = function
  | None | Some Help -> usage_text
  | Some Parse -> parse_help_text
  | Some Check -> check_help_text
  | Some Compile -> compile_help_text
  | Some Run -> run_help_text
  | Some Completion -> completion_help_text

let command_of_string = function
  | "help" -> Ok Help
  | "parse" -> Ok Parse
  | "check" -> Ok Check
  | "compile" -> Ok Compile
  | "run" -> Ok Run
  | "completion" -> Ok Completion
  | other -> Error (Printf.sprintf "unknown command: %s" other)

let shell_of_string = function
  | "bash" -> Ok Bash
  | "zsh" -> Ok Zsh
  | "fish" -> Ok Fish
  | other ->
      Error
        (Printf.sprintf "unknown shell %s; expected one of: %s" other
           (String.concat ", " shell_names))

let parse_flags args =
  let rec loop options positionals = function
    | [] -> Ok { options; positionals = List.rev positionals; help_requested = false }
    | ("-h" | "--help") :: _ ->
        Ok { options; positionals = List.rev positionals; help_requested = true }
    | "-I" :: dir :: rest ->
        loop { options with include_paths = options.include_paths @ [ dir ] }
          positionals rest
    | "-o" :: path :: rest ->
        loop { options with output = Some path } positionals rest
    | "--entry" :: name :: rest ->
        loop { options with entry = name } positionals rest
    | "--input" :: path :: rest ->
        loop { options with input_file = Some path } positionals rest
    | "--input-json" :: json :: rest ->
        loop { options with input_json = Some json } positionals rest
    | "--skills" :: dir :: rest ->
        loop { options with skills_dir = Some dir } positionals rest
    | ("-I" | "-o" | "--entry" | "--input" | "--input-json" | "--skills")
      :: [] as trailing ->
        Error (Printf.sprintf "missing value for flag %s" (List.hd trailing))
    | flag :: _ when String.length flag > 0 && flag.[0] = '-' ->
        Error (Printf.sprintf "unknown flag: %s" flag)
    | arg :: rest -> loop options (arg :: positionals) rest
  in
  loop default_options [] args

let parse_help_command = function
  | [] ->
      Ok
        {
          command = Help;
          options = default_options;
          positionals = [];
          help_topic = None;
          completion_shell = None;
        }
  | [ topic ] ->
      let* topic = command_of_string topic in
      Ok
        {
          command = Help;
          options = default_options;
          positionals = [];
          help_topic = Some topic;
          completion_shell = None;
        }
  | _ -> Error "help accepts at most one command argument"

let parse_completion_command = function
  | [] -> Error "completion expects exactly one shell argument: bash, zsh, or fish"
  | [ ("-h" | "--help") ] ->
      Ok
        {
          command = Help;
          options = default_options;
          positionals = [];
          help_topic = Some Completion;
          completion_shell = None;
        }
  | [ shell ] ->
      let* shell = shell_of_string shell in
      Ok
        {
          command = Completion;
          options = default_options;
          positionals = [];
          help_topic = None;
          completion_shell = Some shell;
        }
  | _ -> Error "completion expects exactly one shell argument: bash, zsh, or fish"

let parse_regular_command command args =
  let* parsed_flags = parse_flags args in
  if parsed_flags.help_requested then
    Ok
      {
        command = Help;
        options = default_options;
        positionals = [];
        help_topic = Some command;
        completion_shell = None;
      }
  else
    Ok
      {
        command;
        options = parsed_flags.options;
        positionals = parsed_flags.positionals;
        help_topic = None;
        completion_shell = None;
      }

let parse_argv argv =
  match argv with
  | [] | [ "-h" ] | [ "--help" ] ->
      Ok
        {
          command = Help;
          options = default_options;
          positionals = [];
          help_topic = None;
          completion_shell = None;
        }
  | "help" :: rest -> parse_help_command rest
  | "completion" :: rest -> parse_completion_command rest
  | command :: rest ->
      let* command = command_of_string command in
      parse_regular_command command rest

let ensure_no_flags command_name flags =
  match List.filter_map Fun.id flags with
  | [] -> Ok ()
  | flags ->
      Error
        (Printf.sprintf "%s does not accept %s" command_name
           (String.concat ", " (List.map (Printf.sprintf "flag %s") flags)))

let ensure_exactly_one_file command_name positionals =
  match positionals with
  | [ file ] -> Ok file
  | [] -> Error (Printf.sprintf "%s expects exactly one file argument" command_name)
  | _ ->
      Error
        (Printf.sprintf "%s expects exactly one file argument, got %d"
           command_name (List.length positionals))

let validate (parsed : parsed) =
  let options = parsed.options in
  match parsed.command with
  | Help -> Ok ()
  | Completion ->
      let* _ =
        match parsed.completion_shell with
        | Some _ -> Ok ()
        | None -> Error "completion requires a shell target"
      in
      let disallowed =
        [
          (match options.include_paths with [] -> None | _ -> Some "-I");
          Option.map (Fun.const "-o") options.output;
          (if options.entry = "main" then None else Some "--entry");
          Option.map (Fun.const "--input") options.input_file;
          Option.map (Fun.const "--input-json") options.input_json;
          Option.map (Fun.const "--skills") options.skills_dir;
        ]
      in
      ensure_no_flags "completion" disallowed
  | Parse ->
      let* _ = ensure_exactly_one_file "parse" parsed.positionals in
      let disallowed =
        [
          (match options.include_paths with [] -> None | _ -> Some "-I");
          Option.map (Fun.const "-o") options.output;
          (if options.entry = "main" then None else Some "--entry");
          Option.map (Fun.const "--input") options.input_file;
          Option.map (Fun.const "--input-json") options.input_json;
          Option.map (Fun.const "--skills") options.skills_dir;
        ]
      in
      ensure_no_flags "parse" disallowed
  | Check ->
      let* _ = ensure_exactly_one_file "check" parsed.positionals in
      let disallowed =
        [
          Option.map (Fun.const "-o") options.output;
          (if options.entry = "main" then None else Some "--entry");
          Option.map (Fun.const "--input") options.input_file;
          Option.map (Fun.const "--input-json") options.input_json;
          Option.map (Fun.const "--skills") options.skills_dir;
        ]
      in
      ensure_no_flags "check" disallowed
  | Compile ->
      let* _ = ensure_exactly_one_file "compile" parsed.positionals in
      let disallowed =
        [
          (if options.entry = "main" then None else Some "--entry");
          Option.map (Fun.const "--input") options.input_file;
          Option.map (Fun.const "--input-json") options.input_json;
          Option.map (Fun.const "--skills") options.skills_dir;
        ]
      in
      ensure_no_flags "compile" disallowed
  | Run ->
      let* _ = ensure_exactly_one_file "run" parsed.positionals in
      let* () =
        match (options.input_file, options.input_json) with
        | Some _, Some _ -> Error "run accepts either --input or --input-json, not both"
        | _ -> Ok ()
      in
      match options.output with
      | Some _ -> Error "run does not accept flag -o"
      | None -> Ok ()

let bash_completion_script =
  String.concat "\n"
    [
      "_camlflow_complete() {";
      "  local cur prev cmd";
      "  cur=\"${COMP_WORDS[COMP_CWORD]}\"";
      "  prev=\"${COMP_WORDS[COMP_CWORD-1]}\"";
      "  cmd=\"${COMP_WORDS[1]}\"";
      "";
      "  case \"$prev\" in";
      "    -I|--skills) COMPREPLY=( $(compgen -d -- \"$cur\") ); return 0 ;;";
      "    -o|--input) COMPREPLY=( $(compgen -f -- \"$cur\") ); return 0 ;;";
      "    --entry) return 0 ;;";
      "  esac";
      "";
      "  if [[ ${COMP_CWORD} -eq 1 ]]; then";
      "    COMPREPLY=( $(compgen -W \"help parse check compile run completion\" -- \"$cur\") )";
      "    return 0";
      "  fi";
      "";
      "  case \"$cmd\" in";
      "    help)";
      "      COMPREPLY=( $(compgen -W \"parse check compile run completion\" -- \"$cur\") ) ;;";
      "    completion)";
      "      COMPREPLY=( $(compgen -W \"bash zsh fish\" -- \"$cur\") ) ;;";
      "    parse)";
      "      COMPREPLY=( $(compgen -W \"-h --help\" -- \"$cur\") $(compgen -f -- \"$cur\") ) ;;";
      "    check)";
      "      COMPREPLY=( $(compgen -W \"-h --help -I\" -- \"$cur\") $(compgen -f -- \"$cur\") ) ;;";
      "    compile)";
      "      COMPREPLY=( $(compgen -W \"-h --help -I -o\" -- \"$cur\") $(compgen -f -- \"$cur\") ) ;;";
      "    run)";
      "      COMPREPLY=( $(compgen -W \"-h --help -I --entry --input --input-json --skills\" -- \"$cur\") $(compgen -f -- \"$cur\") ) ;;";
      "    *) COMPREPLY=() ;;";
      "  esac";
      "}";
      "complete -F _camlflow_complete camlflow";
    ]

let zsh_completion_script =
  String.concat "\n"
    [
      "#compdef camlflow";
      "";
      "local -a commands";
      "commands=(";
      "  'help:show help'";
      "  'parse:parse a source file'";
      "  'check:type-check a source file'";
      "  'compile:compile to JSON IR'";
      "  'run:run a source file or artifact'";
      "  'completion:emit shell completion script'";
      ")";
      "";
      "if (( CURRENT == 2 )); then";
      "  _describe 'command' commands";
      "  return";
      "fi";
      "";
      "case $words[2] in";
      "  help) _values 'command' parse check compile run completion ;;";
      "  completion) _values 'shell' bash zsh fish ;;";
      "  parse) _arguments '-h[show help]' '--help[show help]' '*:file:_files' ;;";
      "  check) _arguments '-h[show help]' '--help[show help]' '-I+[include path]:dir:_files -/' '*:file:_files' ;;";
      "  compile) _arguments '-h[show help]' '--help[show help]' '-I+[include path]:dir:_files -/' '-o+[output file]:file:_files' '*:file:_files' ;;";
      "  run) _arguments '-h[show help]' '--help[show help]' '-I+[include path]:dir:_files -/' '--entry+[entrypoint name]:entry' '--input+[json file]:file:_files' '--input-json+[inline json]:json' '--skills+[skills directory]:dir:_files -/' '*:file:_files' ;;";
      "esac";
    ]

let fish_completion_script =
  String.concat "\n"
    [
      "complete -c camlflow -f";
      "complete -c camlflow -n '__fish_use_subcommand' -a help -d 'Show help'";
      "complete -c camlflow -n '__fish_use_subcommand' -a parse -d 'Parse a source file'";
      "complete -c camlflow -n '__fish_use_subcommand' -a check -d 'Type-check a source file'";
      "complete -c camlflow -n '__fish_use_subcommand' -a compile -d 'Compile to JSON IR'";
      "complete -c camlflow -n '__fish_use_subcommand' -a run -d 'Run a source file or artifact'";
      "complete -c camlflow -n '__fish_use_subcommand' -a completion -d 'Emit shell completion script'";
      "";
      "complete -c camlflow -n '__fish_seen_subcommand_from help' -a parse check compile run completion";
      "complete -c camlflow -n '__fish_seen_subcommand_from completion' -a bash zsh fish";
      "";
      "complete -c camlflow -n '__fish_seen_subcommand_from parse check compile run' -s h -l help -d 'Show help'";
      "complete -c camlflow -n '__fish_seen_subcommand_from check compile run' -s I -d 'Add include path' -r -a '(__fish_complete_directories)'";
      "complete -c camlflow -n '__fish_seen_subcommand_from compile' -s o -d 'Write artifact to file' -r";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l entry -d 'Entrypoint name' -r";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l input -d 'JSON input file' -r";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l input-json -d 'Inline JSON input' -r";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l skills -d 'Skills directory' -r -a '(__fish_complete_directories)'";
    ]

let completion_script = function
  | Bash -> bash_completion_script
  | Zsh -> zsh_completion_script
  | Fish -> fish_completion_script
