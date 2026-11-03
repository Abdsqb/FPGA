(** Encode / decode our subset of Nasdaq ITCH 5.0.

    All integers are big-endian. Field layouts (offset: field, bytes):

    Add Order ['A'], 36 bytes
    {v
      0  type 'A'            1
      1  stock locate        2
      3  tracking number     2
      5  timestamp (ns)      6
     11  order reference     8
     19  buy/sell 'B'/'S'    1
     20  shares              4
     24  stock (ASCII, pad)  8
     32  price (4 dp)        4
    v}
    Order Executed ['E'], 31 bytes: 0 type, 1 locate, 3 tracking,
    5 timestamp, 11 order ref (8), 19 executed shares (4), 23 match number (8).

    Order Cancel ['X'], 23 bytes: 0 type, 1 locate, 3 tracking, 5 timestamp,
    11 order ref (8), 19 cancelled shares (4).

    Order Delete ['D'], 19 bytes: 0 type, 1 locate, 3 tracking, 5 timestamp,
    11 order ref (8).

    Checked against the Nasdaq TotalView-ITCH 5.0 spec (Nov 2026):
    offsets, lengths, big-endian unsigned integers, Price(4) = 4 implied
    decimal places. The hardware parser must agree with this file byte for
    byte. *)

(** Fields a message carries that the order book ignores. *)
type header =
  { stock_locate : int
  ; tracking : int
  ; timestamp_ns : int
  }

val default_header : header

(** The 8-byte space-padded stock symbol we put in Add Order messages. *)
val stock : string

val length_of_type : char -> int option

(** [match_number] is only used by Order Executed. *)
val encode : ?header:header -> ?match_number:int -> Msg.t -> bytes

val decode : bytes -> (Msg.t, string) result

(** Feed files and UDP payloads frame each message with a 2-byte big-endian
    length, as in Nasdaq's binary ITCH files and MoldUDP64 blocks. *)
val frame : bytes -> bytes

(** Split a buffer of length-prefixed messages. *)
val unframe_all : bytes -> (bytes list, string) result

(** Lowercase hex with a space every byte, for expect tests. *)
val to_hex : bytes -> string
