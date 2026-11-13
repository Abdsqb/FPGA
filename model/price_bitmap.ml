let levels = 64 * 64

(* 64-bit words: OCaml's [int] has only 63 bits, so the bitmap uses Int64,
   like the hardware's 64-bit registers. *)
let bit i = Int64.shift_left 1L i
let has_bit w i = not (Int64.equal (Int64.logand w (bit i)) 0L)

(* Highest / lowest set bit of a non-zero word. In hardware this is a
   priority encoder; here a plain loop is fine for a prototype. *)
let msb w =
  let rec go i = if has_bit w i then i else go (i - 1) in
  go 63

let lsb w =
  let rec go i = if has_bit w i then i else go (i + 1) in
  go 0

module Side = struct
  type t =
    { totals : int array  (** level -> total shares *)
    ; words : Int64.t array  (** 64 words; bit b of word w = level 64w + b is non-empty *)
    ; mutable summary : Int64.t  (** bit w set = word w has any non-empty level *)
    }

  let create () =
    { totals = Array.make levels 0; words = Array.make 64 0L; summary = 0L }

  let total t level = t.totals.(level)

  let add t level delta =
    let before = t.totals.(level) in
    let after = before + delta in
    if after < 0 then invalid_arg "Price_bitmap.Side.add: total would go below 0";
    t.totals.(level) <- after;
    let w = level / 64 and b = level mod 64 in
    if before = 0 && after > 0 then begin
      (* level became non-empty: set its bit, and its word's summary bit *)
      t.words.(w) <- Int64.logor t.words.(w) (bit b);
      t.summary <- Int64.logor t.summary (bit w)
    end
    else if before > 0 && after = 0 then begin
      (* level emptied: clear its bit; if the word is now empty, clear the
         summary bit too *)
      t.words.(w) <- Int64.logand t.words.(w) (Int64.lognot (bit b));
      if Int64.equal t.words.(w) 0L then
        t.summary <- Int64.logand t.summary (Int64.lognot (bit w))
    end

  (* Two lookups, like the hardware: summary -> word -> level. *)
  let highest t =
    if Int64.equal t.summary 0L then None
    else
      let w = msb t.summary in
      Some ((w * 64) + msb t.words.(w))

  let lowest t =
    if Int64.equal t.summary 0L then None
    else
      let w = lsb t.summary in
      Some ((w * 64) + lsb t.words.(w))
end

module Book = struct
  type order =
    { side : Msg.side
    ; level : int
    ; mutable remaining : int
    }

  type t =
    { base : int
    ; orders : order option array  (** the order table: 4,096 slots, as in Spec v1 *)
    ; bids : Side.t
    ; asks : Side.t
    ; mutable errors : int
    }

  let slots = 4096

  let create ~base =
    { base
    ; orders = Array.make slots None
    ; bids = Side.create ()
    ; asks = Side.create ()
    ; errors = 0
    }

  let side_of t = function
    | Msg.Buy -> t.bids
    | Msg.Sell -> t.asks

  let level_of_price t price =
    if price < t.base then None
    else
      let level = (price - t.base) / 100 in
      if level < levels then Some level else None

  let price_of_level t level = t.base + (level * 100)

  (* Spec v1: the book uses the low 12 bits of the order ref as the slot. *)
  let slot order_ref = order_ref land (slots - 1)

  let bad t = t.errors <- t.errors + 1

  let reduce t order_ref shares =
    match t.orders.(slot order_ref) with
    | None -> bad t
    | Some o when shares <= 0 || shares > o.remaining -> bad t
    | Some o ->
      Side.add (side_of t o.side) o.level (-shares);
      o.remaining <- o.remaining - shares;
      if o.remaining = 0 then t.orders.(slot order_ref) <- None

  let apply t (msg : Msg.t) =
    match msg with
    | Add_order { order_ref; side; price; shares } ->
      (match level_of_price t price, t.orders.(slot order_ref) with
       | None, _ -> bad t
       | Some _, Some _ -> bad t
       | Some _, None when shares <= 0 -> bad t
       | Some level, None ->
         Side.add (side_of t side) level shares;
         t.orders.(slot order_ref) <- Some { side; level; remaining = shares })
    | Order_executed { order_ref; shares } | Order_cancel { order_ref; shares } ->
      reduce t order_ref shares
    | Order_delete { order_ref } ->
      (match t.orders.(slot order_ref) with
       | None -> bad t
       | Some o ->
         Side.add (side_of t o.side) o.level (-o.remaining);
         t.orders.(slot order_ref) <- None)

  let best side_t pick t =
    match pick side_t with
    | None -> None
    | Some level -> Some (price_of_level t level, Side.total side_t level)

  let best_bid t = best t.bids Side.highest t
  let best_ask t = best t.asks Side.lowest t
  let errors t = t.errors
end
