open! Hardcaml
module P = Hw.Itch_parser
module Sim = Cyclesim.With_interface (P.I) (P.O)

let value r = Bits.to_int !r
let ref64 (o : Bits.t ref P.O.t) = Bits.to_int64 !(o.order_ref)
let bit b = if b then Bits.vdd else Bits.gnd

let setup () =
  let sim = Sim.create P.create in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  i.stock_locate := Bits.of_int ~width:16 1;
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

(* [step] advances one clock and records what the parser reported in that
   cycle: a decoded message on each [valid] pulse (a pulse lasting two
   cycles would be recorded twice), error codes, and filtered pulses. *)
let recorder sim (o : Bits.t ref P.O.t) =
  let msgs = ref [] and refs = ref [] and errors = ref [] and filtered = ref 0 in
  let step () =
    Cyclesim.cycle sim;
    if value o.valid = 1 then (msgs := decoded o :: !msgs; refs := ref64 o :: !refs);
    if value o.error <> 0 then errors := value o.error :: !errors;
    filtered := !filtered + value o.filtered
  in
  let result () = List.rev !msgs, List.rev !errors, !filtered in
  let refs () = List.rev !refs in
  step, result, refs

let drive (i : Bits.t ref P.I.t) ~first ~last byte =
  i.in_valid := Bits.vdd;
  i.in_data := Bits.of_int ~width:8 byte;
  i.in_first := bit first;
  i.in_last := bit last

let idle (i : Bits.t ref P.I.t) =
  i.in_valid := Bits.gnd;
  i.in_first := Bits.gnd;
  i.in_last := Bits.gnd

(* Feed one message (optionally with idle gaps), then two idle cycles.
   Returns (messages reported, error codes, filtered pulses). *)
let send ?(gaps = false) ?(first = true) ?(extra_first = -1) sim i o data =
  let step, result, _ = recorder sim o in
  Bytes.iteri (fun n byte ->
    if gaps && n mod 3 = 1 then (idle i; step (); step ());
    drive i ~first:((n = 0 && first) || n = extra_first)
      ~last:(n = Bytes.length data - 1) (Char.code byte);
    step ()) data;
  idle i;
  step ();
  step ();
  result ()

let from_hex s =
  String.split_on_char ' ' s
  |> List.filter (fun s -> s <> "")
  |> List.map (fun s -> Char.chr (int_of_string ("0x" ^ s)))
  |> List.to_seq |> Bytes.of_seq

let sample = from_hex
  "41 00 01 00 00 1f 1a ce d9 f0 00 00 00 00 00 00 00 00 2a 42 00 00 00 64 41 41 50 4c 20 20 20 20 00 16 ed 24"

let aapl = Model.Msg.Add_order { order_ref = 42; side = Buy; shares = 100; price = 1_502_500 }

let%expect_test "the reading guide's 36-byte AAPL Add, with input bubbles" =
  let sim, i, o = setup () in
  assert (Bytes.length sample = 36);
  let step, result, _ = recorder sim o in
  let ts = ref 0 in
  Bytes.iteri (fun n byte ->
    if n mod 3 = 1 then (idle i; step (); step ());
    drive i ~first:(n = 0) ~last:(n = 35) (Char.code byte);
    step ();
    if value o.valid = 1 then ts := value o.timestamp_ns) sample;
  idle i;
  for _ = 1 to 8 do step () done;
  let msgs, errors, filtered = result () in
  assert (msgs = [ aapl ] && errors = [] && filtered = 0);
  print_endline (Model.Msg.to_string (List.hd msgs));
  Printf.printf "timestamp_ns=%d; valid pulsed for exactly one cycle\n" !ts;
  [%expect {|
    Add_order      order_ref=42 B 100 @ 1502500
    timestamp_ns=34200000000000; valid pulsed for exactly one cycle
    |}]

let%expect_test "all message types, zeroed irrelevant fields, and unsigned 32-bit boundaries" =
  let sim, i, o = setup () in
  let messages = Model.Msg.[
    Add_order { order_ref = 4095; side = Sell; shares = 0xFFFF_FFFF; price = 2_000_000_000 };
    Order_executed { order_ref = 4095; shares = 0x8000_0000 };
    Order_cancel { order_ref = 0; shares = 0xFFFF_FFFF };
    Order_delete { order_ref = 0 } ] in
  List.iter (fun msg ->
    let step, result, _ = recorder sim o in
    let bytes = Model.Itch.encode msg in
    let checked = ref false in
    Bytes.iteri (fun n c ->
      drive i ~first:(n = 0) ~last:(n = Bytes.length bytes - 1) (Char.code c);
      step ();
      if value o.valid = 1 then begin
        if value o.msg_type <> 0 then assert (value o.price = 0 && value o.side = 0);
        if value o.msg_type = 3 then assert (value o.shares = 0);
        checked := true
      end) bytes;
    idle i;
    step ();
    assert (!checked && result () = ([ msg ], [], 0))) messages;
  print_endline "A/E/X/D match; IDs 0 and 4095 and unsigned shares preserved";
  [%expect {| A/E/X/D match; IDs 0 and 4095 and unsigned shares preserved |}]

