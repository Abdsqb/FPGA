open Hardcaml
module Sim = Cyclesim.With_interface (Hw.Always_example.I) (Hw.Always_example.O)

let%expect_test "Always FSM counts enabled cycles, pulses done, restarts and resets" =
  let sim = Sim.create Hw.Always_example.create in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  let bit b = if b then Bits.vdd else Bits.gnd in
  let snapshot () = Bits.to_int !(o.busy), Bits.to_int !(o.done_), Bits.to_int !(o.count) in
  let step ?(clear=false) ?(start=false) ?(enable=false) () =
    i.clear := bit clear; i.start := bit start; i.enable := bit enable;
    Cyclesim.cycle sim; snapshot ()
  in
  assert (step ~clear:true () = (0, 0, 0));
  (* Put data in the list, then execute steps in order: OCaml does not
     guarantee left-to-right evaluation of expressions in a list literal. *)
  let states = List.map (fun (start, enable) -> step ~start ~enable ())
      [ true,false; false,true; false,false; true,true;
        false,true; false,true; false,false ] in
  List.iter (fun (busy, done_, count) -> Printf.printf "%d %d %d\n" busy done_ count) states;
  assert (step ~start:true () = (1, 0, 0));
  assert (step ~enable:true () = (1, 0, 1));
  assert (step ~clear:true ~enable:true ~start:true () = (0, 0, 0));
  [%expect {|
    1 0 0
    1 0 1
    1 0 1
    1 0 2
    1 0 3
    0 1 4
    0 0 4
    |}]
