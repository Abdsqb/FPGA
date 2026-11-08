# Worked Hardcaml examples: counter, Always FSM, waveform viewer

November 8, 2026. This is the completed worked-example set for Amirlan's Week 1 assignment: source, executed simulations, expected results and explanations. It documents the work performed; it does not certify anyone's personal comprehension.

## Run everything

```sh
opam exec --switch=fh -- dune build
opam exec --switch=fh -- dune test
opam exec --switch=fh -- dune exec hw/demo/learning_demo.exe
opam exec --switch=fh -- dune exec hw/demo/parser_demo.exe
```

The first demo prints a small counter and Always state-machine trace, each followed by a terminal waveform. The parser demo then shows the same ideas in the actual design. Saved output is in [learning-demo.txt](evidence/learning-demo.txt) and [parser-demo.txt](evidence/parser-demo.txt).

## 1. Counter: a register with feedback

Source: [counter.ml](../hw/counter.ml). Test: [test_counter.ml](../hw/test/test_counter.ml).

`Reg_spec.create ~clock ~clear ()` defines clock and reset. `reg_fb` creates an 8-bit register; its next value is `d +:. 1` when enable is high. With enable low it holds its previous value. Synchronous clear wins over enable on the clock edge. Eight bits represent 0 through 255, so the next increment wraps to zero.

Starting at zero, the executed inputs and outputs are:

| Edge after reset | enable | count after edge |
|---:|---:|---:|
| 1 | 1 | 1 |
| 2 | 1 | 2 |
| 3 | 1 | 3 |
| 4 | 0 | 3 |
| 5 | 0 | 3 |
| 6 | 1 | 4 |

The existing expect test also checks wrap after 256 enabled cycles. A signal is a hardware value, not a mutable OCaml integer; `create` constructs the circuit once. `Cyclesim.cycle` is the testbench operation that advances simulated hardware.

## 2. Always: an explicit three-state machine

Source: [always_example.ml](../hw/always_example.ml). Test: [test_always_example.ml](../hw/test/test_always_example.ml).

```text
IDLE --start--> COUNT --fourth enabled cycle--> DONE --next cycle--> IDLE
                  |
                  +-- hold count and state when enable=0
```

`State_machine.create` allocates the state register. `Always.Variable.reg` allocates the count register. `sm.switch` describes each state's actions, `when_` gates assignments, and `<--` schedules a register's next value. `compile` turns the description into a signal graph.

The fourth enabled cycle sees the **old** count equal to 3. On that edge both the new count (4) and the new state (Done) take effect. Checking old count 4 would finish one cycle late. `done_` is high for exactly the Done state, then the unconditional transition returns to Idle. Start is accepted only in Idle; a held start can launch another operation after the machine returns to Idle.

| Input action | busy | done | count after edge |
|---|---:|---:|---:|
| start | 1 | 0 | 0 |
| enable | 1 | 0 | 1 |
| pause | 1 | 0 | 1 |
| enable (start while busy is ignored) | 1 | 0 | 2 |
| enable | 1 | 0 | 3 |
| enable | 0 | 1 | 4 |
| idle cycle | 0 | 0 | 4 |

The test checks this trace, restart, and reset while busy. Testbench steps must execute in a deliberate sequence: put input tuples in a list and iterate over them, rather than placing side-effecting `step()` calls inside a list literal whose evaluation order OCaml does not guarantee.

## 3. Waveform viewer: read the transactions

`Hardcaml_waveterm.Waveform.create sim` wraps a simulator to record cycles. `Waveform.print` displays the recording in the terminal; no GUI installation is needed. Printed waveforms capture the cycle around its edge, while our trace lines explicitly report the values after `Cyclesim.cycle`. Use the clock edges to align them.

In the counter view, count changes only on enabled edges. In the Always view, the pause leaves count unchanged; busy drops when done rises; done lasts one cycle. In the parser view:

1. `in_first` accompanies the type byte, and `in_last` accompanies byte 35 of Add.
2. Only `in_valid && in_ready` transfers a byte. Input gaps do not move offsets.
3. After the last byte, Validate has a full register image, including the final byte.
4. `out_valid` holds while `out_ready=0`. The fields must remain stable.
5. Exactly one transfer occurs when both output handshake signals are high. Do not count every cycle that valid is high as a new message.

The parser demo holds the decoded message for three extra cycles, then accepts it. The literal-vector test adds input bubbles and eight stalled output cycles, including an attempted next input byte while the parser is blocked.

## Explain these answers at the meeting

- **Why register the bytes?** They arrive on different clock edges, while decoding needs multiple fields together.
- **Why a separate Validate state?** Register writes take effect at the edge; this guarantees the final stored byte is visible during validation.
- **Why ready as well as valid?** It lets a slower downstream block defer a transfer without losing or duplicating data.
- **Why retain 64 wire-ID bits before producing 12?** Otherwise ID 4096 would alias slot 0. The decoder validates the upper 52 bits are zero.
- **Why not update the book on every byte?** No complete, checked message exists until all fields and boundaries have been validated.
- **Is the FPGA always constant latency?** This decoder has a defined unstalled schedule. Input gaps, downstream stalls, framing, CDC and the future book algorithm affect end-to-end latency.

For the actual parser's diagram, port widths and transport boundary, see [parser-interface.md](parser-interface.md) and the [printable state-machine sketch](parser-state-machine.pdf).
