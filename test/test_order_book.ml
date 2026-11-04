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
