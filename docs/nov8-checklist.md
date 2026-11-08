# Amirlan - November 8 deliverable checklist

This checklist records completed artifacts and executed checks for the four Amirlan-owned Week 1 rows. The worked examples were prepared and executed with Codex assistance; personal reading/comprehension and team approval are not inferred from passing tests.

| Task | Deliverable status | Evidence / note |
|---|---|---|
| Work through Hardcaml examples: counter, Always state machine, waveform viewer | Complete worked-example set, executed | [Walkthrough](hardcaml-worked-examples.md); [Always circuit](../hw/always_example.ml); counter and Always expect tests; [saved demo](evidence/learning-demo.txt). Nov 5 extended target slipped; deliverables completed Nov 8. |
| Sketch parser state machine on paper | Complete printable sketch | [One-page PDF](parser-state-machine.pdf), with [source](render_parser_sketch.py); [full decoder and transport FSM notes](parser-interface.md). Nov 5 extended target slipped; sketch completed Nov 8. Printing or handwriting is a physical step, not claimed here. |
| Define parser Hardcaml inputs and outputs | Complete implementation and contract | [Typed ports](../hw/itch_parser.ml) and [interface contract](parser-interface.md), including widths, framing, reset and error codes. Outputs aligned to Spec v1 on Nov 8 (one-cycle `valid`, 64-bit `order_ref`, `msg_type`/`side` names). |
| Stretch: testbench feeding the 36-byte Add Order example | Complete and passing | [Literal-vector test and regression](../hw/test/test_itch_parser.ml); [demo output](evidence/parser-demo.txt). All four types plus 10,000 generator messages checked. |

## Completion checks

- [x] Counter expect test passes, including enable hold and wrap.
- [x] Standalone Always FSM passes pause, completion pulse, restart and reset tests.
- [x] Counter/Always waveform demo runs and its output is saved.
- [x] Printable FSM sketch generated and visually reviewed.
- [x] Parser input/output contract matches implemented port types.
- [x] Literal 36-byte AAPL Add decodes as ref 42, Buy, 100 shares, price 1,502,500.
- [x] Input bubbles preserve fields and message count; back-to-back messages decode with no gaps.
- [x] Invalid lengths, boundaries and side reject without book updates; full 64-bit order refs pass through (Spec v1).
- [x] Reset flushes partial and pending messages; foreign stock is filtered.
- [x] 10,000 generated messages agree with the existing encoder/model.
- [x] Full build/tests and Verilog generation pass.

See [validation.txt](evidence/validation.txt) for commands and environment. Run `opam exec --switch=fh -- dune exec hw/demo/learning_demo.exe` to follow the worked examples, then `opam exec --switch=fh -- dune exec hw/demo/parser_demo.exe` for the meeting demonstration.

## Scope and team handoff

The decoder accepts already framed ITCH message bodies, not complete UDP packets. MoldUDP64 hardware framing, hardware order-table/top-of-book implementation, CDC testing, synthesis, timing closure and board bring-up are future stages. The generated-message regression uses the software order book for both streams; it does not prove a hardware book exists.

Proposed ownership: Enes supplies validated UDP payloads and packet/error boundaries after clock crossing; Amirlan implements MoldUDP64 framing and this decoder; Abdulla consumes the Spec v1 parser outputs in his checker. Approve that boundary at the meeting.

Shared Everyone rows are distinct from these four assigned deliverables. The recorded toolchain/counter and ITCH reading statuses were already Done. Real World OCaml reading remains personal work to confirm; spec-review comments are included below for the team, not posted to the shared artifact.

## Spec-review comments prepared for November 8

1. Confirm 4096 synthetic IDs; validate the full 64-bit wire ID before narrowing to 12 address bits.
2. Store price (32), remaining quantity (32), side (1) and valid (1): 66 logical bits per order before BRAM packing, not 64.
3. Price-level aggregate quantity can require 44 bits for 4096 maximum-size 32-bit orders.
4. Freeze target stock locate and its session-specific symbol mapping; the decoder does not learn the mapping.
5. Choose a bounded price grid before using a bitmap; a top-K cache needs a recovery path.
6. Agree packet validation, buffering, receive-error and overflow behavior. Ready/valid cannot pause the Ethernet wire.
7. Measure latency with a local cycle counter and explicit start/end events; the ITCH timestamp is not local processing time.
