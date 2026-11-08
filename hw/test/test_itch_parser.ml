open! Hardcaml
module P = Hw.Itch_parser
module Sim = Cyclesim.With_interface (P.I) (P.O)

let value r = Bits.to_int !r
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

let decoded (o : Bits.t ref P.O.t) =
  let order_ref = value o.order_ref and shares = value o.shares in
  match value o.kind with
  | 0 -> Model.Msg.Add_order
      { order_ref; shares; price = value o.price
      ; side = if value o.sell = 1 then Sell else Buy }
  | 1 -> Order_executed { order_ref; shares }
  | 2 -> Order_cancel { order_ref; shares }
  | 3 -> Order_delete { order_ref }
  | _ -> assert false

(* out_ready stays low until the caller has inspected the result.
   Error/filter pulses are sampled every cycle, including during input. *)
let send ?(gaps = false) ?(first = true) ?(extra_first = -1) sim
    (i : Bits.t ref P.I.t) (o : Bits.t ref P.O.t) data =
  let errors = ref [] and filtered = ref 0 in
  let step () =
    Cyclesim.cycle sim;
    if value o.error <> 0 then errors := value o.error :: !errors;
    filtered := !filtered + value o.filtered
  in
  i.out_ready := Bits.gnd;
  Bytes.iteri (fun n byte ->
    i.in_valid := Bits.gnd;
    if gaps && n mod 3 = 1 then (step (); step ());
    assert (value o.in_ready = 1);
    i.in_valid := Bits.vdd;
    i.in_data := Bits.of_int ~width:8 (Char.code byte);
    i.in_first := bit ((n = 0 && first) || n = extra_first);
    i.in_last := bit (n = Bytes.length data - 1);
    step ()) data;
  i.in_valid := Bits.gnd;
  i.in_first := Bits.gnd;
  i.in_last := Bits.gnd;
  step ();
  List.rev !errors, !filtered

let consume sim (i : Bits.t ref P.I.t) (o : Bits.t ref P.O.t) =
  assert (value o.out_valid = 1);
  i.out_ready := Bits.vdd;
  Cyclesim.cycle sim;
  assert (value o.out_valid = 0);
  i.out_ready := Bits.gnd

let from_hex s =
  String.split_on_char ' ' s
  |> List.filter (fun s -> s <> "")
  |> List.map (fun s -> Char.chr (int_of_string ("0x" ^ s)))
  |> List.to_seq |> Bytes.of_seq

let sample = from_hex
  "41 00 01 00 00 1f 1a ce d9 f0 00 00 00 00 00 00 00 00 2a 42 00 00 00 64 41 41 50 4c 20 20 20 20 00 16 ed 24"

let%expect_test "the reading guide's 36-byte AAPL Add, with bubbles and a stalled consumer" =
  let sim, i, o = setup () in
  assert (Bytes.length sample = 36);
  assert (send ~gaps:true sim i o sample = ([], 0));
  assert (value o.out_valid = 1);
  let expected = Model.Msg.Add_order
      { order_ref = 42; side = Buy; shares = 100; price = 1_502_500 } in
  assert (decoded o = expected);
  assert (value o.timestamp_ns = 34_200_000_000_000);
  (* A producer may present the next byte while ready is low. It must not
     overwrite the pending output or advance the parser. *)
  i.in_valid := Bits.vdd;
  i.in_first := Bits.vdd;
  i.in_data := Bits.of_int ~width:8 0x44;
  for _ = 1 to 8 do
    assert (value o.in_ready = 0);
    Cyclesim.cycle sim;
    assert (value o.out_valid = 1 && decoded o = expected);
    assert (value o.timestamp_ns = 34_200_000_000_000)
  done;
  i.in_valid := Bits.gnd;
  print_endline (Model.Msg.to_string (decoded o));
  Printf.printf "timestamp_ns=%d; stable through 8 stalled cycles\n" (value o.timestamp_ns);
  consume sim i o;
  [%expect {|
    Add_order      order_ref=42 B 100 @ 1502500
    timestamp_ns=34200000000000; stable through 8 stalled cycles
    |}]

