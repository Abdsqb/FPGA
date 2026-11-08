(* The parser takes Spec v1's byte stream (MoldUDP64 packets, in_last = last
   byte of each packet) and outputs Spec v1's "Parser -> order book" signals.
   Packets here are built with the model's own encoder (Model.Mold, Model.Itch). *)
open! Hardcaml
module P = Hw.Itch_parser
module Sim = Cyclesim.With_interface (P.I) (P.O)

let value r = Bits.to_int !r
let ref64 (o : Bits.t ref P.O.t) = Bits.to_int64 !(o.order_ref)
let bit b = if b then Bits.vdd else Bits.gnd

let setup () =
  let sim = Sim.create P.create in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  Cyclesim.cycle sim;
  sim, i, o

(* Spec v1 parser outputs -> the reference model's message type. *)
let decoded (o : Bits.t ref P.O.t) =
  let order_ref = Int64.to_int (ref64 o) and shares = value o.shares in
  match value o.msg_type with
  | 0 -> Model.Msg.Add_order
      { order_ref; shares; price = value o.price
      ; side = if value o.side = 1 then Sell else Buy }
  | 1 -> Order_executed { order_ref; shares }
  | 2 -> Order_cancel { order_ref; shares }
  | 3 -> Order_delete { order_ref }
  | _ -> assert false

(* [step] advances one clock and records each [valid] pulse. A pulse lasting
   two cycles would be recorded twice, so counting them checks "one cycle per
   message". [on_valid] lets a test inspect the raw outputs in that cycle. *)
let recorder ?(on_valid = fun () -> ()) sim (o : Bits.t ref P.O.t) =
  let msgs = ref [] and refs = ref [] in
  let step () =
    Cyclesim.cycle sim;
    if value o.valid = 1 then begin
      msgs := decoded o :: !msgs;
      refs := ref64 o :: !refs;
      on_valid ()
    end
  in
  step, (fun () -> List.rev !msgs), (fun () -> List.rev !refs)

let drive (i : Bits.t ref P.I.t) ~last byte =
  i.in_valid := Bits.vdd;
  i.in_data := Bits.of_int ~width:8 byte;
  i.in_last := bit last

let idle (i : Bits.t ref P.I.t) =
  i.in_valid := Bits.gnd;
  i.in_last := Bits.gnd

(* Drive one UDP payload, optionally with idle gaps between bytes. *)
let drive_packet ?(gaps = false) step i packet =
  Bytes.iteri (fun n byte ->
    if gaps && n mod 3 = 1 then (idle i; step (); step ());
    drive i ~last:(n = Bytes.length packet - 1) (Char.code byte);
    step ()) packet

(* Send one packet, then two idle cycles; return the messages reported. *)
let send ?gaps sim i o packet =
  let step, msgs, _ = recorder sim o in
  drive_packet ?gaps step i packet;
  idle i;
  step ();
  step ();
  msgs ()

let from_hex s =
  String.split_on_char ' ' s
  |> List.filter (fun s -> s <> "")
  |> List.map (fun s -> Char.chr (int_of_string ("0x" ^ s)))
  |> List.to_seq |> Bytes.of_seq

let sample = from_hex
  "41 00 01 00 00 1f 1a ce d9 f0 00 00 00 00 00 00 00 00 2a 42 00 00 00 64 41 41 50 4c 20 20 20 20 00 16 ed 24"

let aapl = Model.Msg.Add_order { order_ref = 42; side = Buy; shares = 100; price = 1_502_500 }
let packet msgs = Model.Mold.encode ~seq:1 msgs
let mutation pos v = let b = Bytes.copy sample in Bytes.set_uint8 b pos v; b

let%expect_test "the reading guide's AAPL Add, inside a MoldUDP64 packet, with gaps" =
  let sim, i, o = setup () in
  let p = packet [ sample ] in
  let got = send ~gaps:true sim i o p in
  assert (got = [ aapl ]);
  Printf.printf "%d-byte packet -> %s\n" (Bytes.length p) (Model.Msg.to_string (List.hd got));
  print_endline "valid pulsed for exactly one cycle";
  [%expect {|
    58-byte packet -> Add_order      order_ref=42 B 100 @ 1502500
    valid pulsed for exactly one cycle
    |}]

let%expect_test "all four message types in one packet, in order, irrelevant fields zero" =
  let sim, i, o = setup () in
  let messages = Model.Msg.[
    Add_order { order_ref = 4095; side = Sell; shares = 0xFFFF_FFFF; price = 2_000_000_000 };
    Order_executed { order_ref = 4095; shares = 0x8000_0000 };
    Order_cancel { order_ref = 0; shares = 0xFFFF_FFFF };
    Order_delete { order_ref = 0 } ] in
  let on_valid () =
    if value o.msg_type <> 0 then assert (value o.price = 0 && value o.side = 0);
    if value o.msg_type = 3 then assert (value o.shares = 0)
  in
  let step, msgs, _ = recorder ~on_valid sim o in
  drive_packet step i (packet (List.map Model.Itch.encode messages));
  idle i;
  step ();
  assert (msgs () = messages);
  print_endline "A/E/X/D decoded in order; IDs 0 and 4095 and unsigned shares preserved";
  [%expect {| A/E/X/D decoded in order; IDs 0 and 4095 and unsigned shares preserved |}]

let%expect_test "the full 64-bit order ref is passed through, as in Spec v1" =
  let sim, i, o = setup () in
  let show msg_bytes =
    let step, _, refs = recorder sim o in
    drive_packet step i (packet [ msg_bytes ]);
    idle i;
    step ();
    match refs () with
    | [ r ] -> Printf.printf "order_ref=0x%016Lx  low 12 bits (table index)=%Ld\n" r (Int64.logand r 0xFFFL)
    | _ -> print_endline "no message"
  in
  show sample;
  show (mutation 17 0x10);  (* 0x102A = 4138 *)
  show (mutation 11 0x80);  (* top bit of the 64-bit ref *)
  [%expect {|
    order_ref=0x000000000000002a  low 12 bits (table index)=42
    order_ref=0x000000000000102a  low 12 bits (table index)=42
    order_ref=0x800000000000002a  low 12 bits (table index)=42
    |}]

let%expect_test "heartbeat and end-of-session packets carry no messages" =
  let sim, i, o = setup () in
  let hb = send sim i o (Model.Mold.heartbeat ~seq:1 ()) in
  let eos = send sim i o (Model.Mold.end_of_session ~seq:1 ()) in
  let after = send sim i o (packet [ sample ]) in
  Printf.printf "heartbeat: %d messages; end of session: %d; next packet: %d\n"
    (List.length hb) (List.length eos) (List.length after);
  [%expect {| heartbeat: 0 messages; end of session: 0; next packet: 1 |}]

let%expect_test "bad messages and bad packets produce no output, and the parser recovers" =
  let sim, i, o = setup () in
  let bad =
    [ "unsupported type 'U'", packet [ mutation 0 (Char.code 'U') ]
    ; "bad side byte", packet [ mutation 19 (Char.code '?') ]
    ; "Add with 35 bytes", packet [ Bytes.sub sample 0 35 ]
    ; "Add with 37 bytes", packet [ Bytes.cat sample (Bytes.make 1 '\000') ]
    ; "other stock (locate 2)", packet [ mutation 2 2 ]
    ; "packet cut off mid-message", Bytes.sub (packet [ sample ]) 0 40
    (* Cut-through: the complete first message was already passed on. *)
    ; "cut after 1 complete message", Bytes.sub (packet [ sample; sample ]) 0 59
    ]
  in
  List.iter (fun (name, p) ->
    let got = send sim i o p in
    let next = send sim i o (packet [ sample ]) in
    Printf.printf "%-28s -> %d output(s); next packet decodes: %b\n" name (List.length got) (next = [ aapl ]))
    bad;
  (* A bad message doesn't disturb the good ones around it in the same packet. *)
  let mixed = send sim i o (packet [ sample; mutation 0 (Char.code 'U'); sample ]) in
  Printf.printf "good, bad, good in one packet -> %d output(s)\n" (List.length mixed);
  [%expect {|
    unsupported type 'U'         -> 0 output(s); next packet decodes: true
    bad side byte                -> 0 output(s); next packet decodes: true
    Add with 35 bytes            -> 0 output(s); next packet decodes: true
    Add with 37 bytes            -> 0 output(s); next packet decodes: true
    other stock (locate 2)       -> 0 output(s); next packet decodes: true
    packet cut off mid-message   -> 0 output(s); next packet decodes: true
    cut after 1 complete message -> 1 output(s); next packet decodes: true
    good, bad, good in one packet -> 2 output(s)
    |}]

let%expect_test "packets back to back, one byte every cycle, no gaps" =
  let sim, i, o = setup () in
  let step, msgs, _ = recorder sim o in
  let sent = Model.Feed_gen.generate { Model.Feed_gen.default_config with seed = 3 } 1_000 in
  let packets = Model.Mold.packetize (List.map Model.Itch.encode sent) in
  let cycles = ref 0 in
  List.iter (fun p ->
    Bytes.iteri (fun n c ->
      drive i ~last:(n = Bytes.length p - 1) (Char.code c);
      step ();
      incr cycles) p) packets;
  idle i;
  step ();
  let got = msgs () in
  Printf.printf "%d messages in %d packets, %d cycles with no idle cycles; decoded %d; identical: %b\n"
    (List.length sent) (List.length packets) !cycles (List.length got) (got = sent);
  [%expect {| 1000 messages in 22 packets, 32104 cycles with no idle cycles; decoded 1000; identical: true |}]

let%expect_test "reset in the middle of a packet" =
  let sim, i, o = setup () in
  let step, msgs, _ = recorder sim o in
  let p = packet [ sample ] in
  Bytes.iteri (fun n c -> if n < 30 then (drive i ~last:false (Char.code c); step ())) p;
  i.clear := Bits.vdd;
  idle i;
  step ();
  i.clear := Bits.gnd;
  step ();
  let partial = msgs () in
  let after = send sim i o p in
  assert (partial = [] && after = [ aapl ]);
  print_endline "reset drops the partial packet; the next packet decodes normally";
  [%expect {| reset drops the partial packet; the next packet decodes normally |}]

let%expect_test "10,000 generated messages in MoldUDP64 packets agree with the model" =
  let sim, i, o = setup () in
  let sent = Model.Feed_gen.generate { Model.Feed_gen.default_config with seed = 8 } 10_000 in
  let packets = Model.Mold.packetize (List.map Model.Itch.encode sent) in
  let got =
    List.concat (List.mapi (fun n p -> send ~gaps:(n mod 3 = 0) sim i o p) packets)
  in
  assert (List.length got = List.length sent);
  (* Apply both streams to the model's order book and compare after every message. *)
  let apply book msg =
    match Model.Order_book.apply book msg with
    | Ok next -> next
    | Error e -> failwith (Model.Order_book.error_to_string e)
  in
  let mismatches = ref 0 in
  ignore
    (List.fold_left2 (fun (expected, parsed) s g ->
       let expected = apply expected s and parsed = apply parsed g in
       if Model.Order_book.best_bid expected <> Model.Order_book.best_bid parsed
          || Model.Order_book.best_ask expected <> Model.Order_book.best_ask parsed
       then incr mismatches;
       expected, parsed)
       (Model.Order_book.empty, Model.Order_book.empty) sent got);
  Printf.printf "10,000 messages in %d packets: %d best bid/ask mismatches (seed 8)\n"
    (List.length packets) !mismatches;
  [%expect {| 10,000 messages in 221 packets: 0 best bid/ask mismatches (seed 8) |}]
