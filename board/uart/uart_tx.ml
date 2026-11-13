(* UART transmitter: sends one byte at a time on the board's USB-serial line.

   Spec v1 "Output": 115,200 baud, readable on the PC with tio. Each byte
   costs 10 bits on the wire: a start bit (0), 8 data bits (least
   significant first), a stop bit (1). The line idles at 1.

   At the 100 MHz core clock, one bit lasts 100,000,000 / 115,200 = 868.06
   cycles; we use 868 (115,207 baud, 0.006% fast, far inside what a UART
   tolerates). One byte = 8,680 cycles = 86.8 us.

   Handshake: when [ready] is 1, put a byte on [data] and raise [start] for
   one cycle. [ready] stays 0 until the stop bit has finished. A [start]
   while [ready] is 0 is ignored.

   TODO (waits on Enes / Spec v1): the 20-byte best bid/ask frame that sits
   on top of this. Spec v1 lists its fields (sync byte, sequence number, bid
   price and size, ask price and size, latency) but not their byte layout,
   and they don't fit as written: 1 + 4x4 + 2 = 19 bytes leaves 1 byte for
   the sequence number and no room for bid_valid / ask_valid. *)
open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; data : 'a [@bits 8]
    ; start : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { tx : 'a  (** the serial line *)
    ; ready : 'a  (** 1 = idle, a new byte can start *)
    }
  [@@deriving hardcaml]
end

let default_cycles_per_bit = 868

let create ?(cycles_per_bit = default_cycles_per_bit) (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let busy = Variable.reg spec ~width:1 in
  (* The 10 bits still to send; bit 0 is on the line now. *)
  let shift = Variable.reg spec ~width:10 in
  let bits_left = Variable.reg spec ~width:4 in
  let count = Variable.reg spec ~width:(Int.max 1 (num_bits_to_represent cycles_per_bit)) in
  compile
    [ if_ busy.value
        [ if_ (count.value ==:. cycles_per_bit - 1)
            [ (* end of this bit: move to the next *)
              count <--. 0
            ; shift <-- (vdd @: msbs shift.value)
            ; bits_left <-- bits_left.value -:. 1
            ; when_ (bits_left.value ==:. 1) [ busy <--. 0 ]
            ]
            [ count <-- count.value +:. 1 ]
        ]
        [ when_ i.start
            [ shift <-- (vdd @: i.data @: gnd)  (* stop bit, data, start bit *)
            ; bits_left <--. 10
            ; count <--. 0
            ; busy <--. 1
            ]
        ]
    ];
  { O.tx = mux2 busy.value (lsb shift.value) vdd; ready = ~:(busy.value) }
