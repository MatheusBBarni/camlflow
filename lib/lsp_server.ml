module StringMap = Map.Make (String)
module StringSet = Set.Make (String)
module Analysis = Lsp_analysis

let ( let* ) = Result.bind

type document = {
  uri : string;
  path : string;
  version : int option;
  text : string;
}

type server = {
  input : in_channel;
  output : out_channel;
  mutable shutdown_requested : bool;
  mutable open_documents : document StringMap.t;
  mutable published_by_project : StringSet.t StringMap.t;
}

type text_document = {
  uri : string;
  version : int option;
  text : string option;
}

let content_modified_code = -32801

let object_fields = function
  | `Assoc fields -> Ok fields
  | _ -> Error "expected JSON object"

let field fields name =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing field %s" name)

let string_field fields name =
  let* value = field fields name in
  match value with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "field %s must be a string" name)

let int_field fields name =
  let* value = field fields name in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Printf.sprintf "field %s must be an int" name)

let bool_field_with_default fields name default =
  match List.assoc_opt name fields with
  | None -> Ok default
  | Some (`Bool value) -> Ok value
  | Some _ -> Error (Printf.sprintf "field %s must be a bool" name)

let list_field fields name =
  let* value = field fields name in
  match value with
  | `List items -> Ok items
  | _ -> Error (Printf.sprintf "field %s must be a list" name)

let text_document_of_yojson = function
  | `Assoc fields ->
      let* uri = string_field fields "uri" in
      let version =
        match List.assoc_opt "version" fields with
        | None | Some `Null -> Ok None
        | Some (`Int value) -> Ok (Some value)
        | Some _ -> Error "field version must be an int or null"
      in
      let* version = version in
      let text =
        match List.assoc_opt "text" fields with
        | None | Some `Null -> Ok None
        | Some (`String value) -> Ok (Some value)
        | Some _ -> Error "field text must be a string or null"
      in
      let* text = text in
      Ok { uri; version; text }
  | _ -> Error "expected textDocument object"

let position_of_yojson = function
  | `Assoc fields ->
      let* line = int_field fields "line" in
      let* character = int_field fields "character" in
      Ok (line, character)
  | _ -> Error "expected position object"

let text_document_position_params = function
  | `Assoc fields ->
      let* text_document_json = field fields "textDocument" in
      let* text_document = text_document_of_yojson text_document_json in
      let* position_json = field fields "position" in
      let* line, character = position_of_yojson position_json in
      Ok (text_document, line, character)
  | _ -> Error "expected textDocument position params"

let rename_params_of_yojson = function
  | `Assoc fields ->
      let* text_document_json = field fields "textDocument" in
      let* text_document = text_document_of_yojson text_document_json in
      let* position_json = field fields "position" in
      let* line, character = position_of_yojson position_json in
      let* new_name = string_field fields "newName" in
      Ok (text_document, line, character, new_name)
  | _ -> Error "expected rename params"

let overlays_of_server (server : server) =
  StringMap.fold
    (fun path (document : document) acc -> StringMap.add path document.text acc)
    server.open_documents
    (StringMap.empty : string StringMap.t)

let document_version_by_uri (server : server) uri =
  server.open_documents |> StringMap.bindings
  |> List.find_map (fun (_path, (document : document)) ->
      if String.equal document.uri uri then document.version else None)

let range_to_yojson (range : Analysis.range) =
  `Assoc
    [
      ( "start",
        `Assoc
          [
            ("line", `Int range.start_pos.line);
            ("character", `Int range.start_pos.character);
          ] );
      ( "end",
        `Assoc
          [
            ("line", `Int range.end_pos.line);
            ("character", `Int range.end_pos.character);
          ] );
    ]

let location_to_yojson uri range =
  `Assoc [ ("uri", `String uri); ("range", range_to_yojson range) ]

