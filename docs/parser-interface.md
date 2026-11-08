# Parser interface — matches Spec v1

Prepared for Amirlan (CompE), Enes (EE), and Abdulla (CS). Updated November 8, 2026 to match Spec v1: the parser takes the spec's single byte stream (the UDP payload) and produces the spec's "Parser → order book" signals, with no extra ports. Implemented in `hw/itch_parser.ml` and `hw/mold_deframer.ml`; tested in `hw/test/test_itch_parser.ml`.

## Where it sits

```text
Enes: Ethernet / IPv4 / UDP receive and clock crossing
    │ UDP payload: in_data[7:0] / in_valid / in_last (last byte of the payload)
    ▼
Itch_parser  (hw/itch_parser.ml)
    ├─ Mold_deframer: strips the 20-byte MoldUDP64 header and each 2-byte length,
    │                 marks each ITCH message's first/last byte (internal signals)
    └─ decoder:       collects one message, checks it, pulses valid
    │ valid (one cycle) / msg_type / order_ref[63:0] / side / shares / price
    ▼
Amirlan: order table + top of book [future hardware]

Abdulla: encoder + feed generator + reference model + comparison tests
```

## Ports

All signals use the core clock.

| Input | Bits | Meaning |
|---|---:|---|
| `clock` | 1 | Rising-edge core clock |
| `clear` | 1 | Synchronous reset; drops any partial packet or message |
| `in_data` | 8 | One byte of the UDP payload, in network order |
| `in_valid` | 1 | A byte is on `in_data` this cycle |
| `in_last` | 1 | This is the last byte of the UDP payload |

| Output | Bits | Meaning (Spec v1) |
|---|---:|---|
| `valid` | 1 | High for exactly one cycle per good message |
| `msg_type` | 2 | 0 = Add, 1 = Executed, 2 = Cancel, 3 = Delete |
| `order_ref` | 64 | The full wire Order Reference Number; the order book uses its low 12 bits as the table index |
| `side` | 1 | Add: 0 = buy, 1 = sell; otherwise 0 |
| `shares` | 32 | Add: order size; Executed/Cancel: shares removed; Delete: 0 |
| `price` | 32 | Add: price in ITCH units ($0.0001); otherwise 0 |

The inputs carry an `in_` prefix only so their names don't clash with the output `valid`; they are the spec's `data`, `valid` and `last`.

**Stock Locate** is a build-time setting (`Itch_parser.create ~stock_locate`, default 1), not a port. Only messages whose Stock Locate matches are passed on. Our generator and encoder use 1; the spec should record that value.

There is no backpressure, as in Spec v1: a byte is taken on every cycle with `in_valid = 1`. Output fields are meaningful only in the cycle where `valid = 1`; the order book must capture them then.

## What is checked, and what is dropped

A message produces no `valid` pulse if its type isn't A/E/X/D, its length is wrong for its type (A 36, E 31, X 23, D 19), its Stock Locate doesn't match, or an Add's side byte isn't `B`/`S`. Dropping is silent; the next message is unaffected. Order refs are not range-checked: Spec v1 passes all 64 bits and the book uses the low 12, which is safe because the generator only issues refs 0–4,095.

Book-level bad input (unknown ref, price outside the window, over-reduction; Spec v1 rule 4) is the order book's job, not the parser's.

## MoldUDP64 deframer (cut-through)

```text
HEADER (20 bytes) → LEN_HI → LEN_LO → BODY (length bytes) ─┐
   ▲                   ▲                                   │
   │                   └──── more messages in the packet ──┘
   └── in_last: end of packet (back to HEADER for the next one)
```

A 20-byte packet (heartbeat, or end of session) carries no messages. An empty block (length 0) is skipped. If a packet ends in the middle of a message, that message is dropped (`abort` resets the decoder).

**Cut-through:** every byte is passed on in the same cycle it arrives; nothing is buffered, so the deframer adds no latency. **Accuracy note, to revisit:** messages reach the book before the end of their packet is seen, so a packet that turns out bad at its end (truncated, or flagged by rxerr / FIFO overflow once those exist) may already have updated the book with its earlier messages. Store-and-forward (buffer, check, then replay) would prevent that, at the cost of up to 1,472 × 8 = 11,776 cycles (about 118 µs) for a full packet. The header's sequence number and message count are not checked yet, so a lost packet goes unnoticed. These caveats are marked with `NOTE (accuracy, revisit later)` in `hw/mold_deframer.ml`.

## Decoder state machine

```text
                  first byte
         IDLE ─────────────────► COLLECT
           │                        │ last byte
           │ first and last together│
           └──────────────┐         ▼
                          ▼
                        VALIDATE ── valid = 1 for this one cycle if good
                          │
                          └──────────────────────────► IDLE

 Unexpected first, missing first, or more than 36 bytes ──► DRAIN ── last ──► IDLE
 clear (or a deframer abort) from any state ──► IDLE
```

Collect stores up to 36 bytes in registers. Validation happens one clock after the last byte is stored, so the final byte is available before fields are inspected. Numeric fields are read most-significant byte first.

## Model handoff

On each cycle with `valid = 1`, build exactly one `Model.Msg.t`:

| msg_type | Variant |
|---:|---|
| 0 | `Add_order { order_ref; side = (if side = 1 then Sell else Buy); shares; price }` |
| 1 | `Order_executed { order_ref; shares }` |
| 2 | `Order_cancel { order_ref; shares }` |
| 3 | `Order_delete { order_ref }` |

The reference implementation is `decoded` in `hw/test/test_itch_parser.ml`.

## Timing and current validation

After a message's last byte at clock edge L, `valid` is high for the one cycle after edge L. With cut-through deframing, that is the parser's whole delay: 1 cycle after the message's last byte. Between messages in a packet, the 2 length bytes give the decoder time to finish, so packets can arrive back to back with no idle cycles.

Verified: `dune build`, `dune test`, the waveform demo, and Verilog generation. Tests feed real MoldUDP64 packets built with `Model.Mold` and cover the reading guide's AAPL vector, all four message types in one packet, full 64-bit order refs, heartbeat and end-of-session packets, bad types/sides/lengths, other-stock messages, truncated packets, reset mid-packet, 1,000 messages back to back with no gaps, and 10,000 generated messages compared against the software order book after every message. The hardware order book itself is not built yet.

## Sources

- [Team roadmap](https://claude.ai/artifact/FRBQM18PBVMkVzRMMDKQaV#7c7df410-2643) and [Week 1 assignments](https://claude.ai/artifact/FRBQM18PBVMkVzRMMDKQaV#0a347d78-5107), read November 8, 2026.
- [Reading guide and exact AAPL vector](https://claude.ai/artifact/FRBQM18PBVMkVzRMMDKQaV#f4ab383d-43a1).
- [Nasdaq ITCH 5.0](https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHSpecification.pdf), Data Types and sections 1.3.1, 1.4.1, 1.4.3, 1.4.4.
- [MoldUDP64](https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/moldudp64.pdf), downstream header, message blocks, heartbeat and end of session.
- [Hardcaml simulation documentation](https://docs.hardcaml.org/hardcaml-docs/simulating-circuits/simulation/) and installed v0.17.0 interfaces.
- [Team repository](https://github.com/Abdsqb/FPGA), base commit `031100b25802771026f8f959c5e78a305353bf08`.
