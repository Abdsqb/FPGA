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
        Printf.printf "%-28s -> %s\n" (Msg.to_string m) (Order_book.top_to_string b)
      | Error e ->
        Printf.printf "%-28s -> REJECTED: %s\n" (Msg.to_string m)
          (Order_book.error_to_string e))
    msgs

let%expect_test "build a book, then empty the best level" =
  run
    [ Add { id = 0; side = Buy; price = 999_900; qty = 100 }
    ; Add { id = 1; side = Buy; price = 999_900; qty = 200 }
    ; Add { id = 2; side = Buy; price = 999_800; qty = 500 }
    ; Add { id = 3; side = Sell; price = 1_000_100; qty = 300 }
    ; Executed { id = 0; qty = 100 } (* fully filled: order 0 gone *)
    ; Cancel { id = 1; qty = 50 } (* partial cancel *)
    ; Delete { id = 1 } (* best bid level now empty -> next best *)
    ; Delete { id = 3 } (* ask side empty *)
    ];
  [%expect {|
    Add      id=0 B 100 @ 999900 -> bid 999900 x 100 | ask -
    Add      id=1 B 200 @ 999900 -> bid 999900 x 300 | ask -
    Add      id=2 B 500 @ 999800 -> bid 999900 x 300 | ask -
    Add      id=3 S 300 @ 1000100 -> bid 999900 x 300 | ask 1000100 x 300
    Executed id=0 qty=100        -> bid 999900 x 200 | ask 1000100 x 300
    Cancel   id=1 qty=50         -> bid 999900 x 150 | ask 1000100 x 300
    Delete   id=1                -> bid 999800 x 500 | ask 1000100 x 300
    Delete   id=3                -> bid 999800 x 500 | ask -
    |}]

let%expect_test "invalid messages are rejected and change nothing" =
  run
    [ Add { id = 7; side = Sell; price = 1_000_200; qty = 100 }
    ; Add { id = 7; side = Sell; price = 1_000_300; qty = 100 }
    ; Executed { id = 7; qty = 101 }
    ; Cancel { id = 99; qty = 1 }
    ; Delete { id = 99 }
    ];
  [%expect {|
    Add      id=7 S 100 @ 1000200 -> bid - | ask 1000200 x 100
    Add      id=7 S 100 @ 1000300 -> REJECTED: duplicate order id 7
    Executed id=7 qty=101        -> REJECTED: order 7: asked to remove 101 shares but only 100 remain
    Cancel   id=99 qty=1         -> REJECTED: unknown order id 99
    Delete   id=99               -> REJECTED: unknown order id 99
    |}]

let%expect_test "an id can be reused once its order is gone" =
  run
    [ Add { id = 5; side = Buy; price = 999_500; qty = 100 }
    ; Delete { id = 5 }
    ; Add { id = 5; side = Sell; price = 1_000_500; qty = 400 }
    ];
  [%expect {|
    Add      id=5 B 100 @ 999500 -> bid 999500 x 100 | ask -
    Delete   id=5                -> bid - | ask -
    Add      id=5 S 400 @ 1000500 -> bid - | ask 1000500 x 400
    |}]
