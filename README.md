# Hardcaml Feed Handler

A market-data feed handler on a real FPGA (Arty A7-100T). It receives a
subset of Nasdaq ITCH 5.0 over Ethernet/UDP, parses it in hardware, keeps
the order table in block RAM, and outputs best bid / best ask with latency
measured in clock cycles.

## Who owns what

| Part | Owner |
|---|---|
| Board bring-up, Ethernet receive, clocks/constraints, Vivado, UART | Enes (EE) |
| Hardware core in Hardcaml: parser, order table, top of book | CompE teammate |
| Reference model, feed generator, testbench, CI, repo | Abdullah Saqib (CS) |
| CPU baseline in C, replay tools, latency comparison | TBD (CS if no 4th person) |

## Layout

```
model/          pure OCaml, no hardware
  msg.ml          the 4 message types (Add, Executed, Cancel, Delete)
  order_book.ml   REFERENCE MODEL: the answer key for the hardware
  itch.ml         ITCH 5.0 byte layouts: encode / decode / framing
  feed_gen.ml     random generator of valid message streams
test/           expect tests + randomized tests for model/
hw/             Hardcaml designs (counter now; parser + book later)
hw/test/        hardware simulations
bin/gen_feed.ml writes a feed file used by every stage
```

## Setup (macOS / Linux / WSL)

```sh
# macOS: brew install opam   |   Ubuntu/WSL: sudo apt install opam
opam init -y
opam switch create fh 5.2.1
eval $(opam env --switch=fh)
opam install . --deps-only --with-test -y
dune build
dune test            # silent = all tests passed
```

## Everyday commands

```sh
dune test                                          # run all tests
dune promote                                       # accept new expect output (read the diff first!)
dune exec bin/gen_feed.exe -- -n 20 -print         # see a feed + top of book
dune exec bin/gen_feed.exe -- -n 100000 -o feed.bin
```

## Workflow

1. `git checkout -b my-change`
2. Commit, push, open a pull request.
3. CI must be green and one teammate must approve before merging.

## Decisions this code assumes (confirm in the spec)

- Prices: integer ticks, ITCH 4 implied decimals (1_000_000 = $100.0000), 32 bits.
- Quantity: 32 bits. Up to 4,096 live orders; order ids 0–4095.
- Best bid/ask report total shares at the price level.
- Executed/Cancel that brings an order to 0 removes it.
- One symbol (`TEST`). The book never crosses (no matching).
