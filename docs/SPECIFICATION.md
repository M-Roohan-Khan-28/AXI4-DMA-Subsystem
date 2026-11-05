# Bounded single-channel DMA specification

This first milestone is a deliberately limited memory-to-memory AXI4 DMA.
It is not a production DMA, an AXI4 conformance certificate, or evidence for
the archived four-channel and descriptor features.

## Interfaces and operation

- One clock/reset domain. `aresetn` resets the DMA and the test responder
  together. Resetting only this master does not guarantee cancellation of
  transactions already accepted by an external target.
- A 32-bit AXI4-Lite control slave. Write address and data are accepted
  independently; one control response and one control read may be pending.
  Full-word `WSTRB=4'b1111` is required for writable registers.
- A 64-bit AXI4 data master using byte addresses, fixed ID zero, eight-byte
  beats (`AxSIZE=3`), INCR bursts of 1–16 beats, and no reordering.
  The engine reads one complete burst into a 16-entry buffer, then writes
  the matching destination burst. At most one read **or** one write burst is
  outstanding at a time. It does not overlap read and write bursts.
- Source and destination start addresses must be eight-byte aligned for
  nonzero lengths. Supported length is 0–4096 bytes. A zero length completes
  with no AXI data-bus activity, regardless of the programmed addresses.
  Nonempty overlapping ranges, address overflow, misalignment and lengths
  above 4096 are rejected before any data-bus request.
- The burst planner limits both source and destination to the current 4 KiB
  page. The final write beat uses only the low `length mod 8` strobes.
  Unused bytes of the final source beat are ignored. Source reads therefore
  must target ordinary RAM, not side-effecting MMIO.

## Control registers

| Offset | Name | Read | Write |
| --- | --- | --- | --- |
| `0x00` | SRC_ADDR | 32-bit source byte address | Full word while idle |
| `0x04` | DST_ADDR | 32-bit destination byte address | Full word while idle |
| `0x08` | LENGTH | Byte count | Full word while idle |
| `0x0C` | CONTROL | 0 | bit 0: start; bit 1: acknowledge completion/error |
| `0x10` | STATUS | bit 0 busy, bit 1 done, bit 2 error, bit 3 irq | Read only |
| `0x14` | ERROR_CODE | 0 none, 1 invalid request, 2 read response/protocol, 3 write response/protocol | Read only |

Unknown/misaligned control addresses and writes to read-only registers return
`SLVERR`. Configuration writes and starts while busy return `SLVERR` and do
not change the active transfer. Acknowledge while busy also returns `SLVERR`.
Idle acknowledge clears done, error, code and interrupt. A new accepted start
also clears the previous completion state.

## Completion, errors and reset

`done` and `irq` remain asserted after a successful or rejected request
until acknowledged or a new start. `error` and `ERROR_CODE` identify a
rejected request or bus failure. On a read error, the DMA consumes the rest
of the already accepted read burst, then stops without writing that burst.
Earlier destination bursts may have committed. On a write response error, the
already accepted write burst may have committed; no later bursts are issued.
The bus target decides whether a reported write error implies a memory update.
Reset clears control state and outputs; the test responder shares the reset.

The testbench enforces a finite completion bound as a **test environment**
assumption. AXI4 itself does not impose that bound.

## Verification gate

The self-checking harness models memory as bytes, snapshots the
original source bytes for an independent copy oracle, compares every
destination byte plus guard regions, and separately counts accepted AXI
addresses/data/responses. Directed tests cover 0, 1, 8, 9, 128, 129 and
4096-byte lengths; both sides of 4 KiB boundaries; invalid requests; busy
writes; response and acknowledgment behavior; independent channel stalls;
reset during activity; and injected read and write errors. A fixed-seed
variation exercises supported lengths, addresses and stalls. A disposable
data fault must make the runner exit nonzero.

Only actually executed checks and real simulator logs will be reported as
results. No coverage percentage, synthesis frequency or area is inferred
from the upstream README.
