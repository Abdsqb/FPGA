(* One framed ITCH message at a time; see docs/parser-interface.md.
   The MoldUDP64 adapter is a separate, not-yet-implemented module.

   Outputs follow Spec v1, "Parser -> order book":
     valid (one cycle per message), msg_type[1:0] (0 Add, 1 Executed,
     2 Cancel, 3 Delete), order_ref[63:0], side (0 buy, 1 sell; Add only),
     shares[31:0], price[31:0] (Add only).
   timestamp_ns, error and filtered are extra debug outputs.

   There is no backpressure, as in the spec: the parser accepts a byte on
   every cycle, including the cycle in which it reports the previous
   message, so back-to-back messages never stall. *)
open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; in_valid : 'a
    ; in_data : 'a [@bits 8]
    ; in_first : 'a
    ; in_last : 'a
    ; stock_locate : 'a [@bits 16]
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
    ; timestamp_ns : 'a [@bits 48]
    ; error : 'a [@bits 3]
    ; filtered : 'a
    }
  [@@deriving hardcaml]
end

module States = struct
  type t = Idle | Collect | Validate | Drain
  [@@deriving compare, enumerate, sexp_of]
end

let create (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let sm = State_machine.create (module States) spec in
  let count = Variable.reg spec ~width:6 in
  let bytes = Array.init 36 (fun _ -> Variable.reg spec ~width:8) in
  let selected_locate = Variable.reg spec ~width:16 in
  let error = Variable.reg spec ~width:3 in
  let filtered = Variable.reg spec ~width:1 in
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
  let locate_ok = field 1 2 ==: selected_locate.value in
  let side_ok = ~:is_a |: (field 19 1 ==:. 0x42) |: (field 19 1 ==:. 0x53) in
  let good = supported &: length_ok &: locate_ok &: side_ok in
  let fire = i.in_valid &: ~:(i.clear) in
  let drain code =
    [ error <--. code; if_ i.in_last [ sm.set_next Idle ] [ sm.set_next Drain ] ]
  in
  (* Accept the first byte of a new message, or drain a stray byte. Used in
     Idle, and in Validate so the next message can start with no gap: the
     byte registers only change at the end of this cycle, so the message
     being reported is still intact while the new one begins. *)
  let start_or_drain =
    when_ fire
      [ if_ i.in_first
          [ bytes.(0) <-- i.in_data
          ; count <--. 1
          ; selected_locate <-- i.stock_locate
          ; if_ i.in_last [ sm.set_next Validate ] [ sm.set_next Collect ]
          ]
          (drain 1)
      ]
  in
  compile
    [ error <--. 0
    ; filtered <--. 0
    ; sm.switch
        [ Idle, [ start_or_drain ]
        ; Collect,
          [ when_ fire
              [ if_ i.in_first (drain 1)
                  [ if_ (count.value ==:. 36) (drain 2)
                      [ proc
                          (List.init 36 (fun n ->
                             when_ (count.value ==:. n) [ bytes.(n) <-- i.in_data ]))
                      ; count <-- count.value +:. 1
                      ; when_ i.in_last [ sm.set_next Validate ]
                      ]
                  ]
              ]
          ]
        ; Validate,
          [ if_ ~:supported [ error <--. 3 ]
              [ if_ ~:length_ok [ error <--. 2 ]
                  [ if_ ~:locate_ok [ filtered <--. 1 ]
                      [ when_ ~:side_ok [ error <--. 4 ] ]
                  ]
              ]
          ; sm.set_next Idle
          ; start_or_drain
          ]
        ; Drain, [ when_ (fire &: i.in_last) [ sm.set_next Idle ] ]
        ]
    ];
  { O.valid = sm.is Validate &: good &: ~:(i.clear)
  ; msg_type = mux2 is_a (of_int ~width:2 0)
      (mux2 is_e (of_int ~width:2 1) (mux2 is_x (of_int ~width:2 2) (of_int ~width:2 3)))
  ; order_ref = field 11 8
  ; side = is_a &: (field 19 1 ==:. 0x53)
  ; shares = mux2 is_a (field 20 4) (mux2 (is_e |: is_x) (field 19 4) (zero 32))
  ; price = mux2 is_a (field 32 4) (zero 32)
  ; timestamp_ns = field 5 6
  ; error = error.value
  ; filtered = filtered.value
  }