let%expect_test "the full 64-bit order ref is passed through, as in Spec v1" =
  let sim, i, o = setup () in
  let with_ref_bytes pairs =
    let b = Bytes.copy sample in
    List.iter (fun (pos, v) -> Bytes.set_uint8 b pos v) pairs;
    b
  in
  let show bytes =
    let step, result, refs = recorder sim o in
    Bytes.iteri (fun n c ->
      drive i ~first:(n = 0) ~last:(n = 35) (Char.code c);
      step ()) bytes;
    idle i;
    step ();
    step ();
    let msgs, errors, _ = result () in
    match refs () with
    | [ r ] ->
      Printf.printf "order_ref=0x%016Lx  low 12 bits (table index)=%Ld  errors=%d  messages=%d\n"
        r (Int64.logand r 0xFFFL) (List.length errors) (List.length msgs)
    | _ -> print_endline "no message"
  in
  show sample;
  show (with_ref_bytes [ (17, 0x10) ]);  (* 0x102A = 4138 *)
  show (with_ref_bytes [ (11, 0x80) ]);  (* top bit of the 64-bit ref *)
  [%expect {|
    order_ref=0x000000000000002a  low 12 bits (table index)=42  errors=0  messages=1
    order_ref=0x000000000000102a  low 12 bits (table index)=42  errors=0  messages=1
    order_ref=0x800000000000002a  low 12 bits (table index)=42  errors=0  messages=1
    |}]

let%expect_test "bad frames are reported and the parser recovers" =
  let sim, i, o = setup () in
  let mutation pos v = let b = Bytes.copy sample in Bytes.set_uint8 b pos v; b in
  let check ?(first = true) ?(extra_first = -1) bytes code =
    assert (send ~first ~extra_first sim i o bytes = ([], [ code ], 0));
    assert (send sim i o sample = ([ aapl ], [], 0))
  in
  check (Bytes.sub sample 0 35) 2;
  check (Bytes.cat sample (Bytes.make 8 '\000')) 2;
  check (mutation 0 (Char.code 'U')) 3;
  check (mutation 19 (Char.code '?')) 4;
  check ~first:false sample 1;
  check ~extra_first:8 sample 1;
  assert (send sim i o (mutation 2 2) = ([], [], 1));
  print_endline "6 malformed cases reported and recovered; foreign stock filtered";
  [%expect {| 6 malformed cases reported and recovered; foreign stock filtered |}]

let%expect_test "back-to-back messages, one byte every cycle, no gaps" =
  let sim, i, o = setup () in
  let step, result, _ = recorder sim o in
  let msgs = Model.Feed_gen.generate { Model.Feed_gen.default_config with seed = 3 } 1_000 in
  let cycles = ref 0 in
  List.iter (fun m ->
    let b = Model.Itch.encode m in
    Bytes.iteri (fun n c ->
      drive i ~first:(n = 0) ~last:(n = Bytes.length b - 1) (Char.code c);
      step ();
      incr cycles) b) msgs;
  idle i;
  step ();
  let got, errors, _ = result () in
  Printf.printf "%d messages in %d cycles (no idle cycles); decoded %d; errors %d; identical: %b\n"
    (List.length msgs) !cycles (List.length got) (List.length errors) (got = msgs);
  [%expect {| 1000 messages in 29664 cycles (no idle cycles); decoded 1000; errors 0; identical: true |}]

let%expect_test "reset discards a partial message" =
  let sim, i, o = setup () in
  let step, result, _ = recorder sim o in
  Bytes.iteri (fun n c ->
    if n < 20 then (drive i ~first:(n = 0) ~last:false (Char.code c); step ())) sample;
  i.clear := Bits.vdd;
  idle i;
  step ();
  i.clear := Bits.gnd;
  step ();
  let partial, _, _ = result () in
  let after = send sim i o sample in
  assert (partial = [] && after = ([ aapl ], [], 0));
  print_endline "reset flushes a partial message; next message decodes normally";
  [%expect {| reset flushes a partial message; next message decodes normally |}]

let%expect_test "10,000 generated messages agree with the model encoder and order book" =
  let sim, i, o = setup () in
  let gen = Model.Feed_gen.create { Model.Feed_gen.default_config with seed = 8 } in
  let expected_book = ref Model.Order_book.empty in
  let parsed_book = ref Model.Order_book.empty in
  let apply book msg = match Model.Order_book.apply !book msg with
    | Ok next -> book := next
    | Error e -> failwith (Model.Order_book.error_to_string e)
  in
  for n = 1 to 10_000 do
    let msg = Model.Feed_gen.next gen in
    let actual =
      match send ~gaps:(n mod 7 = 0) sim i o (Model.Itch.encode msg) with
      | [ m ], [], 0 -> m
      | _ -> failwith (Printf.sprintf "message %d: expected exactly one output" n)
    in
    assert (actual = msg);
    apply expected_book msg;
    apply parsed_book actual;
    assert (Model.Order_book.best_bid !expected_book = Model.Order_book.best_bid !parsed_book);
    assert (Model.Order_book.best_ask !expected_book = Model.Order_book.best_ask !parsed_book);
    assert (Model.Order_book.live_orders !expected_book = Model.Order_book.live_orders !parsed_book)
  done;
  print_endline "10,000 messages: zero parser/model mismatches (seed 8)";
  [%expect {| 10,000 messages: zero parser/model mismatches (seed 8) |}]
