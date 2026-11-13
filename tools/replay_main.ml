(* Send MoldUDP64 packets over UDP at a chosen rate.

   From a file written by gen_feed -mold:
     dune exec tools/replay_main.exe -- -file feed.mold -rate 100

   Or generate on the fly, one message per packet:
     dune exec tools/replay_main.exe -- -n 1000 -per-packet 1 -rate 50

   TODO (confirm with Enes): the default address and port below are
   placeholders until his receiver's UDP filter settles on its own. *)

let () =
  let file = ref "" and n = ref 1000 and seed = ref 42 and per_packet = ref 0 in
  let addr = ref "255.255.255.255" and port = ref 5000 and rate = ref 100. in
  let dry_run = ref false in
  Arg.parse
    [ "-file", Arg.Set_string file, "FILE  send packets from a gen_feed -mold file"
    ; "-n", Arg.Set_int n, "N  otherwise generate N messages (default 1000)"
    ; "-seed", Arg.Set_int seed, "S  random seed for generated messages (default 42)"
    ; "-per-packet", Arg.Set_int per_packet,
      "K  messages per generated packet; 0 = fill to 1,472 bytes (default 0)"
    ; "-addr", Arg.Set_string addr, "IP  destination; a broadcast address works (default 255.255.255.255)"
    ; "-port", Arg.Set_int port, "PORT  destination UDP port (default 5000)"
    ; "-rate", Arg.Set_float rate, "R  packets per second; 0 = as fast as possible (default 100)"
    ; "-dry-run", Arg.Set dry_run, "  show what would be sent, send nothing"
    ]
    (fun _ -> ())
    "replay: send MoldUDP64 packets over UDP";
  let packets =
    if !file <> "" then
      match Replay.read_mold_file !file with
      | Ok ps -> ps
      | Error e -> prerr_endline ("replay: " ^ e); exit 1
    else Replay.generate ~msgs_per_packet:!per_packet ~seed:!seed ~n:!n ()
  in
  let total = List.fold_left (fun a p -> a + Bytes.length p) 0 packets in
  Printf.printf "%d packets, %d bytes -> %s:%d at %s\n%!" (List.length packets) total !addr !port
    (if !rate > 0. then Printf.sprintf "%g packets/s" !rate else "full speed");
  if not !dry_run then begin
    let s = Replay.send ~rate:!rate ~addr:!addr ~port:!port packets in
    Printf.printf "sent %d packets (%d bytes) in %.3f s = %.1f packets/s\n" s.packets s.bytes
      s.seconds
      (if s.seconds > 0. then float_of_int s.packets /. s.seconds else 0.)
  end
