(** Prototype of Spec v1's next-best-price structure ("Next-best price"):
    per side, an array of total shares per price level plus a two-level
    bitmap (64 words x 64 bits) marking which levels are non-empty.

    This mirrors what the hardware will do, step by step, so the design can
    be checked in software before anyone writes it in Hardcaml. It is NOT the
    reference model: [Order_book] stays a separate, simple answer key, and
    the tests check this prototype against it and against a plain scan.

    Finding the best level takes two lookups, like the hardware's 2-cycle
    priority encoder:
    + the summary word says which of the 64 words has any non-empty level;
    + that word says which of its 64 levels is non-empty. *)

(** Number of price levels per side: 64 x 64 = 4,096. *)
val levels : int

(** One side of the book: share totals per level, plus the bitmap. *)
module Side : sig
  type t

  val create : unit -> t

  (** [add t level delta] changes the total at [level] by [delta] shares
      (negative to remove) and keeps the bitmap in step: a level's bit is set
      exactly when its total is above 0. Raises if the total would go below 0. *)
  val add : t -> int -> int -> unit

  (** Total shares at a level. *)
  val total : t -> int -> int

  (** Highest non-empty level (best bid), using the bitmap. *)
  val highest : t -> int option

  (** Lowest non-empty level (best ask), using the bitmap. *)
  val lowest : t -> int option
end

(** A whole book (both sides plus the order table) built on [Side], following
    Spec v1's order-book rules. *)
module Book : sig
  type t

  (** [create ~base] makes an empty book whose window covers prices
      [base], [base + 100], ..., [base + 4095 * 100] (one level per cent,
      in ITCH units of $0.0001).

      OPEN QUESTION (team): Spec v1 says the window is "around a base price
      set at reset" but not whether [base] is the bottom or the centre.
      Here it is the bottom (level = (price - base) / 100, as in the spec's
      formula); change it once the team decides. *)
  val create : base:int -> t

  (** Price -> level, per Spec v1: (price - base) / 100, or [None] outside
      the window. A price that isn't a whole cent above [base] lands on the
      level below it (the spec's divide truncates); whether that should be
      bad input is another OPEN QUESTION. *)
  val level_of_price : t -> int -> int option

  (** Apply one message (Spec v1 rules 1-4). Bad input is ignored and counts
      one error: an unknown order ref, a price outside the window, removing
      more shares than the order has, and (as in the reference model) an Add
      to a live order ref or with 0 shares. *)
  val apply : t -> Msg.t -> unit

  (** [(price, total shares)] at the best level, as in [Order_book]. *)
  val best_bid : t -> (int * int) option

  val best_ask : t -> (int * int) option

  (** Bad messages seen so far (Spec v1 rule 4's error counter). *)
  val errors : t -> int
end
