open Model

let%expect_test "packet layout: 20-byte header, then length-prefixed messages" =
  let msgs =
    [ Itch.encode (Msg.Add_order { order_ref = 42; side = Buy; price = 1_502_500; shares = 100 })
    ; Itch.encode (Msg.Order_delete { order_ref = 42 })
    ]
  in
  let p = Mold.encode ~seq:7 msgs in
  Printf.printf "%d bytes\n" (Bytes.length p);
  Printf.printf "session : %s\n" (Itch.to_hex (Bytes.sub p 0 10));
  Printf.printf "seq     : %s\n" (Itch.to_hex (Bytes.sub p 10 8));
  Printf.printf "count   : %s\n" (Itch.to_hex (Bytes.sub p 18 2));
  Printf.printf "len 1   : %s\n" (Itch.to_hex (Bytes.sub p 20 2));
  Printf.printf "len 2   : %s\n" (Itch.to_hex (Bytes.sub p 58 2));
  [%expect {|
    79 bytes
    session : 46 48 30 30 30 30 30 30 30 31
    seq     : 00 00 00 00 00 00 00 07
    count   : 00 02
    len 1   : 00 24
    len 2   : 00 13
    |}]

let%expect_test "heartbeat and end of session" =
  let show name b =
    match Mold.decode b with
    | Ok p -> Printf.printf "%s: %d bytes, seq %d, count %d\n" name (Bytes.length b) p.seq p.count
    | Error e -> Printf.printf "%s: error %s\n" name e
  in
  show "heartbeat" (Mold.heartbeat ~seq:101 ());
  show "end     " (Mold.end_of_session ~seq:101 ());
  [%expect {|
    heartbeat: 20 bytes, seq 101, count 0
    end     : 20 bytes, seq 101, count 65535
    |}]

let%expect_test "decode rejects bad packets" =
  let show b =
    match Mold.decode b with
    | Ok _ -> print_endline "ok"
    | Error e -> print_endline ("error: " ^ e)
  in
  show (Bytes.make 5 'x');
  let p = Mold.encode ~seq:1 [ Itch.encode (Msg.Order_delete { order_ref = 1 }) ] in
  Bytes.set_uint16_be p 18 2;  (* lie about the count *)
  show p;
  [%expect {|
    error: packet shorter than 20-byte header
    error: header says 2 messages, block has 1
    |}]

let%expect_test "randomized: packetize a long feed, then decode it back" =
  let msgs = List.map Itch.encode (Feed_gen.generate Feed_gen.default_config 50_000) in
  let packets = Mold.packetize ~first_seq:1 msgs in
  let decoded = List.map (fun p -> Result.get_ok (Mold.decode p)) packets in
  let biggest = List.fold_left (fun a p -> max a (Bytes.length p)) 0 packets in
  (* sequence numbers must be consecutive across packets *)
  let seq_ok, _ =
    List.fold_left
      (fun (ok, expect) (p : Mold.packet) -> ok && p.seq = expect, expect + p.count)
      (true, 1) decoded
  in
  let same = List.concat_map (fun (p : Mold.packet) -> p.messages) decoded = msgs in
  Printf.printf "%d messages in %d packets; biggest %d bytes (limit %d)\n"
    (List.length msgs) (List.length packets) biggest Mold.max_udp_payload;
  Printf.printf "sequence numbers consecutive: %b; messages identical: %b\n" seq_ok same;
  [%expect {|
    50000 messages in 1057 packets; biggest 1472 bytes (limit 1472)
    sequence numbers consecutive: true; messages identical: true
    |}]
