(* ITCH parser, matching Spec v1.

   Input, Spec v1 "byte stream": the UDP payload (MoldUDP64 packets), one
   byte per cycle. in_data / in_valid / in_last (last byte of the payload).
   The in_ prefix only keeps these names apart from the output [valid].

   Output, Spec v1 "Parser -> order book":
     valid (one cycle per message), msg_type[1:0] (0 Add, 1 Executed,
     2 Cancel, 3 Delete), order_ref[63:0], side (0 buy, 1 sell; Add only),
     shares[31:0] (Add: size; Executed/Cancel: shares removed; Delete: 0),
     price[31:0] (Add only).

   Inside: Mold_deframer strips the packet header and message lengths and
   marks each message's first/last byte; the decoder below collects one
   message, checks it and pulses [valid]. Bad or other-stock messages are
   dropped silently: no valid pulse.

   [clear] is a synchronous reset (Spec v1 sets the base price "at reset").
   [stock_locate] is a build-time setting, not a port: only messages for this
   stock are passed on. It must match what the feed sends (our generator and
   encoder use 1). *)
open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; in_data : 'a [@bits 8]
    ; in_valid : 'a
    ; in_last : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { valid : 'a
    ; msg_type : 'a [@bits 2]
    ; order_ref : 'a [@bits 64]
    ; side : 'a
    ; shares : 'a [@bits 32]
    ; price : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module States = struct
  type t = Idle | Collect | Validate | Drain
  [@@deriving compare, enumerate, sexp_of]
end

(* One ITCH message at a time, framed by [first] / [last]. *)
let decode ~stock_locate ~clock ~clear ~valid ~data ~first ~last : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock ~clear () in
  let sm = State_machine.create (module States) spec in
  let count = Variable.reg spec ~width:6 in
  let bytes = Array.init 36 (fun _ -> Variable.reg spec ~width:8) in
  let field off len =
    concat_msb (List.init len (fun n -> bytes.(off + n).value))
  in
  let typ = field 0 1 in
  let is_a = typ ==:. 0x41 and is_e = typ ==:. 0x45 in
  let is_x = typ ==:. 0x58 and is_d = typ ==:. 0x44 in
  let supported = is_a |: is_e |: is_x |: is_d in
  let length_ok =
    (is_a &: (count.value ==:. 36))
    |: (is_e &: (count.value ==:. 31))
    |: (is_x &: (count.value ==:. 23))
    |: (is_d &: (count.value ==:. 19))
  in
  let locate_ok = field 1 2 ==:. stock_locate in
  let side_ok = ~:is_a |: (field 19 1 ==:. 0x42) |: (field 19 1 ==:. 0x53) in
  let good = supported &: length_ok &: locate_ok &: side_ok in
  let drain = if_ last [ sm.set_next Idle ] [ sm.set_next Drain ] in
  (* Used in Idle and in Validate: the byte registers only change at the end
     of the cycle, so the message being reported stays intact while the next
     one begins. *)
  let start_or_drain =
    when_ valid
      [ if_ first
          [ bytes.(0) <-- data
          ; count <--. 1
          ; if_ last [ sm.set_next Validate ] [ sm.set_next Collect ]
          ]
          [ drain ]
      ]
  in
  compile
    [ sm.switch
        [ Idle, [ start_or_drain ]
        ; ( Collect
          , [ when_ valid
                [ if_ first [ drain ]
                    [ if_ (count.value ==:. 36) [ drain ] (* longer than any message we handle *)
                        [ proc
                            (List.init 36 (fun n ->
                               when_ (count.value ==:. n) [ bytes.(n) <-- data ]))
                        ; count <-- count.value +:. 1
                        ; when_ last [ sm.set_next Validate ]
                        ]
                    ]
                ]
            ] )
        ; Validate, [ sm.set_next Idle; start_or_drain ]
        ; Drain, [ when_ (valid &: last) [ sm.set_next Idle ] ]
        ]
    ];
  { O.valid = sm.is Validate &: good &: ~:clear
  ; msg_type = mux2 is_a (of_int ~width:2 0)
      (mux2 is_e (of_int ~width:2 1) (mux2 is_x (of_int ~width:2 2) (of_int ~width:2 3)))
  ; order_ref = field 11 8
  ; side = is_a &: (field 19 1 ==:. 0x53)
  ; shares = mux2 is_a (field 20 4) (mux2 (is_e |: is_x) (field 19 4) (zero 32))
  ; price = mux2 is_a (field 32 4) (zero 32)
  }

let create ?(stock_locate = 1) (i : _ I.t) : _ O.t =
  let m =
    Mold_deframer.create ~clock:i.clock ~clear:i.clear ~in_data:i.in_data
      ~in_valid:i.in_valid ~in_last:i.in_last
  in
  (* [abort]: the packet ended mid-message, so reset the decoder and drop it. *)
  decode ~stock_locate ~clock:i.clock ~clear:(i.clear |: m.abort) ~valid:m.valid
    ~data:m.data ~first:m.first ~last:m.last
