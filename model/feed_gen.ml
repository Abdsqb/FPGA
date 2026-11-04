type config =
  { seed : int
  ; max_orders : int
  ; mid : int
  ; tick : int
  ; levels : int
  ; max_lots : int
  }

let default_config =
  { seed = 42; max_orders = 4096; mid = 1_000_000; tick = 100; levels = 8; max_lots = 10 }

(* Live ids are kept in a dense array so we can pick one uniformly in O(1)
   and remove it by swapping with the last element. *)
type t =
  { cfg : config
  ; rng : Random.State.t
  ; live_ids : int array  (** first [n_live] entries are live *)
  ; mutable n_live : int
  ; slot : int array  (** order_ref -> index in [live_ids], or -1 *)
  ; remaining : int array  (** order_ref -> shares left *)
  ; free : int array  (** stack of unused ids *)
  ; mutable n_free : int
  }

let create cfg =
  let n = cfg.max_orders in
  { cfg
  ; rng = Random.State.make [| cfg.seed |]
  ; live_ids = Array.make n 0
  ; n_live = 0
  ; slot = Array.make n (-1)
  ; remaining = Array.make n 0
  ; (* pop order 0, 1, 2, ... so early test output is easy to read *)
    free = Array.init n (fun i -> n - 1 - i)
  ; n_free = n
  }

let live t = t.n_live

let add_live t order_ref shares =
  t.live_ids.(t.n_live) <- order_ref;
  t.slot.(order_ref) <- t.n_live;
  t.n_live <- t.n_live + 1;
  t.remaining.(order_ref) <- shares

let remove_live t order_ref =
  let i = t.slot.(order_ref) in
  let last = t.live_ids.(t.n_live - 1) in
  t.live_ids.(i) <- last;
  t.slot.(last) <- i;
  t.n_live <- t.n_live - 1;
  t.slot.(order_ref) <- -1;
  t.remaining.(order_ref) <- 0;
  t.free.(t.n_free) <- order_ref;
  t.n_free <- t.n_free + 1

let gen_add t =
  t.n_free <- t.n_free - 1;
  let order_ref = t.free.(t.n_free) in
  let r = t.rng in
  let side : Msg.side = if Random.State.bool r then Buy else Sell in
  let k = 1 + Random.State.int r t.cfg.levels in
  let price =
    match side with
    | Buy -> t.cfg.mid - (k * t.cfg.tick)
    | Sell -> t.cfg.mid + (k * t.cfg.tick)
  in
  let shares = 100 * (1 + Random.State.int r t.cfg.max_lots) in
  add_live t order_ref shares;
  Msg.Add_order { order_ref; side; price; shares }

(* Order_executed or Order_cancel: take 1..remaining shares. Taking all of them
   removes the order, exactly as the model does. *)
let gen_reduce t ~executed =
  let order_ref = t.live_ids.(Random.State.int t.rng t.n_live) in
  let rem = t.remaining.(order_ref) in
  let shares = 1 + Random.State.int t.rng rem in
  if shares = rem then remove_live t order_ref else t.remaining.(order_ref) <- rem - shares;
  if executed then Msg.Order_executed { order_ref; shares } else Msg.Order_cancel { order_ref; shares }

let gen_delete t =
  let order_ref = t.live_ids.(Random.State.int t.rng t.n_live) in
  remove_live t order_ref;
  Msg.Order_delete { order_ref }

let next t =
  if t.n_live = 0 then gen_add t
  else
    (* Weights: add 45, execute 20, cancel 15, delete 20.
       With no free ids, adds are impossible so we roll among the rest. *)
    let can_add = t.n_free > 0 in
    let roll = Random.State.int t.rng (if can_add then 100 else 55) in
    let roll = if can_add then roll else roll + 45 in
    if roll < 45 then gen_add t
    else if roll < 65 then gen_reduce t ~executed:true
    else if roll < 80 then gen_reduce t ~executed:false
    else gen_delete t

let generate cfg n =
  let t = create cfg in
  let rec go i acc = if i = n then List.rev acc else go (i + 1) (next t :: acc) in
  go 0 []
