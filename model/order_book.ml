module IntMap = Map.Make (Int)

type order =
  { side : Msg.side
  ; price : int
  ; remaining : int
  }

(* [orders]: every live order by order_ref. ITCH Order_executed/Order_cancel/Order_delete carry only
   the order_ref, so we must remember each order's side and price to find its
   price level. The hardware keeps the same table in block RAM.

   [bids] / [asks]: price -> total remaining shares at that price. Only
   non-empty levels are stored, so the best price is the max / min key. *)
type t =
  { orders : order IntMap.t
  ; bids : int IntMap.t
  ; asks : int IntMap.t
  }

type error =
  | Unknown_order of int
  | Duplicate_order of int
  | Over_reduce of
      { order_ref : int
      ; remaining : int
      ; requested : int
      }
  | Bad_field of string

let empty = { orders = IntMap.empty; bids = IntMap.empty; asks = IntMap.empty }

let error_to_string = function
  | Unknown_order order_ref -> Printf.sprintf "unknown order ref %d" order_ref
  | Duplicate_order order_ref -> Printf.sprintf "duplicate order ref %d" order_ref
  | Over_reduce { order_ref; remaining; requested } ->
    Printf.sprintf "order %d: asked to remove %d shares but only %d remain" order_ref
      requested remaining
  | Bad_field s -> "bad field: " ^ s

let levels t = function
  | Msg.Buy -> t.bids
  | Msg.Sell -> t.asks

let with_levels t side l =
  match side with
  | Msg.Buy -> { t with bids = l }
  | Msg.Sell -> { t with asks = l }

(* Add [delta] (possibly negative) shares at [price]; drop empty levels. *)
let adjust_level t side price delta =
  let l = levels t side in
  let cur = Option.value (IntMap.find_opt price l) ~default:0 in
  let next = cur + delta in
  let l = if next = 0 then IntMap.remove price l else IntMap.add price next l in
  with_levels t side l

let reduce t order_ref shares =
  match IntMap.find_opt order_ref t.orders with
  | None -> Error (Unknown_order order_ref)
  | Some o when shares <= 0 -> ignore o; Error (Bad_field "reduce shares must be > 0")
  | Some o when shares > o.remaining ->
    Error (Over_reduce { order_ref; remaining = o.remaining; requested = shares })
  | Some o ->
    let t = adjust_level t o.side o.price (-shares) in
    let remaining = o.remaining - shares in
    let orders =
      if remaining = 0 then IntMap.remove order_ref t.orders
      else IntMap.add order_ref { o with remaining } t.orders
    in
    Ok { t with orders }

let apply t (msg : Msg.t) =
  match msg with
  | Add_order { order_ref; side; price; shares } ->
    if IntMap.mem order_ref t.orders then Error (Duplicate_order order_ref)
    else if shares <= 0 then Error (Bad_field "add shares must be > 0")
    else if price <= 0 then Error (Bad_field "price must be > 0")
    else
      let t = adjust_level t side price shares in
      Ok { t with orders = IntMap.add order_ref { side; price; remaining = shares } t.orders }
  | Order_executed { order_ref; shares } | Order_cancel { order_ref; shares } -> reduce t order_ref shares
  | Order_delete { order_ref } ->
    (match IntMap.find_opt order_ref t.orders with
     | None -> Error (Unknown_order order_ref)
     | Some o ->
       let t = adjust_level t o.side o.price (-o.remaining) in
       Ok { t with orders = IntMap.remove order_ref t.orders })

let best_bid t = IntMap.max_binding_opt t.bids
let best_ask t = IntMap.min_binding_opt t.asks
let live_orders t = IntMap.cardinal t.orders

let top_to_string t =
  let f = function
    | None -> "-"
    | Some (p, q) -> Printf.sprintf "%d x %d" p q
  in
  Printf.sprintf "bid %s | ask %s" (f (best_bid t)) (f (best_ask t))
