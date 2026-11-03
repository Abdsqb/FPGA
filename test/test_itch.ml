open Model

let%expect_test "byte layout of each message type" =
  let header = { Itch.default_header with timestamp_ns = 0x0102_0304_0506 } in
  List.iter
    (fun m ->
      let b = Itch.encode ~header ~match_number:9 m in
      Printf.printf "%c (%d bytes): %s\n" (Bytes.get b 0) (Bytes.length b) (Itch.to_hex b))
    [ Msg.Add { id = 0x2A; side = Buy; price = 1_000_100; qty = 300 }
    ; Executed { id = 0x2A; qty = 100 }
    ; Cancel { id = 0x2A; qty = 50 }
    ; Delete { id = 0x2A }
    ];
  [%expect {|
    A (36 bytes): 41 00 01 00 00 01 02 03 04 05 06 00 00 00 00 00 00 00 2a 42 00 00 01 2c 54 45 53 54 20 20 20 20 00 0f 42 a4
    E (31 bytes): 45 00 01 00 00 01 02 03 04 05 06 00 00 00 00 00 00 00 2a 00 00 00 64 00 00 00 00 00 00 00 09
    X (23 bytes): 58 00 01 00 00 01 02 03 04 05 06 00 00 00 00 00 00 00 2a 00 00 00 32
    D (19 bytes): 44 00 01 00 00 01 02 03 04 05 06 00 00 00 00 00 00 00 2a
    |}]

let%expect_test "decode rejects bad input" =
  let show b =
    match Itch.decode b with
    | Ok m -> print_endline (Msg.to_string m)
    | Error e -> print_endline ("error: " ^ e)
  in
  show Bytes.empty;
  show (Bytes.of_string "Zxxxx");
  show (Bytes.sub (Itch.encode (Delete { id = 1 })) 0 10);
  [%expect {|
    error: empty message
    error: unsupported message type 'Z'
    error: type 'D': expected 19 bytes, got 10
    |}]

let%expect_test "randomized: encode then decode is the identity" =
  let msgs = Feed_gen.generate Feed_gen.default_config 20_000 in
  let bad =
    List.filter (fun m -> Itch.decode (Itch.encode m) <> Ok m) msgs |> List.length
  in
  (* also round-trip through framing, as a feed file would *)
  let buf = Bytes.concat Bytes.empty (List.map (fun m -> Itch.frame (Itch.encode m)) msgs) in
  let framed_ok =
    match Itch.unframe_all buf with
    | Ok bs -> List.map Itch.decode bs = List.map Result.ok msgs
    | Error _ -> false
  in
  Printf.printf "mismatches: %d, framing ok: %b\n" bad framed_ok;
  [%expect {| mismatches: 0, framing ok: true |}]
