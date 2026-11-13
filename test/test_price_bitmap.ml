(* Week 2: check the next-best-price bitmap prototype (Spec v1) against
   (1) a simple scan over the share totals, and
   (2) the reference model [Order_book], on random feeds. *)

open Model
module Side = Price_bitmap.Side
module Book = Price_bitmap.Book

(* The simple scan: look at every level, no bitmap. *)
let scan_highest s =
  let rec go l = if l < 0 then None else if Side.total s l > 0 then Some l else go (l - 1) in
  go (Price_bitmap.levels - 1)

let scan_lowest s =
  let rec go l =
    if l >= Price_bitmap.levels then None else if Side.total s l > 0 then Some l else go (l + 1)
  in
  go 0

let show = function None -> "-" | Some l -> string_of_int l

let%expect_test "one side by hand: word and summary boundaries" =
  let s = Side.create () in
  let print () = Printf.printf "highest %-5s lowest %s\n" (show (Side.highest s)) (show (Side.lowest s)) in
  print ();
  Side.add s 63 100;   (* last level of word 0 *)
  Side.add s 64 100;   (* first level of word 1 *)
  Side.add s 4095 50;  (* very last level *)
  Side.add s 0 10;     (* very first level *)
  print ();
  Side.add s 4095 (-50);  (* word 63 empties: summary bit must clear *)
  Side.add s 0 (-10);
  print ();
  Side.add s 64 (-40);    (* partly reduced: still non-empty *)
  print ();
  Side.add s 64 (-60);
  Side.add s 63 (-100);   (* everything empty again *)
  print ();
  [%expect {|
    highest -     lowest -
    highest 4095  lowest 0
    highest 64    lowest 63
    highest 64    lowest 63
    highest -     lowest -
    |}]

let%expect_test "random adds and removes on one side: bitmap always matches the scan" =
  let rng = Random.State.make [| 7 |] in
  let s = Side.create () in
  let mismatches = ref 0 and ops = 300_000 in
  for _ = 1 to ops do
    let level =
      (* cluster some levels near word edges, spread the rest *)
      if Random.State.bool rng then Random.State.int rng Price_bitmap.levels
      else (64 * Random.State.int rng 64) + (if Random.State.bool rng then 0 else 63)
    in
    let total = Side.total s level in
    let delta =
      if total > 0 && Random.State.bool rng then -(1 + Random.State.int rng total)
      else 1 + Random.State.int rng 500
    in
    Side.add s level delta;
    if Side.highest s <> scan_highest s || Side.lowest s <> scan_lowest s then incr mismatches
  done;
  Printf.printf "%d random operations: %d bitmap/scan mismatches\n" ops !mismatches;
  [%expect {| 300000 random operations: 0 bitmap/scan mismatches |}]

(* Run one random feed through the bitmap book and the reference model and
   compare best bid / best ask after every message. *)
let compare_with_model ~name ~cfg ~base ~n =
  let gen = Feed_gen.create cfg in
  let book = Book.create ~base in
  let model = ref Order_book.empty in
  let mismatches = ref 0 in
  for _ = 1 to n do
    let m = Feed_gen.next gen in
    Book.apply book m;
    (match Order_book.apply !model m with Ok b -> model := b | Error _ -> ());
    if Book.best_bid book <> Order_book.best_bid !model
       || Book.best_ask book <> Order_book.best_ask !model
    then incr mismatches
  done;
  Printf.printf "%s: %d messages, %d mismatches with the model, %d errors\n"
    name n !mismatches (Book.errors book)

let%expect_test "random feeds: bitmap book matches the reference model after every message" =
  (* Base = bottom of the window. Mid $100.00, so base = mid - 2,048 cents. *)
  let mid = 1_000_000 in
  let base = mid - (2048 * 100) in
  compare_with_model ~name:"default feed (8 levels each side)"
    ~cfg:Feed_gen.default_config ~base ~n:200_000;
  (* Prices spread over +/- 2,000 cents: about 63 of the 64 words in use,
     so the two-level search really has to search. *)
  compare_with_model ~name:"wide feed (2,000 levels each side)"
    ~cfg:{ Feed_gen.default_config with seed = 5; levels = 2000 } ~base ~n:200_000;
  [%expect {|
    default feed (8 levels each side): 200000 messages, 0 mismatches with the model, 0 errors
    wide feed (2,000 levels each side): 200000 messages, 0 mismatches with the model, 0 errors
    |}]

let%expect_test "bad input is ignored and counted (Spec v1 rule 4)" =
  let base = 795_200 in
  let book = Book.create ~base in
  let apply m =
    Book.apply book m;
    let f = function None -> "-" | Some (p, q) -> Printf.sprintf "%d x %d" p q in
    Printf.printf "%-44s -> bid %s | ask %s | errors %d\n" (Msg.to_string m)
      (f (Book.best_bid book)) (f (Book.best_ask book)) (Book.errors book)
  in
  apply (Add_order { order_ref = 1; side = Buy; price = 999_900; shares = 100 });
  apply (Add_order { order_ref = 2; side = Buy; price = base - 100; shares = 100 });         (* below the window *)
  apply (Add_order { order_ref = 3; side = Sell; price = base + (4096 * 100); shares = 100 }); (* above it *)
  apply (Order_cancel { order_ref = 9; shares = 1 });                                     (* unknown ref *)
  apply (Order_executed { order_ref = 1; shares = 101 });                                 (* too many shares *)
  apply (Add_order { order_ref = 1; side = Sell; price = 1_000_100; shares = 5 });        (* ref already live *)
  apply (Order_delete { order_ref = 1 });
  [%expect {|
    Add_order      order_ref=1 B 100 @ 999900    -> bid 999900 x 100 | ask - | errors 0
    Add_order      order_ref=2 B 100 @ 795100    -> bid 999900 x 100 | ask - | errors 1
    Add_order      order_ref=3 S 100 @ 1204800   -> bid 999900 x 100 | ask - | errors 2
    Order_cancel   order_ref=9 shares=1          -> bid 999900 x 100 | ask - | errors 3
    Order_executed order_ref=1 shares=101        -> bid 999900 x 100 | ask - | errors 4
    Add_order      order_ref=1 S 5 @ 1000100     -> bid 999900 x 100 | ask - | errors 5
    Order_delete   order_ref=1                   -> bid - | ask - | errors 5
    |}]
