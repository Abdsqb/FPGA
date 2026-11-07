(* Hand-written scenarios. Each step prints the message and the resulting
   top of book; the expected output lives right here in the file. *)

open Model

let run msgs =
  let book = ref Order_book.empty in
  List.iter
    (fun m ->
      match Order_book.apply !book m with
      | Ok b ->
        book := b;
        Printf.printf "%-44s -> %s\n" (Msg.to_string m) (Order_book.top_to_string b)
      | Error e ->
        Printf.printf "%-44s -> REJECTED: %s\n" (Msg.to_string m)
          (Order_book.error_to_string e))
    msgs

let%expect_test "build a book, then empty the best level" =
  run
    [ Add_order { order_ref = 0; side = Buy; price = 999_900; shares = 100 }
    ; Add_order { order_ref = 1; side = Buy; price = 999_900; shares = 200 }
    ; Add_order { order_ref = 2; side = Buy; price = 999_800; shares = 500 }
    ; Add_order { order_ref = 3; side = Sell; price = 1_000_100; shares = 300 }
    ; Order_executed { order_ref = 0; shares = 100 } (* fully filled: order 0 gone *)
    ; Order_cancel { order_ref = 1; shares = 50 } (* partial cancel *)
    ; Order_delete { order_ref = 1 } (* best bid level now empty -> next best *)
    ; Order_delete { order_ref = 3 } (* ask side empty *)
    ];
  [%expect {|
    Add_order      order_ref=0 B 100 @ 999900    -> bid 999900 x 100 | ask -
    Add_order      order_ref=1 B 200 @ 999900    -> bid 999900 x 300 | ask -
    Add_order      order_ref=2 B 500 @ 999800    -> bid 999900 x 300 | ask -
    Add_order      order_ref=3 S 300 @ 1000100   -> bid 999900 x 300 | ask 1000100 x 300
    Order_executed order_ref=0 shares=100        -> bid 999900 x 200 | ask 1000100 x 300
    Order_cancel   order_ref=1 shares=50         -> bid 999900 x 150 | ask 1000100 x 300
    Order_delete   order_ref=1                   -> bid 999800 x 500 | ask 1000100 x 300
    Order_delete   order_ref=3                   -> bid 999800 x 500 | ask -
    |}]

let%expect_test "invalid messages are rejected and change nothing" =
  run
    [ Add_order { order_ref = 7; side = Sell; price = 1_000_200; shares = 100 }
    ; Add_order { order_ref = 7; side = Sell; price = 1_000_300; shares = 100 }
    ; Order_executed { order_ref = 7; shares = 101 }
    ; Order_cancel { order_ref = 99; shares = 1 }
    ; Order_delete { order_ref = 99 }
    ];
  [%expect {|
    Add_order      order_ref=7 S 100 @ 1000200   -> bid - | ask 1000200 x 100
    Add_order      order_ref=7 S 100 @ 1000300   -> REJECTED: duplicate order ref 7
    Order_executed order_ref=7 shares=101        -> REJECTED: order 7: asked to remove 101 shares but only 100 remain
    Order_cancel   order_ref=99 shares=1         -> REJECTED: unknown order ref 99
    Order_delete   order_ref=99                  -> REJECTED: unknown order ref 99
    |}]

let%expect_test "an order_ref can be reused once its order is gone" =
  run
    [ Add_order { order_ref = 5; side = Buy; price = 999_500; shares = 100 }
    ; Order_delete { order_ref = 5 }
    ; Add_order { order_ref = 5; side = Sell; price = 1_000_500; shares = 400 }
    ];
  [%expect {|
    Add_order      order_ref=5 B 100 @ 999500    -> bid 999500 x 100 | ask -
    Order_delete   order_ref=5                   -> bid - | ask -
    Add_order      order_ref=5 S 400 @ 1000500   -> bid - | ask 1000500 x 400
    |}]

(* One focused test per message type, as asked in the week-1 plan. *)