let%expect_test "all message types, zeroed irrelevant fields, and unsigned 32-bit boundaries" =
  let sim, i, o = setup () in
  let messages = Model.Msg.[
    Add_order { order_ref = 4095; side = Sell; shares = 0xFFFF_FFFF; price = 2_000_000_000 };
    Order_executed { order_ref = 4095; shares = 0x8000_0000 };
    Order_cancel { order_ref = 0; shares = 0xFFFF_FFFF };
    Order_delete { order_ref = 0 } ] in
  List.iter (fun msg ->
    assert (send sim i o (Model.Itch.encode msg) = ([], 0));
    assert (value o.out_valid = 1 && decoded o = msg);
    if value o.kind <> 0 then assert (value o.price = 0 && value o.sell = 0);
    if value o.kind = 3 then assert (value o.shares = 0);
    consume sim i o) messages;
  print_endline "A/E/X/D match; IDs 0 and 4095 and unsigned shares preserved";
  [%expect {| A/E/X/D match; IDs 0 and 4095 and unsigned shares preserved |}]

let%expect_test "bad frames recover; foreign stock is filtered; full 64-bit ID is checked" =
  let sim, i, o = setup () in
  let mutation pos v = let b = Bytes.copy sample in Bytes.set_uint8 b pos v; b in
  let check ?(first=true) ?(extra_first = -1) bytes code =
    assert (send ~first ~extra_first sim i o bytes = ([code], 0));
    assert (value o.out_valid = 0);
    assert (send sim i o sample = ([], 0));
    consume sim i o
  in
  check (Bytes.sub sample 0 35) 2;
  check (Bytes.cat sample (Bytes.make 8 '\000')) 2;
  check (mutation 0 (Char.code 'U')) 3;
  check (mutation 19 (Char.code '?')) 4;
  check (mutation 17 0x10) 5; (* 4096 + low byte: never aliases slot 42 *)
  check (mutation 11 0x80) 5; (* high bit of the wire's 64-bit ID *)
  check ~first:false sample 1;
  check ~extra_first:8 sample 1;
  assert (send sim i o (mutation 2 2) = ([], 1));
  assert (value o.out_valid = 0);
  print_endline "8 malformed cases rejected and recovered; foreign stock filtered";
  [%expect {| 8 malformed cases rejected and recovered; foreign stock filtered |}]

let%expect_test "reset discards a partial frame and a pending output" =
  let sim, i, o = setup () in
  i.in_valid := Bits.vdd;
  i.in_first := Bits.vdd;
  i.in_data := Bits.of_int ~width:8 0x41;
  Cyclesim.cycle sim;
  let reset () =
    i.clear := Bits.vdd;
    Cyclesim.cycle sim;
    i.in_valid := Bits.gnd;
    i.clear := Bits.gnd;
    Cyclesim.cycle sim;
    assert (value o.out_valid = 0 && value o.in_ready = 1)
  in
  reset ();
  assert (send sim i o sample = ([], 0));
  reset ();
  assert (send sim i o sample = ([], 0));
  consume sim i o;
  print_endline "reset flushes partial and pending messages";
  [%expect {| reset flushes partial and pending messages |}]

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
    assert (send ~gaps:(n mod 7 = 0) sim i o (Model.Itch.encode msg) = ([], 0));
    assert (value o.out_valid = 1 && decoded o = msg);
    let actual = decoded o in
    for _ = 1 to n mod 5 do
      Cyclesim.cycle sim;
      assert (value o.out_valid = 1 && decoded o = actual)
    done;
    apply expected_book msg;
    apply parsed_book actual;
    assert (Model.Order_book.best_bid !expected_book = Model.Order_book.best_bid !parsed_book);
    assert (Model.Order_book.best_ask !expected_book = Model.Order_book.best_ask !parsed_book);
    assert (Model.Order_book.live_orders !expected_book = Model.Order_book.live_orders !parsed_book);
    consume sim i o
  done;
  print_endline "10,000 messages: zero parser/model mismatches (seed 8)";
  [%expect {| 10,000 messages: zero parser/model mismatches (seed 8) |}]
