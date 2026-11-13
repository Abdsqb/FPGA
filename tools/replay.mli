(** PC replay tool: send MoldUDP64 packets over UDP at a chosen rate.

    Enes uses it to test the board's receive path; later the CPU baseline
    reads the same packets. Packets come from a file written by
    [gen_feed -mold] or are generated on the fly. *)

(** Read a file written by [gen_feed -mold]: each MoldUDP64 packet with a
    2-byte big-endian length in front. *)
val read_mold_file : string -> (bytes list, string) result

(** Generate [n] messages with [seed] and pack them into MoldUDP64 packets
    with consecutive sequence numbers from 1. [msgs_per_packet = 0] (the
    default) fills packets up to 1,472 bytes; [1] sends one message per
    packet, which keeps the board's buffering wait small for latency tests. *)
val generate : ?msgs_per_packet:int -> seed:int -> n:int -> unit -> bytes list

type stats =
  { packets : int
  ; bytes : int  (** UDP payload bytes sent *)
  ; seconds : float  (** wall-clock time taken *)
  }

(** Send each packet as one UDP datagram to [addr]:[port].
    [rate] = packets per second ([0.] or less = as fast as possible). Sends
    are scheduled against the start time, so a slow send doesn't make the
    whole run drift. Broadcast is enabled, so [addr] can be a broadcast
    address such as 192.168.1.255 or 255.255.255.255. *)
val send : ?rate:float -> addr:string -> port:int -> bytes list -> stats
