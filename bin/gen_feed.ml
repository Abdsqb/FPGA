(* Write a random feed to a file. The same feed drives the Hardcaml
   testbench, the UDP replay script and the C baseline, so every stage sees
   identical input.

   Two output formats:
   - default: each ITCH message with a 2-byte big-endian length in front
     (the same framing as MoldUDP64's message block and Nasdaq's ITCH files)
   - -mold:   MoldUDP64 packets, each with a 2-byte big-endian length in
     front. A UDP sender reads a length, reads that many bytes, and sends
     them as one datagram: no ITCH knowledge needed.

   dune exec bin/gen_feed.exe -- -n 10000 -seed 7 -o feed.bin
   dune exec bin/gen_feed.exe -- -n 10000 -mold -o feed.mold
   dune exec bin/gen_feed.exe -- -n 10 -print        (human-readable) *)

open Model

let () =
  let n = ref 10_000 and seed = ref 42 and out = ref "" and print = ref false in
  let mold = ref false in
  Arg.parse
    [ "-n", Arg.Set_int n, "N  number of messages (default 10000)"
    ; "-seed", Arg.Set_int seed, "S  random seed (default 42)"
    ; "-o", Arg.Set_string out, "FILE  output file (default feed.bin, or feed.mold with -mold)"
    ; "-mold", Arg.Set mold, "  write MoldUDP64 packets instead of bare messages"
    ; "-print", Arg.Set print, "  print messages and top of book instead of writing"
    ]
    (fun _ -> ())
    "gen_feed: write a random ITCH 5.0 subset feed";
  let cfg = { Feed_gen.default_config with seed = !seed } in
  let g = Feed_gen.create cfg in
  if !print then begin
    let book = ref Order_book.empty in
    for _ = 1 to !n do
      let m = Feed_gen.next g in
      book := Result.get_ok (Order_book.apply !book m);
      Printf.printf "%-44s %s\n" (Msg.to_string m) (Order_book.top_to_string !book)
    done
  end
  else begin
    let out = if !out <> "" then !out else if !mold then "feed.mold" else "feed.bin" in
    let msgs =
      List.init !n (fun i ->
        let i = i + 1 in
        let header = { Itch.default_header with tracking = i land 0xFFFF; timestamp_ns = i } in
        Itch.encode ~header ~match_number:i (Feed_gen.next g))
    in
    let oc = open_out_bin out in
    if !mold then begin
      let packets = Mold.packetize ~first_seq:1 msgs in
      List.iter (fun p -> output_bytes oc (Itch.frame p)) packets;
      close_out oc;
      Printf.printf "wrote %d messages in %d MoldUDP64 packets to %s\n" !n
        (List.length packets) out
    end
    else begin
      List.iter (fun m -> output_bytes oc (Itch.frame m)) msgs;
      close_out oc;
      Printf.printf "wrote %d messages to %s\n" !n out
    end
  end
