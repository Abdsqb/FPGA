(* The generator promises a valid stream. Check it by feeding long streams
   to the reference model: every message must be accepted, and the book
   must never cross. *)

open Model

let check ~seed ~n ~max_orders =
  let cfg = { Feed_gen.default_config with seed; max_orders } in
  let g = Feed_gen.create cfg in
  let book = ref Order_book.empty in
  let errors = ref 0 and crossed = ref 0 and counts = Array.make 4 0 in
  let peak = ref 0 in
  for _ = 1 to n do
    let m = Feed_gen.next g in
    let k = match m with Add_order _ -> 0 | Order_executed _ -> 1 | Order_cancel _ -> 2 | Order_delete _ -> 3 in
    counts.(k) <- counts.(k) + 1;
    (match Order_book.apply !book m with
     | Ok b -> book := b
     | Error e ->
       incr errors;
       if !errors <= 3 then print_endline (Order_book.error_to_string e));
    (match Order_book.best_bid !book, Order_book.best_ask !book with
     | Some (b, _), Some (a, _) when b >= a -> incr crossed
     | _ -> ());
    peak := max !peak (Order_book.live_orders !book);
    assert (Order_book.live_orders !book = Feed_gen.live g)
  done;
  Printf.printf
    "seed %d: %d msgs (A %d / E %d / X %d / D %d), errors %d, crossed %d, peak live %d\n"
    seed n counts.(0) counts.(1) counts.(2) counts.(3) !errors !crossed !peak

let%expect_test "long random streams are always valid" =
  check ~seed:1 ~n:200_000 ~max_orders:4096;
  check ~seed:2 ~n:200_000 ~max_orders:4096;
  (* a tiny table forces the "no free ids" path *)
  check ~seed:3 ~n:50_000 ~max_orders:16;
  [%expect {|
    seed 1: 200000 msgs (A 59186 / E 51265 / X 38484 / D 51065), errors 0, crossed 0, peak live 4096
    seed 2: 200000 msgs (A 59362 / E 51279 / X 38194 / D 51165), errors 0, crossed 0, peak live 4096
    seed 3: 50000 msgs (A 14220 / E 13000 / X 9679 / D 13101), errors 0, crossed 0, peak live 16
    |}]

let%expect_test "same seed, same stream" =
  let a = Feed_gen.generate Feed_gen.default_config 1000 in
  let b = Feed_gen.generate Feed_gen.default_config 1000 in
  print_endline (string_of_bool (a = b));
  List.iteri (fun i m -> if i < 6 then print_endline (Msg.to_string m)) a;
  [%expect {|
    true
    Add_order      order_ref=0 S 800 @ 1000100
    Order_delete   order_ref=0
    Add_order      order_ref=0 B 700 @ 999700
    Order_executed order_ref=0 shares=412
    Order_executed order_ref=0 shares=124
    Order_cancel   order_ref=0 shares=130
    |}]