let diagnostic_to_yojson (diagnostic : Analysis.diagnostic) =
  let base =
    [
      ("range", range_to_yojson diagnostic.range);
      ("severity", `Int diagnostic.severity);
      ("source", `String diagnostic.source);
      ("message", `String diagnostic.message);
    ]
  in
  `Assoc base

let rec document_symbol_to_yojson (symbol : Analysis.document_symbol) =
  `Assoc
    ([
       ("name", `String symbol.name);
       ("kind", `Int symbol.kind);
       ("range", range_to_yojson symbol.range);
       ("selectionRange", range_to_yojson symbol.selection_range);
     ]
    @
    match symbol.detail with
    | Some detail -> [ ("detail", `String detail) ]
    | None ->
        []
        @
        if symbol.children = [] then []
        else
          [
            ( "children",
              `List (List.map document_symbol_to_yojson symbol.children) );
          ])

let text_edit_to_yojson range new_text =
  `Assoc [ ("range", range_to_yojson range); ("newText", `String new_text) ]

let is_ident_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '\'' -> true
  | _ -> false

let valid_new_name value =
  let len = String.length value in
  len > 0
  && (match value.[0] with 'A' .. 'Z' | 'a' .. 'z' | '_' -> true | _ -> false)
  && String.for_all is_ident_char value

let respond server id result =
  Rpc_stdio.write_message server.output (Rpc_protocol.success id result)

let respond_null server id = respond server id `Null

let respond_error server ?data id ~code ~message =
  Rpc_stdio.write_message server.output
    (Rpc_protocol.error ?id:(Some id) ?data ~code ~message ())

let notify server method_ params =
  Rpc_stdio.write_message server.output (Rpc_protocol.request method_ ~params)

let publish_diagnostics server uri version diagnostics =
  let payload =
    `Assoc
      ([
         ("uri", `String uri);
         ("diagnostics", `List (List.map diagnostic_to_yojson diagnostics));
       ]
      @
      match version with
      | Some version -> [ ("version", `Int version) ]
      | None -> [])
  in
  notify server "textDocument/publishDiagnostics" payload

let publish_analysis server (analysis : Analysis.analysis) =
  let diagnostics_by_uri =
    if StringMap.mem analysis.current_uri analysis.diagnostics_by_uri then
      analysis.diagnostics_by_uri
    else StringMap.add analysis.current_uri [] analysis.diagnostics_by_uri
  in
  let current_uris =
    diagnostics_by_uri |> StringMap.bindings |> List.map fst
    |> StringSet.of_list
  in
  let previous =
    match
      StringMap.find_opt analysis.project_id server.published_by_project
    with
    | Some uris -> uris
    | None -> StringSet.empty
  in
  let* () =
    StringSet.diff previous current_uris
    |> StringSet.to_list
    |> List.fold_left
         (fun acc uri ->
           let* () = acc in
           publish_diagnostics server uri
             (document_version_by_uri server uri)
             [])
         (Ok ())
  in
  let* () =
    diagnostics_by_uri |> StringMap.bindings
    |> List.fold_left
         (fun acc (uri, diagnostics) ->
           let* () = acc in
           publish_diagnostics server uri
             (document_version_by_uri server uri)
             diagnostics)
         (Ok ())
  in
  server.published_by_project <-
    StringMap.add analysis.project_id current_uris server.published_by_project;
  Ok ()

let analysis_for_path server path =
  Analysis.analyze ~overlays:(overlays_of_server server) path

let with_path_from_uri uri f =
  let* path = Analysis.path_of_uri uri in
  f path

let with_document_analysis server (document : text_document) f =
  with_path_from_uri document.uri (fun path ->
      let analysis = analysis_for_path server path in
      f path analysis)

let lsp_capabilities =
  `Assoc
    [
      ("textDocumentSync", `Int 1);
      ("hoverProvider", `Bool true);
      ("definitionProvider", `Bool true);
      ("referencesProvider", `Bool true);
      ("documentSymbolProvider", `Bool true);
      ("renameProvider", `Assoc [ ("prepareProvider", `Bool true) ]);
    ]

let initialize_result () =
  `Assoc
    [
      ("capabilities", lsp_capabilities);
      ( "serverInfo",
        `Assoc
          [ ("name", `String "camlflow-lsp"); ("version", `String "0.2.0-dev") ]
      );
    ]

let hover_result (symbol : Analysis.symbol) =
  match symbol.hover with
  | None -> `Null
  | Some hover ->
      `Assoc
        [
          ( "contents",
            `Assoc
              [
                ("kind", `String "markdown");
                ("value", `String (Printf.sprintf "```camlflow\n%s\n```" hover));
              ] );
          ("range", range_to_yojson symbol.decl_selection_range);
        ]

let definition_result (symbol : Analysis.symbol) =
  location_to_yojson symbol.uri symbol.decl_selection_range

let references_result (occurrences : Analysis.occurrence list)
    include_declaration =
  occurrences
  |> List.filter (fun (occurrence : Analysis.occurrence) ->
      include_declaration || occurrence.role = Analysis.Reference)
  |> List.map (fun (occurrence : Analysis.occurrence) ->
      location_to_yojson occurrence.uri occurrence.range)
  |> fun items -> `List items

let prepare_rename_result (occurrence : Analysis.occurrence)
    (symbol : Analysis.symbol) =
  `Assoc
    [
      ("range", range_to_yojson occurrence.range);
      ("placeholder", `String symbol.name);
    ]

