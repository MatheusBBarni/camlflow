type command =
  | Help
  | Parse
  | Check
  | Compile
  | Run
  | Serve
  | Completion

type shell = Bash | Zsh | Fish

type options = {
  include_paths : string list;
  output : string option;
  entry : string;
  input_file : string option;
  input_json : string option;
  skills_dir : string option;
  rpc_stdio : bool;
  provider_options : Provider.settings;
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
    rpc_stdio = false;
    provider_options = Provider.default_settings;
  }

let command_name = function
  | Help -> "help"
  | Parse -> "parse"
  | Check -> "check"
  | Compile -> "compile"
  | Run -> "run"
  | Serve -> "serve"
  | Completion -> "completion"

let shell_name = function Bash -> "bash" | Zsh -> "zsh" | Fish -> "fish"

let all_commands = [ Help; Parse; Check; Compile; Run; Serve; Completion ]
let public_commands = [ Parse; Check; Compile; Run; Serve; Completion ]
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
      "               [--provider codex] [--model name] [--reasoning level]";
      "               [--provider-profile name] [--provider-config key=value]...";
      "               [--sandbox mode] [--allow-write-dir dir]... [--trace-provider]";
      "  camlflow serve --stdio";
      "  camlflow completion <bash|zsh|fish>";
      "";
      "Commands:";
      "  parse        Parse one CamlFlow source file and report declaration count";
      "  check        Load, resolve, and type-check a CamlFlow program";
      "  compile      Type-check and emit JSON IR";
      "  run          Execute from source or compiled JSON IR";
      "  serve        Start the JSON-RPC stdio server";
      "  completion   Emit a shell completion script";
      "";
      "Common options:";
      "  -h, --help              Show help text";
      "  -I <dir>                Add an include path for module resolution";
      "";
      "Run options:";
      "  --entry <name>          Entrypoint to run (default: main)";
      "  --input <path>          Read entrypoint JSON input from a file";
      "  --input-json <j>        Read entrypoint JSON input from an inline JSON string";
      "  --skills <dir>          Resolve local skills from <dir>/<name>/SKILL.md";
      "  --provider <name>       Provider to use for unresolved effects (codex)";
      "  --model <name>          Override provider model when the workflow does not set one";
      "  --reasoning <level>     Provider-agnostic reasoning level: low, medium, high, max";
      "  --provider-profile <n>  Provider profile name";
      "  --provider-config <kv>  Provider config override in key=value form (repeatable)";
      "  --sandbox <mode>        Sandbox mode: read-only, workspace-write, danger-full-access";
      "  --allow-write-dir <d>   Extra writable directory for provider execution (repeatable)";
      "  --trace-provider        Print provider step trace metadata to stderr";
      "  --stdio                 Use stdio transport for serve";
      "";
      "Examples:";
      "  camlflow help run";
      "  camlflow parse examples/basic/main.cml";
      "  camlflow check examples/qualified-imports/main.cml";
      "  camlflow compile examples/basic/main.cml -o /tmp/basic.ir.json";
      "  camlflow run examples/basic/main.cml --input-json '\"Ada\"'";
      "  camlflow run examples/basic/main.cml --input-json '\"Ada\"' --provider codex --model gpt-5.4-mini";
      "  camlflow serve --stdio";
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
      "               [--provider codex] [--model name] [--reasoning level]";
      "               [--provider-profile name] [--provider-config key=value]...";
      "               [--sandbox mode] [--allow-write-dir dir]... [--trace-provider]";
      "";
      "Description:";
      "  Execute a CamlFlow program from source or a compiled JSON IR artifact.";
      "  Provider-backed execution remains opt-in through --provider.";
      "";
      "Accepted flags:";
      "  -h, --help";
      "  -I <dir>";
      "  --entry <name>";
      "  --input <path>";
      "  --input-json <json>";
      "  --skills <dir>";
      "  --provider <name>";
      "  --model <name>";
      "  --reasoning <level>";
      "  --provider-profile <name>";
      "  --provider-config <key=value>";
      "  --sandbox <mode>";
      "  --allow-write-dir <dir>";
      "  --trace-provider";
      "";
      "Examples:";
      "  camlflow run examples/basic/main.cml --input-json '\"Ada\"'";
      "  camlflow run /tmp/basic.ir.json --input-json '\"Ada\"'";
      "  camlflow run examples/basic/main.cml --input-json '\"Ada\"' --provider codex --model gpt-5.4-mini";
    ]

