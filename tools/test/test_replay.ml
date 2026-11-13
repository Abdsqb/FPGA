(* Send real UDP packets to ourselves on 127.0.0.1 and check they arrive
   whole, in order, and decode back to the generated feed. *)

open Model

let with_receiver f =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_DGRAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close sock) (fun () ->
    Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));  (* any free port *)
    let port = match Unix.getsockname sock with Unix.ADDR_INET (_, p) -> p | _ -> assert false in
    let buf = Bytes.create 2048 in
    let receive () =
      match Unix.select [ sock ] [] [] 2.0 with
      | [], _, _ -> None
      | _ ->
        let n, _ = Unix.recvfrom sock buf 0 (Bytes.length buf) [] in
        Some (Bytes.sub buf 0 n)
    in
    f ~port ~receive)

let send_and_collect ?rate packets =
  with_receiver (fun ~port ~receive ->
    let stats = Replay.send ?rate ~addr:"127.0.0.1" ~port packets in
    let got = List.filter_map (fun _ -> receive ()) packets in
    stats, got)

let messages_of packets =
  List.concat_map (fun p -> (Result.get_ok (Mold.decode p)).messages) packets

let%expect_test "packets arrive whole and in order, and decode to the generated feed" =
  let packets = Replay.generate ~seed:1 ~n:2_000 () in
  let stats, got = send_and_collect packets in
  let expected = List.map Itch.encode (Feed_gen.generate { Feed_gen.default_config with seed = 1 } 2_000) in
  let same_msgs =
    List.map Itch.decode (messages_of got) = List.map Itch.decode expected
  in
  Printf.printf "sent %d packets (%d bytes); received %d; identical: %b; messages match feed: %b\n"
    stats.packets stats.bytes (List.length got) (got = packets) same_msgs;
  [%expect {| sent 45 packets (64477 bytes); received 45; identical: true; messages match feed: true |}]

let%expect_test "one message per packet, consecutive sequence numbers" =
  let packets = Replay.generate ~msgs_per_packet:1 ~seed:2 ~n:50 () in
  let decoded = List.map (fun p -> Result.get_ok (Mold.decode p)) packets in
  let seqs_ok =
    List.for_all2 (fun (p : Mold.packet) k -> p.seq = k && p.count = 1)
      decoded (List.init 50 (fun k -> k + 1))
  in
  let sizes = List.sort_uniq compare (List.map Bytes.length packets) in
  Printf.printf "%d packets; seq 1..50, one message each: %b; packet sizes: %s\n"
    (List.length packets) seqs_ok (String.concat ", " (List.map string_of_int sizes));
  [%expect {| 50 packets; seq 1..50, one message each: true; packet sizes: 41, 45, 53, 58 |}]

let%expect_test "a gen_feed -mold file replays exactly" =
  let path = Filename.temp_file "feed" ".mold" in
  let packets = Replay.generate ~seed:3 ~n:500 () in
  Out_channel.with_open_bin path (fun oc ->
    List.iter (fun p -> Out_channel.output_bytes oc (Itch.frame p)) packets);
  let from_file = Result.get_ok (Replay.read_mold_file path) in
  Sys.remove path;
  Printf.printf "file round trip identical: %b (%d packets)\n" (from_file = packets) (List.length from_file);
  print_endline
    (match Replay.read_mold_file "/no/such/file.mold" with Ok _ -> "ok?" | Error _ -> "missing file -> error");
  [%expect {|
    file round trip identical: true (12 packets)
    missing file -> error
    |}]

let%expect_test "rate limiting spaces packets out" =
  let packets = Replay.generate ~msgs_per_packet:1 ~seed:4 ~n:21 () in
  let stats, got = send_and_collect ~rate:200. packets in
  (* 21 packets at 200/s: the last is due 20/200 = 0.1 s after the first. *)
  Printf.printf "received %d; took at least 0.1 s: %b\n" (List.length got) (stats.seconds >= 0.099);
  [%expect {| received 21; took at least 0.1 s: true |}]
