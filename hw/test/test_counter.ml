(* Simulate the counter cycle by cycle. This is the same pattern the real
   testbench will use: set inputs, Cyclesim.cycle, read outputs. *)

open! Hardcaml
module Sim = Cyclesim.With_interface (Hw.Counter.I) (Hw.Counter.O)

let%expect_test "counter counts only while enabled, wraps at 256" =
  let sim = Sim.create Hw.Counter.create in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  let step ~enable =
    i.enable := if enable then Bits.vdd else Bits.gnd;
    Cyclesim.cycle sim;
    Bits.to_int !(o.count)
  in
  let counts = List.map (fun enable -> step ~enable) [ true; true; true; false; false; true ] in
  print_endline (String.concat " " (List.map string_of_int counts));
  (* run to the 8-bit limit *)
  let last = ref 0 in
  for _ = 1 to 252 do last := step ~enable:true done;
  Printf.printf "after 256 enabled cycles: %d\n" !last;
  [%expect {|
    1 2 3 3 3 4
    after 256 enabled cycles: 0
    |}]

let%expect_test "waveform" =
  (* Hardcaml_waveterm draws signals as ASCII art, like a logic analyzer. *)
  let sim = Sim.create Hw.Counter.create in
  let waves, sim = Hardcaml_waveterm.Waveform.create sim in
  let i = Cyclesim.inputs sim in
  i.enable := Bits.vdd;
  for _ = 1 to 4 do Cyclesim.cycle sim done;
  i.enable := Bits.gnd;
  for _ = 1 to 2 do Cyclesim.cycle sim done;
  Hardcaml_waveterm.Waveform.print ~display_width:60 ~display_height:12 waves;
  [%expect {|
    ┌Signals──────┐┌Waves──────────────────────────────────────┐
    │clock        ││┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌──│
    │             ││    └───┘   └───┘   └───┘   └───┘   └───┘  │
    │clear        ││                                           │
    │             ││───────────────────────────────────────────│
    │enable       ││────────────────────────────────┐          │
    │             ││                                └──────────│
    │             ││────────┬───────┬───────┬───────┬──────────│
    │count        ││ 00     │01     │02     │03     │04        │
    │             ││────────┴───────┴───────┴───────┴──────────│
    │             ││                                           │
    └─────────────┘└───────────────────────────────────────────┘
    |}]
