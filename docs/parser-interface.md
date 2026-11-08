# Parser interface proposal — November 8, 2026

Prepared for Amirlan (CompE), Enes (EE), and Abdulla (CS). The ITCH decoder below is implemented and tested. Its outputs follow Spec v1 ("Parser → order book"): a one-cycle `valid` pulse, `msg_type`, a 64-bit `order_ref`, `side`, `shares` and `price`. The MoldUDP64 adapter is a proposed next step.

## Boundaries and ownership

```text
Enes: Ethernet / IPv4 / UDP receive and clock crossing
    │ validated UDP payload, packet boundaries, loss/error indication
    ▼
Amirlan: MoldUDP64 adapter [design only, week 2]
    │ strips 20-byte header and each 2-byte message length
    │ framed ITCH bytes: data / valid / first / last
    ▼
Amirlan: Itch_parser [implemented here]
    │ valid (one cycle) / msg_type / order_ref[63:0] / side / shares / price
    │ (+ debug: timestamp_ns / error / filtered)
    ▼
Amirlan: order table + top of book [future hardware]

Abdulla: encoder + feed generator + reference model + comparison tests
```

`hw/itch_parser.ml` accepts one ITCH body at a time. Do not feed it a MoldUDP64 header, a two-byte length prefix, Ethernet headers, or raw MII nibbles. The raw Add Order example is exactly 36 input transfers. `Model.Itch.encode` supplies a body; `Model.Itch.frame` adds a prefix and therefore cannot be sent directly to this decoder.

## Implemented ports

All signals use the core clock. Widths refer to unsigned bit vectors. Suggested board frequency is 100 MHz; no clock frequency is required by the simulation.

| Input | Bits | Contract |
|---|---:|---|
| `clock` | 1 | Rising-edge core clock |
| `clear` | 1 | Synchronous active-high reset; discards partial and pending messages |
| `in_data` | 8 | One ITCH byte, in network order |
| `in_valid` | 1 | Producer offers a byte |
| `in_first` | 1 | Assert with type byte, offset 0 |
| `in_last` | 1 | Assert with the actual final byte of this message |
| `stock_locate` | 16 | Configured target security; latched with the first byte |

| Output | Bits | Contract |
|---|---:|---|
| `valid` | 1 | High for exactly one cycle per good message (Spec v1) |
| `msg_type` | 2 | 0 = A, 1 = E, 2 = X, 3 = D |
| `order_ref` | 64 | The full wire Order Reference Number (Spec v1); the order book uses its low 12 bits as the table index |
| `side` | 1 | A: 0 = Buy, 1 = Sell; otherwise zero |
| `shares` | 32 | A: initial shares; E/X: amount to subtract; D: zero |
| `price` | 32 | A: integer Price(4); otherwise zero |
| `timestamp_ns` | 48 | Exchange timestamp, retained for debugging |
| `error` | 3 | One-cycle diagnostic pulse, codes below |
| `filtered` | 1 | One-cycle pulse for a correctly sized supported message with a different locate |

There is no backpressure, as in Spec v1. A byte is taken on every rising edge where `in_valid=1`; a bubble (`in_valid=0`) advances nothing. The decoder accepts input in every state, including the Validate cycle in which it reports the previous message, so back-to-back messages arrive with no gap (tested: 1,000 messages, one byte per cycle). Output fields are meaningful only in the cycle where `valid=1`; the order book must capture them in that cycle. During `clear`, `valid` is masked low.

Error codes: **1** missing first or unexpected first within a message; **2** incorrect length or more than 36 bytes; **3** unsupported type; **4** invalid A side byte. Errors are one-cycle pulses, one cycle after the bad message ends; an integrating module should count or latch them. Foreign-stock filtering precedes side validation. Order refs are not range-checked here: Spec v1 passes all 64 bits and the book uses the low 12, which is safe because the generator only issues refs 0–4,095. Errors never emit an order-book update.

An oversized or misframed message drains through the next accepted `in_last`. If a producer abandons a partial message without sending `in_last`, the adapter must reset/flush the decoder before restarting. Unknown messages of more than 36 bytes receive the oversize diagnostic. These are prototype diagnostics, not a complete Nasdaq error taxonomy.

## Decoder state-machine sketch

```text
                  first byte accepted
         IDLE ───────────────────────────► COLLECT
           │                                  │
           │ first and last together          │ final byte accepted
           └────────────────┐                 │
                            ▼                 ▼
                           VALIDATE ── valid = 1 for this one cycle if good
                              │
                              ├── next byte is a new first byte ──► COLLECT (no gap)
                              └── otherwise ──────────────────────► IDLE

 Missing/unexpected first or >36 bytes ──► DRAIN ── accepted last ──► IDLE
 clear from any state ──► IDLE
```

Collect stores up to 36 bytes in registers. A six-bit byte counter increments only on input transfer. Validation happens one clock after the last byte is stored, so the final byte is available before fields are inspected. This deliberately avoids reading the previous value of a register on its write edge.

