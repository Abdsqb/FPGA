(** Random feed generator: an endless stream of VALID messages.

    "Valid" means the stream never breaks the rules the hardware relies on:
    - order ids are in [0, max_orders) and a live order_ref is never re-added;
    - Order_executed / Order_cancel / Order_delete only target live orders;
    - Order_executed / Order_cancel never remove more shares than remain;
    - bids sit below [mid] and asks above it, so the book never crosses
      (we do not model matching).

    The same [seed] always gives the same stream, so a failing test can be
    replayed exactly. *)

type config =
  { seed : int
  ; max_orders : int  (** table size; 4096 by team decision *)
  ; mid : int  (** reference price in ticks, e.g. 1_000_000 = $100.0000 *)
  ; tick : int  (** price step, e.g. 100 = one cent *)
  ; levels : int
        (** prices are mid +/- tick * [1..levels]; few levels means price
            levels empty and refill often, which stresses next-best logic *)
  ; max_lots : int  (** shares is 100 * [1..max_lots] *)
  }

val default_config : config

type t

val create : config -> t

(** Next valid message. *)
val next : t -> Msg.t

(** [generate config n] is the first [n] messages for [config]. *)
val generate : config -> int -> Msg.t list

(** Number of live orders the generator believes exist. *)
val live : t -> int
