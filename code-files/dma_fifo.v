`timescale 1ns / 1ps

module dma_fifo #(
    parameter DATA_WIDTH  = 72,    // 64-bit data + 8-bit strobe
    parameter DEPTH       = 512,   // number of entries (must be power of 2)
    parameter AFULL_THRES = 8,     // almost-full threshold (entries from full)
    parameter AEMPTY_THRES= 8      // almost-empty threshold (entries from empty)
)(
    input  wire                     aclk,
    input  wire                     aresetn,

    // --- Write Port ---
    input  wire                     wr_en,
    input  wire [DATA_WIDTH-1:0]    wr_data,
    output wire                     wr_full,
    output wire                     wr_almost_full,

    // --- Read Port ---
    input  wire                     rd_en,
    output wire [DATA_WIDTH-1:0]    rd_data,
    output wire                     rd_empty,
    output wire                     rd_almost_empty,

    // --- Status ---
    output wire [$clog2(DEPTH):0]   fill_level      // 0 .. DEPTH
);

    // =========================================================================
    // Parameters Derived
    // =========================================================================
    localparam PTR_WIDTH = $clog2(DEPTH);  // e.g. 9 for DEPTH=512

    // =========================================================================
    // Storage Array
    // =========================================================================
    reg [DATA_WIDTH-1:0]    mem [0:DEPTH-1];

    // =========================================================================
    // Pointers (extra bit for full/empty differentiation)
    // =========================================================================
    reg [PTR_WIDTH:0]   wr_ptr;     // write pointer (PTR_WIDTH+1 bits)
    reg [PTR_WIDTH:0]   rd_ptr;     // read  pointer (PTR_WIDTH+1 bits)

    // =========================================================================
    // Status Flags
    // =========================================================================
    wire [PTR_WIDTH:0]  count;
    assign count       = wr_ptr - rd_ptr;
    assign fill_level  = count;
    assign wr_full     = (count == DEPTH[PTR_WIDTH:0]);
    assign rd_empty    = (count == {(PTR_WIDTH+1){1'b0}});
    assign wr_almost_full  = (count >= (DEPTH - AFULL_THRES));
    assign rd_almost_empty = (count <= AEMPTY_THRES);

    // =========================================================================
    // Write Logic
    // =========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_ptr <= {(PTR_WIDTH+1){1'b0}};
        end else begin
            if (wr_en && !wr_full) begin
                mem[wr_ptr[PTR_WIDTH-1:0]] <= wr_data;
                wr_ptr <= wr_ptr + 1'b1;
            end
        end
    end

    // =========================================================================
    // Read Logic
    // =========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_ptr <= {(PTR_WIDTH+1){1'b0}};
        end else begin
            if (rd_en && !rd_empty) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
        end
    end

    // =========================================================================
    // Read Data Output (registered, 1-cycle latency)
    // =========================================================================
    assign rd_data = mem[rd_ptr[PTR_WIDTH-1:0]];

    // =========================================================================
    // Overflow / Underflow Assertions (simulation only)
    // =========================================================================
    // synthesis translate_off
    always @(posedge aclk) begin
        if (aresetn) begin
            if (wr_en && wr_full)
                $display("[DMA_FIFO] WARNING: Write while FULL at time %0t", $time);
            if (rd_en && rd_empty)
                $display("[DMA_FIFO] WARNING: Read while EMPTY at time %0t", $time);
        end
    end
    // synthesis translate_on

endmodule