Supported lengths are A=36, E=31, X=23, D=19. All use the ID at offsets 11–18. A uses side at 19, shares at 20–23, and price at 32–35. E/X use shares at 19–22. Numeric fields concatenate their bytes most-significant first. Tracking, symbol text, and E match number are consumed but not emitted. Locate filtering assumes the team has configured the locate-to-symbol mapping; it does not discover that mapping from Stock Directory messages.

## Model handoff

On each cycle with `valid=1`, build exactly one `Model.Msg.t`:

| msg_type | Variant |
|---:|---|
| 0 | `Add_order { order_ref; side = (if side = 1 then Sell else Buy); shares; price }` |
| 1 | `Order_executed { order_ref; shares }` |
| 2 | `Order_cancel { order_ref; shares }` |
| 3 | `Order_delete { order_ref }` |

The reference implementation is `decoded` in `hw/test/test_itch_parser.ml`. The generator's refs (0–4,095) fit OCaml integers. The decoder passes the full 64-bit wire ID; narrowing to a 12-bit table index happens in the order book, per Spec v1. Real Nasdaq IDs would alias slots, which is why hashing them is a stretch goal.

Duplicate live IDs, unknown IDs, over-reduction, zero quantities, and price-domain rules belong to order-book validation. This decoder checks encoding, framing, side and selected locate. It does not claim to implement the full book or full real-market feed semantics.

## Proposed MoldUDP64 adapter state machine

```text
WAIT_PACKET → HEADER[20] → LENGTH_HI → LENGTH_LO → BODY[length]
                             ▲                       │
                             └── more blocks ────────┘
                          last block → EXPECT_PACKET_END → WAIT_PACKET
malformed / sequence mismatch → DROP_REMAINDER → WAIT_PACKET (book invalid)
```

Parse the session, sequence, and count; do not blindly skip all 20 header bytes. Count 0 is heartbeat; 65535 is end-of-session. Those have no data messages. A normal length excludes the two length bytes themselves. Mold permits zero-length blocks; this ITCH subset rejects them as containing no type byte. Each body's first/last flags derive from its length counter, not from the UDP packet boundary. Count every block for sequence tracking, including unsupported or filtered messages.

Validate that declared lengths and message count fit the packet and that no bytes remain afterward. Carry packet boundaries and receive-error/overflow information across the clock crossing. For the first implementation, buffer and validate an entire UDP payload before replaying its bodies; then a late framing/FCS error cannot silently commit part of a corrupt packet. Agree buffer capacity, oversized-datagram rejection, and checksum ownership with Enes. A streaming design would instead need explicit book invalidation/recovery after late errors; it cannot undo already accepted updates for free.

Track session and expected sequence. A gap or duplicate/out-of-order packet must not be applied as if fresh; stop valid quote publication and report it. Retransmission/recovery is a later feature. If upstream FIFO overflow occurs, invalidate the book rather than silently dropping bytes. Ready/valid only backpressures buffered logic; Ethernet traffic itself does not stop because this decoder is busy.

## Timing and current validation

After the final byte at edge L, `valid` is high for the one cycle after edge L (the Validate state) and low again after edge L+1. The next message's first byte can arrive in that same cycle, so an N-byte message occupies exactly N input cycles and consecutive Add Orders can start 36 cycles apart. Bubbles add time. These are decoder timings, not board-to-UART or end-to-end measurements.

Use a local cycle counter to measure first-input-transfer to book-update completion; report input stalls and consumer stalls separately. The exchange timestamp is not a local cycle counter and cannot establish FPGA processing latency by itself. Neither board timing closure nor constant end-to-end latency has been demonstrated.

Verified locally: `dune build`, `dune test`, a waveform demo, and Verilog generation. Tests include the literal reading-guide AAPL vector, all four message types, unsigned quantities, full 64-bit order refs, input bubbles, back-to-back messages with no gaps, malformed lengths/boundaries, foreign locate, reset, and 10,000 generated messages. The randomized test compares decoded messages and applies both streams to the software order book; it does **not** test hardware order-book storage.

## Sources

- [Team roadmap](https://claude.ai/artifact/FRBQM18PBVMkVzRMMDKQaV#7c7df410-2643) and [Week 1 assignments](https://claude.ai/artifact/FRBQM18PBVMkVzRMMDKQaV#0a347d78-5107), read November 8, 2026.
- [Reading guide and exact AAPL vector](https://claude.ai/artifact/FRBQM18PBVMkVzRMMDKQaV#f4ab383d-43a1).
- [Nasdaq ITCH 5.0](https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHSpecification.pdf), Data Types and sections 1.3.1, 1.4.1, 1.4.3, 1.4.4.
- [MoldUDP64](https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/moldudp64.pdf), downstream header, message blocks, heartbeat and end of session.
- [Hardcaml simulation documentation](https://docs.hardcaml.org/hardcaml-docs/simulating-circuits/simulation/) and installed v0.17.0 interfaces.
- [Team repository](https://github.com/Abdsqb/FPGA), base commit `031100b25802771026f8f959c5e78a305353bf08`.