let%expect_test "Add_order: totals per price level, better prices take over" =
  run
    [ Add_order { order_ref = 0; side = Buy; price = 999_800; shares = 100 }
    ; Add_order { order_ref = 1; side = Buy; price = 999_800; shares = 200 } (* same level: totals add *)
    ; Add_order { order_ref = 2; side = Buy; price = 999_900; shares = 50 } (* higher bid: new best *)
    ; Add_order { order_ref = 3; side = Buy; price = 999_700; shares = 900 } (* lower bid: best unchanged *)
    ; Add_order { order_ref = 4; side = Sell; price = 1_000_300; shares = 100 }
    ; Add_order { order_ref = 5; side = Sell; price = 1_000_200; shares = 100 } (* lower ask: new best *)
    ];
  [%expect {|
    Add_order      order_ref=0 B 100 @ 999800    -> bid 999800 x 100 | ask -
    Add_order      order_ref=1 B 200 @ 999800    -> bid 999800 x 300 | ask -
    Add_order      order_ref=2 B 50 @ 999900     -> bid 999900 x 50 | ask -
    Add_order      order_ref=3 B 900 @ 999700    -> bid 999900 x 50 | ask -
    Add_order      order_ref=4 S 100 @ 1000300   -> bid 999900 x 50 | ask 1000300 x 100
    Add_order      order_ref=5 S 100 @ 1000200   -> bid 999900 x 50 | ask 1000200 x 100
    |}]

let%expect_test "Order_executed: partial fill shrinks, full fill removes" =
  run
    [ Add_order { order_ref = 0; side = Sell; price = 1_000_100; shares = 300 }
    ; Add_order { order_ref = 1; side = Sell; price = 1_000_200; shares = 400 }
    ; Order_executed { order_ref = 0; shares = 100 } (* 200 left *)
    ; Order_executed { order_ref = 0; shares = 200 } (* filled: next best ask appears *)
    ; Order_executed { order_ref = 0; shares = 1 } (* order is gone *)
    ];
  [%expect {|
    Add_order      order_ref=0 S 300 @ 1000100   -> bid - | ask 1000100 x 300
    Add_order      order_ref=1 S 400 @ 1000200   -> bid - | ask 1000100 x 300
    Order_executed order_ref=0 shares=100        -> bid - | ask 1000100 x 200
    Order_executed order_ref=0 shares=200        -> bid - | ask 1000200 x 400
    Order_executed order_ref=0 shares=1          -> REJECTED: unknown order ref 0
    |}]

let%expect_test "Order_cancel: partial cancel shrinks, cancelling everything removes" =
  run
    [ Add_order { order_ref = 0; side = Buy; price = 999_900; shares = 500 }
    ; Add_order { order_ref = 1; side = Buy; price = 999_800; shares = 100 }
    ; Order_cancel { order_ref = 0; shares = 200 } (* 300 left *)
    ; Order_cancel { order_ref = 0; shares = 301 } (* more than remain: rejected *)
    ; Order_cancel { order_ref = 0; shares = 300 } (* all cancelled: next best bid *)
    ];
  [%expect {|
    Add_order      order_ref=0 B 500 @ 999900    -> bid 999900 x 500 | ask -
    Add_order      order_ref=1 B 100 @ 999800    -> bid 999900 x 500 | ask -
    Order_cancel   order_ref=0 shares=200        -> bid 999900 x 300 | ask -
    Order_cancel   order_ref=0 shares=301        -> REJECTED: order 0: asked to remove 301 shares but only 300 remain
    Order_cancel   order_ref=0 shares=300        -> bid 999800 x 100 | ask -
    |}]

let%expect_test "Order_delete: removes the whole order, whatever is left" =
  run
    [ Add_order { order_ref = 0; side = Sell; price = 1_000_100; shares = 700 }
    ; Add_order { order_ref = 1; side = Sell; price = 1_000_100; shares = 100 }
    ; Order_executed { order_ref = 0; shares = 50 } (* level now 750 *)
    ; Order_delete { order_ref = 0 } (* removes its remaining 650 *)
    ; Order_delete { order_ref = 1 } (* level empty: no asks *)
    ; Order_delete { order_ref = 1 } (* already gone *)
    ];
  [%expect {|
    Add_order      order_ref=0 S 700 @ 1000100   -> bid - | ask 1000100 x 700
    Add_order      order_ref=1 S 100 @ 1000100   -> bid - | ask 1000100 x 800
    Order_executed order_ref=0 shares=50         -> bid - | ask 1000100 x 750
    Order_delete   order_ref=0                   -> bid - | ask 1000100 x 100
    Order_delete   order_ref=1                   -> bid - | ask -
    Order_delete   order_ref=1                   -> REJECTED: unknown order ref 1
    |}]
