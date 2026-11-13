# Hardcaml Feed Handler

A market-data feed handler on a real FPGA (Arty A7-100T). It receives a
subset of Nasdaq ITCH 5.0 over Ethernet/UDP, parses it in hardware, keeps
the order table in block RAM, and outputs best bid / best ask with latency
measured in clock cycles.

## November 8 CompE deliverables

The [Amirlan checklist](docs/nov8-checklist.md) links the worked Hardcaml
examples, printable parser state-machine sketch, implemented ITCH decoder,
interface contract and tests. The parser takes MoldUDP64 packets
(cut-through deframing built in) and outputs Spec v1's parser signals; the
hardware order book remains future work.

```sh
opam exec --switch=fh -- dune exec hw/demo/learning_demo.exe
opam exec --switch=fh -- dune exec hw/demo/parser_demo.exe
```

## How the repo is divided

Each person owns one part from start to finish and works mostly in their
own folders, so people rarely edit the same files. Everyone still reviews
everyone else's pull requests, because an interviewer will ask about the
whole design.

### Abdullah Saqib (CS): checking that everything is correct, and the repo itself

| Folder / file | What's in it | Status |
|---|---|---|
| `model/` | Reference model (the answer key), message types, ITCH 5.0 format, random feed generator | Done |
| `model/price_bitmap.ml` | Prototype of Spec v1's next-best-price bitmap (two-level, 64 × 64), separate from the reference model | Week 2: checked against a scan and the model; base price still open |
| `test/` | Tests for everything in `model/` | Done |
| `bin/` | `gen_feed`: writes the feed files every stage uses | Done |
| `hw/test/` | Parser/model regression and hardware learning examples; full hardware-book comparison planned | Parser tests available; book comparison next |
| `tools/` | `replay`: sends MoldUDP64 packets over UDP at a chosen rate, for testing the board | Week 2: done; default port/address to confirm with Enes |
| `board/uart/` | UART transmitter (115,200 baud), moved from EE in week 2 | Week 2: byte sender done; 20-byte frame waits on the frame layout |
| `.github/workflows/` | CI: builds and tests every push and pull request | Done |
| `README.md`, `dune-project`, `feed_handler.opam.locked` | Setup guide, project settings, pinned library versions | Done |

Also: reviews every pull request, runs the repo.

### Amirlan (CompE): the chip's logic, in Hardcaml

| Folder | What goes in it | Status |
|---|---|---|
| `hw/` | ITCH parser with MoldUDP64 deframer (matches Spec v1) and learning examples; BRAM order table and top-of-book logic planned | Parser implemented and simulated; book next |

Also: leads the digital-logic crash course.

### Enes (EE): the physical board and the network

| Folder | What goes in it | Status |
|---|---|---|
| `board/` | Ethernet receive (PHY, MII, UDP filter), clocks, pin and timing constraints (XDC), Vivado build scripts (UART moved to CS in `board/uart/`) | Setting up; see [`board/README.md`](board/README.md) |

Also: project lead, buys the parts, records the demo video.

### CPU baseline (4th person, or CS if nobody joins)

| Folder | What goes in it | Status |
|---|---|---|
| `baseline/` *(planned)* | C program on Linux that reads the same feed from UDP sockets, for the speed comparison | Later |
| `tools/` | Replay tool done (CS, week 2); script that reads the board's UART output still planned | Partly |

Also: latency measurement, comparison chart, write-up.

### How the parts connect

The same feed file drives every part, so every stage is tested on identical data.

```
bin/gen_feed ──> feed.bin ─┬─> hw/       chip simulation ─────┐
   (CS)                    │   (CompE)                        ├─> hw/test/ compares them (CS)
                           ├─> model/    answer key ──────────┘
                           │   (CS)
                           ├─> tools/ ──> network ──> board/  real chip on the Arty A7 (EE)
                           └─> baseline/ C version on a normal CPU, for the speed comparison
```

## Layout

```
.github/workflows/  CI: builds and tests every push and pull request
model/              pure OCaml, no hardware
  msg.ml              the 4 message types: Add_order, Order_executed,
                      Order_cancel, Order_delete (fields: order_ref, side,
                      price, shares; named after the ITCH spec)
  order_book.ml       REFERENCE MODEL: the answer key for the hardware
  itch.ml             ITCH 5.0 byte layouts: encode / decode / framing
  mold.ml             MoldUDP64 packets: 20-byte header + length-prefixed messages
  feed_gen.ml         random generator of valid message streams
  price_bitmap.ml     next-best-price bitmap prototype (Spec v1), not the answer key
test/               expect tests + randomized tests for model/
hw/                 Hardcaml counter, Always example, ITCH parser + MoldUDP64 deframer; book later
hw/test/            hardware simulations and the testbench
board/              board bring-up: Ethernet, clocks, constraints, Vivado
board/uart/         UART transmitter, 115,200 baud (CS)
tools/              replay: send MoldUDP64 packets over UDP (CS)
bin/gen_feed.ml     writes a feed file used by every stage
dune-project        project settings and dependencies
feed_handler.opam   generated from dune-project; don't edit by hand
feed_handler.opam.locked   exact library versions everyone must use
```

## Versions everyone must match

| What | Version |
|---|---|
| OCaml compiler | **5.2.1** |
| opam | 2.1 or newer (check with `opam --version`) |
| Hardcaml, dune, ppx_expect and all other OCaml libraries | exactly what's in **`feed_handler.opam.locked`** |

The lock file is what keeps everyone on identical versions. Always install
with `--locked` (see below). Without it, opam picks whatever is newest that
day, which may not match the rest of the team or CI.

