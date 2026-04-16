let test_version () =
  Alcotest.(check string) "version" "0.1.0-dev" Camlflow.version

let test_parse_stub () =
  match Camlflow.Parsing.parse_string "agent programmer" with
  | Ok program ->
      Alcotest.(check int) "placeholder program length" 0 (List.length program)
  | Error error ->
      Alcotest.failf "expected placeholder parse success, got error: %s" error

let () =
  Alcotest.run "camlflow"
    [
      ( "scaffold",
        [
          Alcotest.test_case "exports version" `Quick test_version;
          Alcotest.test_case "placeholder parser succeeds" `Quick test_parse_stub;
        ] );
    ]
