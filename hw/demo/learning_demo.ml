open Hardcaml

let counter () =
  let module Sim = Cyclesim.With_interface (Hw.Counter.I) (Hw.Counter.O) in
  let sim = Sim.create Hw.Counter.create in
  let waves, sim = Hardcaml_waveterm.Waveform.create sim in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  print_endline "COUNTER: enable -> count after rising edge";
  List.iter (fun enable ->
    i.enable := if enable then Bits.vdd else Bits.gnd;
    Cyclesim.cycle sim;
    Printf.printf "%d -> %d\n" (if enable then 1 else 0) (Bits.to_int !(o.count)))
    [true; true; true; false; false; true];
  i.enable := Bits.gnd;
  Cyclesim.cycle sim;
  Hardcaml_waveterm.Waveform.print ~display_width:90 ~display_height:14 waves

let always () =
  let module Sim = Cyclesim.With_interface (Hw.Always_example.I) (Hw.Always_example.O) in
  let sim = Sim.create Hw.Always_example.create in
  let waves, sim = Hardcaml_waveterm.Waveform.create sim in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  print_endline "ALWAYS: start enable -> busy done count after rising edge";
  List.iter (fun (start, enable) ->
    i.start := Bits.of_int ~width:1 start;
    i.enable := Bits.of_int ~width:1 enable;
    Cyclesim.cycle sim;
    Printf.printf "%d %d -> %d %d %d\n" start enable
      (Bits.to_int !(o.busy)) (Bits.to_int !(o.done_)) (Bits.to_int !(o.count)))
    [1,0; 0,1; 0,0; 0,1; 0,1; 0,1; 0,0; 0,0];
  Hardcaml_waveterm.Waveform.print ~display_width:100 ~display_height:20 waves

let () = counter (); always ()
