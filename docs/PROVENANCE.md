# Source provenance

M. Roohan Khan confirms that he and Talib developed the reference projects
together and that Talib permits reuse and enhancement. The historical base of
this repository is
[`sha1kh-talib/DMA-PROTOCOL`](https://github.com/sha1kh-talib/DMA-PROTOCOL)
commit `85868386f1d4c105b8baa666c5a6c273756fa8e5`. Its original
`README.md` contains the MIT licence and the notice
`Copyright (c) 2026 DMA RTL Team`. That entire README is retained as
`docs/UPSTREAM_README.md`; all ten original Verilog files are retained
byte-for-byte in `upstream/code-files/`. The original Git commit remains an
ancestor of this branch.

The related jointly developed
[`AMBA-AXI-Full-DMA-Integration`](https://github.com/sha1kh-talib/AMBA-AXI-Full-DMA-Integration)
was inspected at `21d8c32c3f70956aba71cc6f40ec24c2a3131ee1`.
It is design context; its source was not mixed into this implementation.
No Arham source is included.

The archived 64-bit DMA has multiple apparent FIFO signal owners in
`dma_top.v`: the channel and AXI master connect to the same FIFO data nets,
and `dma_channel.v` drives `fifo_rd_data`/strb constants. The reviewed
`dma_axi4_master.v` computes bursts from length and remaining bytes but has
no visible cap at the AXI 4 KiB boundary. ModelSim Intel FPGA Starter Edition
2020.1 compiled the nine design files with zero compile errors/warnings; top
elaboration returned exit 0 with 16 unconnected FIFO-status-port warnings.
Those results are preflight observations, not a functional pass.

The new bounded engine uses one owner for each burst-buffer write and read
index, independently plans read and write bursts at both 4 KiB boundaries,
and has a separate self-checking regression. Each new file and fix belongs to
the milestone commit(s), distinct from the preserved upstream commit.