System tools (any recent version is fine): a C compiler, `git`,
`pkg-config`, `gmp`.

## Setup

Works on **macOS** (Apple Silicon or Intel) and **Windows via WSL** (Ubuntu).
Vivado is the only tool that needs Windows/Linux; it's only used for the
board stages.

### 1. System tools

**macOS**
```sh
xcode-select --install
# Homebrew, if `brew --version` doesn't work. Run the two "Next steps"
# lines it prints at the end, or `brew` won't be found.
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install opam gmp pkg-config git
```

**Windows**: open **Ubuntu** (WSL; install with `wsl --install` in an admin
PowerShell if you don't have it), then:
```sh
sudo apt update
sudo apt install -y opam build-essential pkg-config libgmp-dev git bubblewrap
```

### 2. OCaml 5.2.1 (10–15 min)
```sh
opam init -y
eval $(opam env)
opam switch create fh 5.2.1
eval $(opam env --switch=fh)
```

### 3. The repo and its libraries (20–30 min)
On Windows, clone inside Ubuntu's home folder (`~`), **not** under
`/mnt/c/...` or OneDrive.
```sh
cd ~
git clone https://github.com/Abdsqb/FPGA.git
cd FPGA
opam install . --deps-only --with-test --locked -y
```

### 4. Check it works
```sh
dune build
dune test        # no output = every test passed
dune exec bin/gen_feed.exe -- -n 20 -print
```

### Every new terminal
```sh
cd ~/FPGA
eval $(opam env --switch=fh)
```

### Git sign-in
GitHub doesn't accept your account password for git.
- **macOS:** `brew install gh`, then `gh auth login`.
- **Windows/WSL:** reuse the Windows Git sign-in:
  ```sh
  git config --global credential.helper "/mnt/c/Program\ Files/Git/mingw64/bin/git-credential-manager.exe"
  ```
Also set your name and the email on your GitHub account, so commits are
credited to you:
```sh
git config --global user.name "Your Name"
git config --global user.email "your-github-email@example.com"
```

### Common problems
| Problem | Fix |
|---|---|
| `bwrap` / sandbox error during `opam init` | `opam init -y --disable-sandboxing` |
| Error mentioning `gmp` or `zarith` | install gmp (`brew install gmp` / `sudo apt install libgmp-dev`), rerun the `opam install` line |
| `brew: command not found` | run the two "Next steps" lines Homebrew printed |
| `sudo` password rejected in WSL | in PowerShell: `wsl -u root`, then `passwd YOUR_LINUX_USERNAME`, then `exit` |
| `opam switch create` says `fh` exists | just run `eval $(opam env --switch=fh)` |

## Everyday commands

```sh
dune build                                         # compile everything
dune test                                          # run all tests
dune promote                                       # accept new expect output (read the diff first!)
dune exec bin/gen_feed.exe -- -n 20 -print         # see a feed + top of book
dune exec bin/gen_feed.exe -- -n 100000 -o feed.bin        # bare messages
dune exec bin/gen_feed.exe -- -n 100000 -mold -o feed.mold  # MoldUDP64 packets, ready to send over UDP
dune exec tools/replay_main.exe -- -file feed.mold -rate 100 -addr 192.168.1.255 -port 5000   # send them
dune exec tools/replay_main.exe -- -n 1000 -per-packet 1 -rate 50 -dry-run                 # one message per packet; preview only
```

## Workflow

1. `git checkout -b my-change` (never commit straight to `main`)
2. Commit, push, open a pull request.
3. CI must be green and one teammate must approve before merging.
4. **Never `git push --force`** on `main`.

### Adding or upgrading a library
1. Add it to `depends` in `dune-project`, then `opam install` it.
2. Run `opam lock .` to update `feed_handler.opam.locked`.
3. Commit both files in the same pull request.
4. Everyone else reruns `opam install . --deps-only --with-test --locked -y`
   after it merges.

## Decisions this code assumes (confirm in the spec)

- Prices: integer ticks, ITCH 4 implied decimals (1_000_000 = $100.0000), 32 bits.
- Shares: 32 bits. Up to 4,096 live orders; order_ref 0–4095.
- Best bid/ask report total shares at the price level.
- Order_executed / Order_cancel that brings an order to 0 shares removes it.
- One symbol (`TEST`, stock locate 1). The book never crosses (no matching).

## MoldUDP64: how messages arrive over the network

Each UDP packet is a 20-byte header, then the ITCH messages, each with a
2-byte length in front:

```
 0  Session          10 bytes  ASCII, e.g. "FH00000001"
10  Sequence Number   8 bytes  number of the FIRST message in this packet
18  Message Count     2 bytes  0 = heartbeat, 0xFFFF = end of session
20  [length (2)][ITCH message] [length (2)][ITCH message] ...
```

Packets are at most 1472 bytes (one 1500-byte Ethernet frame minus the IP
and UDP headers). Sequence numbers count messages, so a gap means a dropped
packet. The hardware parser skips the first 20 bytes of each packet, then
reads length, message, length, message... `model/mold.ml` builds and checks
these packets; `gen_feed -mold` writes a file of them, each packet with a
2-byte length in front, so a UDP sender just reads a length, reads that many
bytes and sends them as one datagram.

## Team decisions on ITCH fields

| Question | Decision |
|---|---|
| Tracking Number, Match Number | Ignored by the model and hardware |
| Filter by symbol | Use Stock Locate (2 bytes), not the 8-byte Stock field |
| Timestamp | Not used; latency is counted in clock cycles inside the chip |
| `U` Order Replace | Not supported; stretch goal for replaying real Nasdaq data |

(Proposed by CS; confirm at the next meeting and copy into the spec.)