let serve_help_text =
  String.concat "\n"
    [
      "Command: serve";
      "";
      "Usage:";
      "  camlflow serve --stdio";
      "";
      "Description:";
      "  Start CamlFlow as a JSON-RPC 2.0 server over stdio.";
      "";
      "Accepted flags:";
      "  -h, --help";
      "  --stdio";
      "";
      "Example:";
      "  camlflow serve --stdio";
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
  | Some Serve -> serve_help_text
  | Some Completion -> completion_help_text

let command_of_string = function
  | "help" -> Ok Help
  | "parse" -> Ok Parse
  | "check" -> Ok Check
  | "compile" -> Ok Compile
  | "run" -> Ok Run
  | "serve" -> Ok Serve
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
    | "--provider" :: name :: rest ->
        let* provider = Provider.name_of_string name in
        let provider_options =
          { options.provider_options with provider = Some provider }
        in
        loop { options with provider_options } positionals rest
    | "--model" :: name :: rest ->
        let provider_options =
          { options.provider_options with model = Some name }
        in
        loop { options with provider_options } positionals rest
    | "--reasoning" :: level :: rest ->
        let* reasoning = Provider.reasoning_of_string level in
        let provider_options =
          { options.provider_options with reasoning = Some reasoning }
        in
        loop { options with provider_options } positionals rest
    | "--provider-profile" :: profile :: rest ->
        let provider_options =
          { options.provider_options with provider_profile = Some profile }
        in
        loop { options with provider_options } positionals rest
    | "--provider-config" :: config :: rest ->
        let* config = Provider.config_of_string config in
        let provider_options =
          {
            options.provider_options with
            provider_configs = options.provider_options.provider_configs @ [ config ];
          }
        in
        loop { options with provider_options } positionals rest
    | "--sandbox" :: mode :: rest ->
        let* sandbox = Provider.sandbox_of_string mode in
        let provider_options = { options.provider_options with sandbox } in
        loop { options with provider_options } positionals rest
    | "--allow-write-dir" :: dir :: rest ->
        let provider_options =
          {
            options.provider_options with
            allow_write_dirs = options.provider_options.allow_write_dirs @ [ dir ];
          }
        in
        loop { options with provider_options } positionals rest
    | "--trace-provider" :: rest ->
        let provider_options =
          { options.provider_options with trace_provider = true }
        in
        loop { options with provider_options } positionals rest
    | "--stdio" :: rest -> loop { options with rpc_stdio = true } positionals rest
    | ( "-I" | "-o" | "--entry" | "--input" | "--input-json" | "--skills"
      | "--provider" | "--model" | "--reasoning" | "--provider-profile"
      | "--provider-config" | "--sandbox" | "--allow-write-dir" )
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

let provider_disallowed_flags (settings : Provider.settings) =
  [
    Option.map (Fun.const "--provider") settings.provider;
    Option.map (Fun.const "--model") settings.model;
    Option.map (Fun.const "--reasoning") settings.reasoning;
    Option.map (Fun.const "--provider-profile") settings.provider_profile;
    (match settings.provider_configs with [] -> None | _ -> Some "--provider-config");
    (if settings.sandbox = Provider.default_sandbox then None else Some "--sandbox");
    (match settings.allow_write_dirs with [] -> None | _ -> Some "--allow-write-dir");
    (if settings.trace_provider then Some "--trace-provider" else None);
  ]

let explicit_provider_dependency_flags (settings : Provider.settings) =
  [
    Option.map (Fun.const "--model") settings.model;
    Option.map (Fun.const "--reasoning") settings.reasoning;
    Option.map (Fun.const "--provider-profile") settings.provider_profile;
    (match settings.provider_configs with [] -> None | _ -> Some "--provider-config");
    (if settings.sandbox = Provider.default_sandbox then None else Some "--sandbox");
    (match settings.allow_write_dirs with [] -> None | _ -> Some "--allow-write-dir");
    (if settings.trace_provider then Some "--trace-provider" else None);
  ]

let ensure_provider_selected settings =
  match List.filter_map Fun.id (explicit_provider_dependency_flags settings) with
  | [] -> Ok ()
  | flags ->
      Error
        (Printf.sprintf "run requires --provider when using %s"
           (String.concat ", " (List.map (Printf.sprintf "flag %s") flags)))

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
          (if options.rpc_stdio then Some "--stdio" else None);
        ]
        @ provider_disallowed_flags options.provider_options
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
        @ provider_disallowed_flags options.provider_options
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
        @ provider_disallowed_flags options.provider_options
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
        @ provider_disallowed_flags options.provider_options
      in
      ensure_no_flags "compile" disallowed
  | Run ->
      let* _ = ensure_exactly_one_file "run" parsed.positionals in
      let* () =
        match (options.input_file, options.input_json) with
        | Some _, Some _ -> Error "run accepts either --input or --input-json, not both"
        | _ -> Ok ()
      in
      let* () =
        match options.provider_options.provider with
        | Some _ -> Ok ()
        | None -> ensure_provider_selected options.provider_options
      in
      let* () = if options.rpc_stdio then Error "run does not accept flag --stdio" else Ok () in
      let* () =
        match options.output with
        | Some _ -> Error "run does not accept flag -o"
        | None -> Ok ()
      in
      Ok ()
  | Serve ->
      let* () =
        match parsed.positionals with
        | [] -> Ok ()
        | _ -> Error "serve does not accept positional arguments"
      in
      let* () = if options.rpc_stdio then Ok () else Error "serve requires flag --stdio" in
      let disallowed =
        [
          (match options.include_paths with [] -> None | _ -> Some "-I");
          Option.map (Fun.const "-o") options.output;
          (if options.entry = "main" then None else Some "--entry");
          Option.map (Fun.const "--input") options.input_file;
          Option.map (Fun.const "--input-json") options.input_json;
          Option.map (Fun.const "--skills") options.skills_dir;
        ]
        @ provider_disallowed_flags options.provider_options
      in
      ensure_no_flags "serve" disallowed

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
      "    -I|--skills|--allow-write-dir) COMPREPLY=( $(compgen -d -- \"$cur\") ); return 0 ;;";
      "    -o|--input) COMPREPLY=( $(compgen -f -- \"$cur\") ); return 0 ;;";
      "    --provider) COMPREPLY=( $(compgen -W \"codex\" -- \"$cur\") ); return 0 ;;";
      "    --reasoning) COMPREPLY=( $(compgen -W \"low medium high max\" -- \"$cur\") ); return 0 ;;";
      "    --sandbox) COMPREPLY=( $(compgen -W \"read-only workspace-write danger-full-access\" -- \"$cur\") ); return 0 ;;";
      "    --entry|--model|--provider-profile|--provider-config) return 0 ;;";
      "  esac";
      "";
      "  if [[ ${COMP_CWORD} -eq 1 ]]; then";
      "    COMPREPLY=( $(compgen -W \"help parse check compile run serve completion\" -- \"$cur\") )";
      "    return 0";
      "  fi";
      "";
      "  case \"$cmd\" in";
      "    help)";
      "      COMPREPLY=( $(compgen -W \"parse check compile run serve completion\" -- \"$cur\") ) ;;";
      "    serve)";
      "      COMPREPLY=( $(compgen -W \"-h --help --stdio\" -- \"$cur\") ) ;;";
      "    completion)";
      "      COMPREPLY=( $(compgen -W \"bash zsh fish\" -- \"$cur\") ) ;;";
      "    parse)";
      "      COMPREPLY=( $(compgen -W \"-h --help\" -- \"$cur\") $(compgen -f -- \"$cur\") ) ;;";
      "    check)";
      "      COMPREPLY=( $(compgen -W \"-h --help -I\" -- \"$cur\") $(compgen -f -- \"$cur\") ) ;;";
      "    compile)";
      "      COMPREPLY=( $(compgen -W \"-h --help -I -o\" -- \"$cur\") $(compgen -f -- \"$cur\") ) ;;";
      "    run)";
      "      COMPREPLY=( $(compgen -W \"-h --help -I --entry --input --input-json --skills --provider --model --reasoning --provider-profile --provider-config --sandbox --allow-write-dir --trace-provider\" -- \"$cur\") $(compgen -f -- \"$cur\") ) ;;";
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
      "  'serve:start the JSON-RPC stdio server'";
      "  'completion:emit shell completion script'";
      ")";
      "";
      "if (( CURRENT == 2 )); then";
      "  _describe 'command' commands";
      "  return";
      "fi";
      "";
      "case $words[2] in";
      "  help) _values 'command' parse check compile run serve completion ;;";
      "  serve) _arguments '-h[show help]' '--help[show help]' '--stdio[use stdio transport]' ;;";
      "  completion) _values 'shell' bash zsh fish ;;";
      "  parse) _arguments '-h[show help]' '--help[show help]' '*:file:_files' ;;";
      "  check) _arguments '-h[show help]' '--help[show help]' '-I+[include path]:dir:_files -/' '*:file:_files' ;;";
      "  compile) _arguments '-h[show help]' '--help[show help]' '-I+[include path]:dir:_files -/' '-o+[output file]:file:_files' '*:file:_files' ;;";
      "  run) _arguments '-h[show help]' '--help[show help]' '-I+[include path]:dir:_files -/' '--entry+[entrypoint name]:entry' '--input+[json file]:file:_files' '--input-json+[inline json]:json' '--skills+[skills directory]:dir:_files -/' '--provider+[provider name]:provider:(codex)' '--model+[provider model]:model' '--reasoning+[reasoning level]:reasoning:(low medium high max)' '--provider-profile+[provider profile]:profile' '--provider-config+[provider config override]:config' '--sandbox+[sandbox mode]:sandbox:(read-only workspace-write danger-full-access)' '--allow-write-dir+[extra writable directory]:dir:_files -/' '--trace-provider[print provider step trace metadata]' '*:file:_files' ;;";
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
      "complete -c camlflow -n '__fish_use_subcommand' -a serve -d 'Start the JSON-RPC stdio server'";
      "complete -c camlflow -n '__fish_use_subcommand' -a completion -d 'Emit shell completion script'";
      "";
      "complete -c camlflow -n '__fish_seen_subcommand_from help' -a parse check compile run serve completion";
      "complete -c camlflow -n '__fish_seen_subcommand_from completion' -a bash zsh fish";
      "";
      "complete -c camlflow -n '__fish_seen_subcommand_from parse check compile run serve' -s h -l help -d 'Show help'";
      "complete -c camlflow -n '__fish_seen_subcommand_from check compile run' -s I -d 'Add include path' -r -a '(__fish_complete_directories)'";
      "complete -c camlflow -n '__fish_seen_subcommand_from compile' -s o -d 'Write artifact to file' -r";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l entry -d 'Entrypoint name' -r";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l input -d 'JSON input file' -r";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l input-json -d 'Inline JSON input' -r";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l skills -d 'Skills directory' -r -a '(__fish_complete_directories)'";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l provider -d 'Provider name' -r -a 'codex'";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l model -d 'Provider model' -r";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l reasoning -d 'Reasoning level' -r -a 'low medium high max'";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l provider-profile -d 'Provider profile' -r";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l provider-config -d 'Provider config override' -r";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l sandbox -d 'Sandbox mode' -r -a 'read-only workspace-write danger-full-access'";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l allow-write-dir -d 'Extra writable directory' -r -a '(__fish_complete_directories)'";
      "complete -c camlflow -n '__fish_seen_subcommand_from run' -l trace-provider -d 'Print provider step trace metadata'";
      "complete -c camlflow -n '__fish_seen_subcommand_from serve' -l stdio -d 'Use stdio transport'";
    ]

let completion_script = function
  | Bash -> bash_completion_script
  | Zsh -> zsh_completion_script
  | Fish -> fish_completion_script
