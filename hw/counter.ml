(* Week-1 homework: an 8-bit counter in Hardcaml.

   This is a CIRCUIT description, not a program that runs step by step.
   [create] runs once, when we build the circuit, and returns wires.
   After that, the hardware does the same thing on every clock edge:
   if [enable] is high, count <- count + 1.
   [clear] is a synchronous reset back to 0. *)

open! Hardcaml
open Signal

(* The circuit's ports. [@@deriving hardcaml] generates the boilerplate
   that lets the simulator and Verilog generator find each port by name. *)
module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; enable : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { count : 'a [@bits 8] } [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  (* A Reg_spec says which clock and clear a register uses. *)
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  (* reg_fb = a register whose next value is a function of its own output
     (fb = feedback). [+:.] adds an OCaml int constant to a signal. *)
  let count = reg_fb spec ~enable:i.enable ~width:8 ~f:(fun d -> d +:. 1) in
  { O.count }
