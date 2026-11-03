(* The four ITCH 5.0 message types we support, with only the fields the
   order book needs. Wire-format details (timestamps, stock symbol, match
   numbers) live in [Itch], not here. *)

type side =
  | Buy
  | Sell

type t =
  | Add of
      { id : int  (** order reference number, 0..4095 by team decision *)
      ; side : side
      ; price : int  (** integer ticks; ITCH Price(4) = 4 implied decimals *)
      ; qty : int
      }
  | Executed of
      { id : int
      ; qty : int  (** shares executed *)
      }
  | Cancel of
      { id : int
      ; qty : int  (** shares cancelled; a partial cancel *)
      }
  | Delete of { id : int }

let side_to_string = function
  | Buy -> "B"
  | Sell -> "S"

let to_string = function
  | Add { id; side; price; qty } ->
    Printf.sprintf "Add      id=%d %s %d @ %d" id (side_to_string side) qty price
  | Executed { id; qty } -> Printf.sprintf "Executed id=%d qty=%d" id qty
  | Cancel { id; qty } -> Printf.sprintf "Cancel   id=%d qty=%d" id qty
  | Delete { id } -> Printf.sprintf "Delete   id=%d" id
