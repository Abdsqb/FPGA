# board/: board bring-up (Enes, EE)

Everything needed to get the design running on the physical
**Digilent Arty A7-100T** and talking to the network.

The parser and order book live in `hw/` (CompE). This folder is the layer
around them: getting bytes in from the Ethernet cable, getting results out
over UART, and turning the whole design into a bitstream with Vivado.

## What goes here

| Piece | What it does |
|---|---|
| Ethernet receive | Reads frames from the board's Ethernet PHY over MII (100 Mbit/s, 25 MHz receive clock), strips the Ethernet / IP / UDP headers, keeps only our feed's UDP packets, and hands the payload bytes to the parser |
| Clock crossing | Ethernet receive runs on its own 25 MHz clock; the core runs at the board's 100 MHz. An async FIFO moves bytes safely between the two |
| UART output | Sends best bid / best ask (and the latency in cycles) to the PC over the USB cable |
| Top level | Wires Ethernet receive, the core from `hw/` and UART output together |
| Constraints (`.xdc`) | Which FPGA pin is which (clock, Ethernet PHY, UART, LEDs) and the clock timing rules |
| Vivado scripts | Synthesis, place and route, timing reports, bitstream |

## Suggested layout

```
board/
  README.md          this file
  constraints/       arty_a7_100t.xdc
  vivado/            build.tcl (synth, place and route, bitstream)
  rtl/               Hardcaml for Ethernet receive, UART, top level
  test/              simulations of the above (e.g. a recorded frame in, payload out)
```

Hardcaml code in `rtl/` gets its own `dune` file, like `hw/`. Vivado
output (`.Xil/`, `*.jou`, `*.log`, `vivado_project/`) is already in
`.gitignore`. Don't commit it.

## Decisions this assumes (from the kickoff)

- Core clock: the board's 100 MHz. Ethernet receive: 25 MHz (MII), with an async FIFO between them.
- Output: UART to the PC first; sending results back over Ethernet is a stretch goal.
- Vivado ML Standard (free), Artix-7 device family only. It runs on Windows or Linux, not macOS.

## Milestones

- [ ] Vivado installed; blinking-LED design running on the board
- [ ] Constraint file with clock, LEDs, UART, Ethernet PHY pins
- [ ] UART "hello" from the board to the PC
- [ ] Ethernet receive in simulation: recorded frame in, UDP payload out
- [ ] Ethernet receive on the board: UDP packets from a laptop seen on the LEDs / UART
- [ ] Core from `hw/` wired in; best bid / ask over UART
- [ ] Timing closed at 100 MHz
