open Hardcaml
module P = Hw.Itch_parser
module Sim = Cyclesim.With_interface (P.I) (P.O)

let () =
  if Array.length Sys.argv > 1 && Sys.argv.(1) = "--verilog" then
    let module C = Circuit.With_interface (P.I) (P.O) in
    Rtl.print Verilog (C.create_exn ~name:"itch_parser" P.create)
  else (
    let sim = Sim.create P.create in
    let waves, sim = Hardcaml_waveterm.Waveform.create sim in
    let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
    let value r = Bits.to_int !r in
    let bit b = if b then Bits.vdd else Bits.gnd in
    i.clear := Bits.vdd;
    Cyclesim.cycle sim;
    i.clear := Bits.gnd;
    Cyclesim.cycle sim;
    let msg = Model.Msg.Add_order
        { order_ref = 42; side = Buy; shares = 100; price = 1_502_500 } in
    let itch = Model.Itch.encode
        ~header:{ stock_locate = 1; tracking = 0; timestamp_ns = 34_200_000_000_000 } msg in
    Bytes.blit_string "AAPL    " 0 itch 24 8;
    let packet = Model.Mold.encode ~seq:1 [ itch ] in
    Printf.printf "36-byte Add Order:     %s\n" (Model.Itch.to_hex itch);
    Printf.printf "58-byte MoldUDP64 packet = 20-byte header + 2-byte length (00 24) + the message\n";
    let pulses = ref 0 in
    let step () =
      Cyclesim.cycle sim;
      if value o.valid = 1 then begin
        incr pulses;
        Printf.printf "Decoded: msg_type=%d order_ref=%d side=%d shares=%d price=%d\n"
          (value o.msg_type) (value o.order_ref) (value o.side) (value o.shares) (value o.price)
      end
    in
    Bytes.iteri (fun n c ->
      i.in_valid := Bits.vdd;
      i.in_data := Bits.of_int ~width:8 (Char.code c);
      i.in_last := bit (n = Bytes.length packet - 1);
      step ()) packet;
    i.in_valid := Bits.gnd;
    i.in_last := Bits.gnd;
    for _ = 1 to 4 do step () done;
    Printf.printf "valid pulsed %d time(s), for one cycle, as in Spec v1.\n" !pulses;
    Hardcaml_waveterm.Waveform.print
      ~wave_width:0 ~display_width:140 ~display_height:40 waves)
