(* MoldUDP64 deframer: turns one UDP payload into a stream of ITCH messages.

   Input (Spec v1 byte stream): the UDP payload, one byte per cycle;
   [in_last] marks the last byte of the payload.
   Output: the same bytes minus the 20-byte packet header and each 2-byte
   message length, with [first] / [last] marking each ITCH message.

   Packet layout (see model/mold.mli):
     20-byte header (session 10, sequence number 8, message count 2),
     then repeated [2-byte length][ITCH message].
   A 20-byte packet (heartbeat or end of session) carries no messages.

   Cut-through: every byte is passed on in the same cycle it arrives; nothing
   is buffered, so the deframer adds no latency.

   NOTE (accuracy, revisit later): because messages are passed on before the
   end of the packet has arrived, a packet that turns out bad at its end
   (truncated, or flagged by rxerr / FIFO overflow once those exist) may
   already have updated the book with its earlier messages. Only the message
   cut off by the bad end is dropped ([abort]). If that matters, switch to
   store-and-forward: buffer the whole packet, check it, then replay it. That
   costs up to 1,472 bytes x 8 cycles = 11,776 cycles (~118 us) per full
   packet. Also not checked yet: the header's sequence number (a lost packet
   goes unnoticed) and its message count. *)
open! Hardcaml
open Signal

module States = struct
  type t = Header | Len_hi | Len_lo | Body
  [@@deriving compare, enumerate, sexp_of]
end

type t =
  { data : Signal.t
  ; valid : Signal.t  (** a message byte is on [data] this cycle *)
  ; first : Signal.t  (** ... and it is the message's first byte *)
  ; last : Signal.t  (** ... and it is the message's last byte *)
  ; abort : Signal.t
        (** the packet ended in the middle of a message: drop that message *)
  }

let create ~clock ~clear ~in_data ~in_valid ~in_last =
  let open Always in
  let spec = Reg_spec.create ~clock ~clear () in
  let sm = State_machine.create (module States) spec in
  let header_count = Variable.reg spec ~width:5 in
  let len_hi = Variable.reg spec ~width:8 in
  (* Body bytes still to come, counting the current one. *)
  let remaining = Variable.reg spec ~width:16 in
  let at_first = Variable.reg spec ~width:1 in
  let abort = Variable.wire ~default:gnd in
  let len = len_hi.value @: in_data in
  compile
    [ sm.switch
        [ ( Header
          , [ when_ in_valid
                [ if_ in_last
                    (* End of a header-only packet (heartbeat / end of session),
                       or a malformed short one: wait for the next packet. *)
                    [ header_count <--. 0 ]
                    [ if_ (header_count.value ==:. 19)
                        [ header_count <--. 0; sm.set_next Len_hi ]
                        [ header_count <-- header_count.value +:. 1 ]
                    ]
                ]
            ] )
        ; ( Len_hi
          , [ when_ in_valid
                [ len_hi <-- in_data
                ; if_ in_last [ sm.set_next Header ] [ sm.set_next Len_lo ]
                ]
            ] )
        ; ( Len_lo
          , [ when_ in_valid
                [ if_ in_last [ sm.set_next Header ]
                    [ if_ (len ==:. 0)
                        [ sm.set_next Len_hi ] (* empty block: nothing to pass on *)
                        [ remaining <-- len; at_first <--. 1; sm.set_next Body ]
                    ]
                ]
            ] )
        ; ( Body
          , [ when_ in_valid
                [ remaining <-- remaining.value -:. 1
                ; at_first <--. 0
                ; if_ (remaining.value ==:. 1)
                    [ if_ in_last [ sm.set_next Header ] [ sm.set_next Len_hi ] ]
                    [ when_ in_last [ abort <-- vdd; sm.set_next Header ] ]
                ]
            ] )
        ]
    ];
  { data = in_data
  ; valid = in_valid &: sm.is Body
  ; first = at_first.value
  ; last = remaining.value ==:. 1
  ; abort = abort.value
  }
