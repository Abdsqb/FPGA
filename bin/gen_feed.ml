(* Write a random feed to a file: each ITCH message framed with a 2-byte
   big-endian length. The same file will drive the Hardcaml testbench, the
   UDP replay script and the C baseline, so every stage sees identical input.

   dune exec bin/gen_feed.exe -- -n 10000 -seed 7 -o feed.bin
   dune exec bin/gen_feed.exe -- -n 10 -print        (human-readable) *)

open Model

let () =
  let n = ref 10_000 and seed = ref 42 and out = ref "feed.bin" and print = ref false in
  Arg.parse
    [ "-n", Arg.Set_int n, "N  number of messages (default 10000)"
    ; "-seed", Arg.Set_int seed, "S  random seed (default 42)"
    ; "-o", Arg.Set_string out, "FILE  output file (default feed.bin)"
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
      Printf.printf "%-30s %s\n" (Msg.to_string m) (Order_book.top_to_string !book)
    done
  end
  else begin
    let oc = open_out_bin !out in
    for i = 1 to !n do
      let header = { Itch.default_header with tracking = i land 0xFFFF; timestamp_ns = i } in
      output_bytes oc (Itch.frame (Itch.encode ~header ~match_number:i (Feed_gen.next g)))
    done;
    close_out oc;
    Printf.printf "wrote %d messages to %s\n" !n !out
  end
