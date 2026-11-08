(* Learning example: accept start, count four enabled cycles, pulse done.
   This is deliberately small enough to trace on paper before the parser. *)
open Hardcaml
open Signal

module I = struct
  type 'a t = { clock : 'a; clear : 'a; start : 'a; enable : 'a }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { busy : 'a; done_ : 'a; count : 'a [@bits 3] }
  [@@deriving hardcaml]
end

module State = struct
  type t = Idle | Count | Done [@@deriving compare, enumerate, sexp_of]
end

let create (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let sm = State_machine.create (module State) spec in
  let count = Variable.reg spec ~width:3 in
  compile [ sm.switch
    [ Idle, [ when_ i.start [ count <--. 0; sm.set_next Count ] ]
    ; Count, [ when_ i.enable
        [ count <-- count.value +:. 1
        ; when_ (count.value ==:. 3) [ sm.set_next Done ] ] ]
    ; Done, [ sm.set_next Idle ] ] ];
  { O.busy = sm.is Count; done_ = sm.is Done; count = count.value }
