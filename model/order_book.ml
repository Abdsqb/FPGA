module IntMap = Map.Make (Int)

type order =
  { side : Msg.side
  ; price : int
  ; remaining : int
  }

(* [orders]: every live order by id. ITCH Executed/Cancel/Delete carry only
   the id, so we must remember each order's side and price to find its
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
      { id : int
      ; remaining : int
      ; requested : int
      }
  | Bad_field of string

let empty = { orders = IntMap.empty; bids = IntMap.empty; asks = IntMap.empty }

let error_to_string = function
  | Unknown_order id -> Printf.sprintf "unknown order id %d" id
  | Duplicate_order id -> Printf.sprintf "duplicate order id %d" id
  | Over_reduce { id; remaining; requested } ->
    Printf.sprintf "order %d: asked to remove %d shares but only %d remain" id
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

let reduce t id qty =
  match IntMap.find_opt id t.orders with
  | None -> Error (Unknown_order id)
  | Some o when qty <= 0 -> ignore o; Error (Bad_field "reduce qty must be > 0")
  | Some o when qty > o.remaining ->
    Error (Over_reduce { id; remaining = o.remaining; requested = qty })
  | Some o ->
    let t = adjust_level t o.side o.price (-qty) in
    let remaining = o.remaining - qty in
    let orders =
      if remaining = 0 then IntMap.remove id t.orders
      else IntMap.add id { o with remaining } t.orders
    in
    Ok { t with orders }

let apply t (msg : Msg.t) =
  match msg with
  | Add { id; side; price; qty } ->
    if IntMap.mem id t.orders then Error (Duplicate_order id)
    else if qty <= 0 then Error (Bad_field "add qty must be > 0")
    else if price <= 0 then Error (Bad_field "price must be > 0")
    else
      let t = adjust_level t side price qty in
      Ok { t with orders = IntMap.add id { side; price; remaining = qty } t.orders }
  | Executed { id; qty } | Cancel { id; qty } -> reduce t id qty
  | Delete { id } ->
    (match IntMap.find_opt id t.orders with
     | None -> Error (Unknown_order id)
     | Some o ->
       let t = adjust_level t o.side o.price (-o.remaining) in
       Ok { t with orders = IntMap.remove id t.orders })

let best_bid t = IntMap.max_binding_opt t.bids
let best_ask t = IntMap.min_binding_opt t.asks
let live_orders t = IntMap.cardinal t.orders

let top_to_string t =
  let f = function
    | None -> "-"
    | Some (p, q) -> Printf.sprintf "%d x %d" p q
  in
  Printf.sprintf "bid %s | ask %s" (f (best_bid t)) (f (best_ask t))
