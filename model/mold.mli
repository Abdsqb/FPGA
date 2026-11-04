(** MoldUDP64: how Nasdaq sends ITCH messages over UDP.

    Each UDP packet is a 20-byte header followed by a "message block":
    {v
      Header (20 bytes, big-endian)
       0  Session          10   ASCII, space-padded (e.g. "FH00000001")
      10  Sequence Number   8   sequence number of the FIRST message in this packet
      18  Message Count     2   messages in this packet
                                  0      = heartbeat (no messages)
                                  0xFFFF = end of session
      Message block, repeated Message Count times
       0  Message Length    2
       2  Message Data      N   one ITCH message (e.g. 36-byte Add Order)
    v}

    Sequence numbers count messages, not packets: if packet 1 carries
    messages 1..40, packet 2 starts at 41. A receiver that sees a gap knows
    it dropped a packet.

    The hardware parser's job per packet: skip 20 bytes, then repeatedly
    read a 2-byte length and that many bytes of ITCH. *)

val header_len : int  (** 20 *)

(** Largest UDP payload in one standard 1500-byte Ethernet frame:
    1500 - 20 (IP header) - 8 (UDP header) = 1472. *)
val max_udp_payload : int

type packet =
  { session : string  (** exactly 10 characters *)
  ; seq : int  (** sequence number of the first message *)
  ; count : int  (** number of messages, 0 for a heartbeat *)
  ; messages : bytes list  (** ITCH messages, without length prefixes *)
  }

val default_session : string

(** Build one packet. Raises if [session] isn't 10 characters, there are
    more than 65534 messages, or a message is longer than 65535 bytes. *)
val encode : ?session:string -> seq:int -> bytes list -> bytes

(** A heartbeat: header only, count 0. [seq] is the NEXT expected sequence number. *)
val heartbeat : ?session:string -> seq:int -> unit -> bytes

(** End of session: header only, count 0xFFFF. *)
val end_of_session : ?session:string -> seq:int -> unit -> bytes

val decode : bytes -> (packet, string) result

(** Split a stream of ITCH messages into packets, each at most
    [max_payload] bytes (default [max_udp_payload]), with consecutive
    sequence numbers starting at [first_seq] (default 1). *)
val packetize :
  ?session:string -> ?first_seq:int -> ?max_payload:int -> bytes list -> bytes list