let rename_result (occurrences : Analysis.occurrence list) new_name =
  let changes =
    occurrences
    |> List.fold_left
         (fun acc (occurrence : Analysis.occurrence) ->
           let edits =
             match StringMap.find_opt occurrence.uri acc with
             | Some edits ->
                 text_edit_to_yojson occurrence.range new_name :: edits
             | None -> [ text_edit_to_yojson occurrence.range new_name ]
           in
           StringMap.add occurrence.uri edits acc)
         StringMap.empty
    |> StringMap.bindings
    |> List.map (fun (uri, edits) -> (uri, `List (List.rev edits)))
  in
  `Assoc [ ("changes", `Assoc changes) ]

let can_rename (symbol : Analysis.symbol) =
  symbol.renameable
  &&
  match symbol.kind with
  | Analysis.Module | Analysis.Field -> false
  | _ -> true

let handle_initialize server request =
  match request.Rpc_protocol.request_id with
  | Some id -> respond server id (initialize_result ())
  | None -> Ok ()

let handle_shutdown server request =
  server.shutdown_requested <- true;
  match request.Rpc_protocol.request_id with
  | Some id -> respond_null server id
  | None -> Ok ()

let update_document server (document : text_document) text =
  let* path = Analysis.path_of_uri document.uri in
  server.open_documents <-
    StringMap.add path
      { uri = document.uri; path; version = document.version; text }
      server.open_documents;
  Ok path

let handle_did_open server params =
  let* fields = object_fields params in
  let* text_document_json = field fields "textDocument" in
  let* text_document = text_document_of_yojson text_document_json in
  let text = match text_document.text with Some text -> text | None -> "" in
  let* path = update_document server text_document text in
  publish_analysis server (analysis_for_path server path)

let handle_did_change server params =
  let* fields = object_fields params in
  let* text_document_json = field fields "textDocument" in
  let* text_document = text_document_of_yojson text_document_json in
  let* changes = list_field fields "contentChanges" in
  let latest_text =
    match List.rev changes with
    | `Assoc fields :: _ -> (
        match List.assoc_opt "text" fields with
        | Some (`String text) -> Ok text
        | _ -> Error "contentChanges entries must contain text")
    | _ -> Error "contentChanges must not be empty"
  in
  let* latest_text = latest_text in
  let* path = update_document server text_document latest_text in
  publish_analysis server (analysis_for_path server path)

let handle_did_save server params =
  let* fields = object_fields params in
  let* text_document_json = field fields "textDocument" in
  let* text_document = text_document_of_yojson text_document_json in
  with_document_analysis server text_document (fun _path analysis ->
      publish_analysis server analysis)

let handle_did_close server params =
  let* fields = object_fields params in
  let* text_document_json = field fields "textDocument" in
  let* text_document = text_document_of_yojson text_document_json in
  let* path = Analysis.path_of_uri text_document.uri in
  server.open_documents <- StringMap.remove path server.open_documents;
  publish_analysis server (analysis_for_path server path)

let request_id_or_error request =
  match request.Rpc_protocol.request_id with
  | Some id -> Ok id
  | None -> Error "request id required"

let handle_hover server request params =
  let* id = request_id_or_error request in
  let* document, line, character = text_document_position_params params in
  with_document_analysis server document (fun _path analysis ->
      match
        Analysis.symbol_at_position analysis document.uri ~line ~character
      with
      | Some (_occurrence, symbol) -> respond server id (hover_result symbol)
      | None -> respond_null server id)

let handle_definition server request params =
  let* id = request_id_or_error request in
  let* document, line, character = text_document_position_params params in
  with_document_analysis server document (fun _path analysis ->
      match
        Analysis.symbol_at_position analysis document.uri ~line ~character
      with
      | Some (_occurrence, symbol) ->
          respond server id (definition_result symbol)
      | None -> respond_null server id)

let handle_references server request params =
  let* id = request_id_or_error request in
  let* fields = object_fields params in
  let* text_document_json = field fields "textDocument" in
  let* document = text_document_of_yojson text_document_json in
  let* position_json = field fields "position" in
  let* line, character = position_of_yojson position_json in
  let include_declaration =
    match List.assoc_opt "context" fields with
    | Some (`Assoc context_fields) ->
        bool_field_with_default context_fields "includeDeclaration" false
    | Some _ -> Error "field context must be an object"
    | None -> Ok false
  in
  let* include_declaration = include_declaration in
  with_document_analysis server document (fun _path analysis ->
      match
        Analysis.symbol_at_position analysis document.uri ~line ~character
      with
      | Some (_occurrence, symbol) ->
          let occurrences =
            Analysis.occurrences_for_symbol analysis symbol.id
          in
          respond server id (references_result occurrences include_declaration)
      | None -> respond server id (`List []))

let handle_document_symbol server request params =
  let* id = request_id_or_error request in
  let* fields = object_fields params in
  let* text_document_json = field fields "textDocument" in
  let* document = text_document_of_yojson text_document_json in
  with_document_analysis server document (fun _path analysis ->
      let items = Analysis.document_symbols_for_uri analysis document.uri in
      respond server id (`List (List.map document_symbol_to_yojson items)))

let handle_prepare_rename server request params =
  let* id = request_id_or_error request in
  let* document, line, character = text_document_position_params params in
  with_document_analysis server document (fun _path analysis ->
      match
        Analysis.symbol_at_position analysis document.uri ~line ~character
      with
      | Some (occurrence, symbol) when can_rename symbol ->
          respond server id (prepare_rename_result occurrence symbol)
      | _ -> respond_null server id)

let handle_rename server request params =
  let* id = request_id_or_error request in
  let* document, line, character, new_name = rename_params_of_yojson params in
  if not (valid_new_name new_name) then
    respond_error server id ~code:(-32602)
      ~message:"newName must be a valid CamlFlow identifier"
  else
    with_document_analysis server document (fun _path analysis ->
        match
          Analysis.symbol_at_position analysis document.uri ~line ~character
        with
        | Some (_occurrence, symbol) when can_rename symbol ->
            let occurrences =
              Analysis.occurrences_for_symbol analysis symbol.id
            in
            respond server id (rename_result occurrences new_name)
        | _ ->
            respond_error server id ~code:content_modified_code
              ~message:"symbol at position is not renameable")

let handle_request server request =
  let params =
    Option.value request.Rpc_protocol.request_params ~default:(`Assoc [])
  in
  match request.Rpc_protocol.request_method with
  | "initialize" -> handle_initialize server request
  | "initialized" -> Ok ()
  | "shutdown" -> handle_shutdown server request
  | "exit" -> Ok ()
  | "textDocument/didOpen" -> handle_did_open server params
  | "textDocument/didChange" -> handle_did_change server params
  | "textDocument/didSave" -> handle_did_save server params
  | "textDocument/didClose" -> handle_did_close server params
  | "textDocument/hover" -> handle_hover server request params
  | "textDocument/definition" -> handle_definition server request params
  | "textDocument/references" -> handle_references server request params
  | "textDocument/documentSymbol" ->
      handle_document_symbol server request params
  | "textDocument/prepareRename" -> handle_prepare_rename server request params
  | "textDocument/rename" -> handle_rename server request params
  | "workspace/didChangeConfiguration" | "$/setTrace" -> Ok ()
  | method_ -> (
      match request.Rpc_protocol.request_id with
      | Some id ->
          respond_error server id ~code:(-32601)
            ~message:(Printf.sprintf "method not found: %s" method_)
      | None -> Ok ())

let run ~input ~output =
  let server =
    {
      input;
      output;
      shutdown_requested = false;
      open_documents = StringMap.empty;
      published_by_project = StringMap.empty;
    }
  in
  let rec loop () =
    let* message = Rpc_stdio.read_message server.input in
    match message with
    | None -> Ok ()
    | Some json -> (
        match Rpc_protocol.request_of_yojson json with
        | Ok request ->
            let* () = handle_request server request in
            if String.equal request.request_method "exit" then Ok ()
            else loop ()
        | Error error ->
            let* () =
              Rpc_stdio.write_message server.output
                (Rpc_protocol.error ~code:(-32600) ~message:error ())
            in
            loop ())
  in
  loop ()

let run_stdio () = run ~input:stdin ~output:stdout
