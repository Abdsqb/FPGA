(* The four ITCH 5.0 message types we support, with only the fields the
   order book needs. Wire-format details (timestamps, stock symbol, match
   numbers) live in [Itch], not here. *)

type side =
  | Buy
  | Sell

type t =
  | Add_order of
      { order_ref : int  (** order reference number, 0..4095 by team decision *)
      ; side : side
      ; price : int  (** integer ticks; ITCH Price(4) = 4 implied decimals *)
      ; shares : int
      }
  | Order_executed of
      { order_ref : int
      ; shares : int  (** shares executed *)
      }
  | Order_cancel of
      { order_ref : int
      ; shares : int  (** shares cancelled; a partial cancel *)
      }
  | Order_delete of { order_ref : int }

let side_to_string = function
  | Buy -> "B"
  | Sell -> "S"

let to_string = function
  | Add_order { order_ref; side; price; shares } ->
    Printf.sprintf "Add_order      order_ref=%d %s %d @ %d" order_ref (side_to_string side) shares price
  | Order_executed { order_ref; shares } -> Printf.sprintf "Order_executed order_ref=%d shares=%d" order_ref shares
  | Order_cancel { order_ref; shares } -> Printf.sprintf "Order_cancel   order_ref=%d shares=%d" order_ref shares
  | Order_delete { order_ref } -> Printf.sprintf "Order_delete   order_ref=%d" order_ref
