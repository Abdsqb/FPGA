(* Simulate the transmitter and decode its [tx] line with a software UART
   receiver, the way the PC's USB-serial chip would. *)

open! Hardcaml
module U = Uart.Uart_tx
module Sim = Cyclesim.With_interface (U.I) (U.O)

let setup ?cycles_per_bit () =
  let sim = Sim.create (U.create ?cycles_per_bit) in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  sim, i, o

let tx (o : Bits.t ref U.O.t) = Bits.to_int !(o.tx)
let ready (o : Bits.t ref U.O.t) = Bits.to_int !(o.ready)

(* Record the tx line, one sample per cycle, while sending [bytes]
   back to back (each starts as soon as [ready] is 1). *)
let send_bytes sim (i : Bits.t ref U.I.t) o bytes =
  let line = ref [] in
  let cycle () = Cyclesim.cycle sim; line := tx o :: !line in
  List.iter (fun b ->
    while ready o = 0 do cycle () done;
    i.data := Bits.of_int ~width:8 b;
    i.start := Bits.vdd;
    cycle ();
    i.start := Bits.gnd) bytes;
  while ready o = 0 do cycle () done;
  for _ = 1 to 3 do cycle () done;
  Array.of_list (List.rev !line)

(* Software receiver: find each falling edge (start bit), then sample the
   middle of each of the 10 bits. Returns the bytes and any framing errors. *)
let decode ~cycles_per_bit line =
  let n = Array.length line in
  let rec go t acc =
    if t >= n then List.rev acc
    else if line.(t) = 0 && (t = 0 || line.(t - 1) = 1) then begin
      let sample k = line.(t + (k * cycles_per_bit) + (cycles_per_bit / 2)) in
      let start_ok = sample 0 = 0 and stop_ok = sample 9 = 1 in
      let byte = List.fold_left (fun a k -> a lor (sample (k + 1) lsl k)) 0 (List.init 8 Fun.id) in
      go (t + (10 * cycles_per_bit)) ((byte, start_ok && stop_ok) :: acc)
    end
    else go (t + 1) acc
  in
  go 0 []

let show results =
  String.concat " "
    (List.map (fun (b, ok) -> Printf.sprintf "%02x%s" b (if ok then "" else "(framing error)")) results)

let%expect_test "bytes decode correctly (fast clock for the simulation: 4 cycles per bit)" =
  let sim, i, o = setup ~cycles_per_bit:4 () in
  let idle_high = tx o = 1 && ready o = 1 in
  let sent = [ 0x55; 0xA5; 0x00; 0xFF; 0x41; 0x80; 0x01 ] in
  let line = send_bytes sim i o sent in
  Printf.printf "idle line high, ready after reset: %b\n" idle_high;
  Printf.printf "decoded: %s\n" (show (decode ~cycles_per_bit:4 line));
  [%expect {|
    idle line high, ready after reset: true
    decoded: 55 a5 00 ff 41 80 01
    |}]

let%expect_test "real speed: 868 cycles per bit at 100 MHz = 115,207 baud" =
  let sim, i, o = setup () in
  let busy_cycles = ref 0 in
  i.data := Bits.of_int ~width:8 0x41;
  i.start := Bits.vdd;
  Cyclesim.cycle sim;
  i.start := Bits.gnd;
  let line = ref [ tx o ] in
  while ready o = 0 do
    incr busy_cycles;
    Cyclesim.cycle sim;
    line := tx o :: !line
  done;
  let line = Array.of_list (List.rev !line) in
  Printf.printf "one byte took %d cycles = %.1f us; decoded: %s\n" (!busy_cycles + 1)
    (float_of_int (!busy_cycles + 1) /. 100.) (show (decode ~cycles_per_bit:868 line));
  [%expect {| one byte took 8681 cycles = 86.8 us; decoded: 41 |}]

let%expect_test "start is ignored while busy; the byte in flight isn't corrupted" =
  let sim, i, o = setup ~cycles_per_bit:4 () in
  let line = ref [] in
  let cycle () = Cyclesim.cycle sim; line := tx o :: !line in
  i.data := Bits.of_int ~width:8 0x3C;
  i.start := Bits.vdd;
  cycle ();
  i.data := Bits.of_int ~width:8 0xFF;  (* try to start another byte mid-way *)
  for _ = 1 to 15 do cycle () done;
  i.start := Bits.gnd;
  while ready o = 0 do cycle () done;
  for _ = 1 to 3 do cycle () done;
  Printf.printf "decoded: %s\n" (show (decode ~cycles_per_bit:4 (Array.of_list (List.rev !line))));
  [%expect {| decoded: 3c |}]

let%expect_test "throughput: a 20-byte frame at real speed, as in Spec v1's sizing" =
  let sim, i, o = setup () in
  let frame = List.init 20 (fun k -> (k * 37) land 0xFF) in
  let line = send_bytes sim i o frame in
  let cycles = Array.length line - 3 in
  let decoded = decode ~cycles_per_bit:868 line in
  Printf.printf "20 bytes in %d cycles = %.3f ms -> %.0f frames/s; all decoded: %b\n" cycles
    (float_of_int cycles /. 100_000.)
    (100_000_000. /. float_of_int cycles)
    (List.map fst decoded = frame && List.for_all snd decoded);
  [%expect {| 20 bytes in 173620 cycles = 1.736 ms -> 576 frames/s; all decoded: true |}]

let%expect_test "waveform: one byte, 'A' = 0x41, 2 cycles per bit" =
  let sim = Sim.create (U.create ~cycles_per_bit:2) in
  let waves, sim = Hardcaml_waveterm.Waveform.create sim in
  let i = Cyclesim.inputs sim in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  i.data := Bits.of_int ~width:8 0x41;
  i.start := Bits.vdd;
  Cyclesim.cycle sim;
  i.start := Bits.gnd;
  for _ = 1 to 22 do Cyclesim.cycle sim done;
  Hardcaml_waveterm.Waveform.print ~display_width:90 ~display_height:16 ~wave_width:0 waves;
  [%expect {|
    ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────────────┐
    │clock             ││┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐│
    │                  ││ └┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└│
    │clear             ││──┐                                                                 │
    │                  ││  └─────────────────────────────────────────────                    │
    │                  ││──┬─────────────────────────────────────────────                    │
    │data              ││ .│41                                                               │
    │                  ││──┴─────────────────────────────────────────────                    │
    │start             ││  ┌─┐                                                               │
    │                  ││──┘ └───────────────────────────────────────────                    │
    │ready             ││────┐                                       ┌───                    │
    │                  ││    └───────────────────────────────────────┘                       │
    │tx                ││────┐   ┌───┐                   ┌───┐   ┌───────                    │
    │                  ││    └───┘   └───────────────────┘   └───┘                           │
    │                  ││                                                                    │
    └──────────────────┘└────────────────────────────────────────────────────────────────────┘
    |}]
