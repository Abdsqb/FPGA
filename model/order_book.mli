(** Reference model: a top-of-book order book for one symbol.

    This is the answer key the Hardcaml core is tested against. It favours
    being obviously correct over being fast.

    Semantics (keep in sync with the team spec):
    - [Add_order] inserts a live order. Re-using a live order_ref is an error.
    - [Order_executed] and [Order_cancel] reduce an order's remaining shares. Reducing
      by more than remain is an error. An order that reaches 0 is removed.
    - [Order_delete] removes the order whatever its remaining shares.
    - Best bid / best ask report the price and the TOTAL shares resting at
      that price level, not the size of a single order. *)

type t

type error =
  | Unknown_order of int
  | Duplicate_order of int
  | Over_reduce of
      { order_ref : int
      ; remaining : int
      ; requested : int
      }
  | Bad_field of string

val empty : t

(** Apply one message. Invalid messages leave the book unchanged. *)
val apply : t -> Msg.t -> (t, error) result

(** [(price, total_qty)] at the highest bid price. *)
val best_bid : t -> (int * int) option

(** [(price, total_qty)] at the lowest ask price. *)
val best_ask : t -> (int * int) option

val live_orders : t -> int
val error_to_string : error -> string

(** e.g. ["bid 10000 x 300 | ask 10050 x 100"]; used by expect tests and the
    testbench's mismatch reports. *)
val top_to_string : t -> string
