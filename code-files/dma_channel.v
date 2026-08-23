`timescale 1ns / 1ps

module dma_channel #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 64,
    parameter FIFO_DEPTH = 512,
    parameter STRB_WIDTH = DATA_WIDTH / 8
)(
    input  wire                     aclk,
    input  wire                     aresetn,

    // --- Configuration from register file ---
    input  wire                     ch_enable,
    input  wire                     ch_sg_mode,
    input  wire [ADDR_WIDTH-1:0]    ch_src_addr,
    input  wire [ADDR_WIDTH-1:0]    ch_dst_addr,
    input  wire [31:0]              ch_xfer_len,
    input  wire [7:0]               ch_burst_len,   // AXI ARLEN/AWLEN value
    input  wire [2:0]               ch_burst_size,  // AXI SIZE
    input  wire [1:0]               ch_src_inc,     // 00=fixed,01=incr,10=wrap
    input  wire [1:0]               ch_dst_inc,

    // --- Peripheral flow-control handshake ---
    input  wire                     dma_req,
    output reg                      dma_ack,
    input  wire                     dma_done_ext,

    // --- Descriptor engine interface ---
    output reg                      desc_fetch_req,
    input  wire                     desc_fetch_done,
    input  wire [ADDR_WIDTH-1:0]    desc_src_addr,
    input  wire [ADDR_WIDTH-1:0]    desc_dst_addr,
    input  wire [31:0]              desc_xfer_len,
    input  wire [7:0]               desc_burst_len,
    input  wire                     desc_last,

    // --- Arbiter request/grant ---
    output reg                      rd_req,
    input  wire                     rd_gnt,
    output reg                      wr_req,
    input  wire                     wr_gnt,

    // --- Status outputs ---
    output reg                      ch_busy,
    output reg                      ch_done,
    output reg                      ch_err,
    output reg                      ch_done_pulse,
    output reg                      ch_err_pulse,
    output reg  [31:0]              bytes_xfered,
    output reg  [ADDR_WIDTH-1:0]    cur_src_addr,
    output reg  [ADDR_WIDTH-1:0]    cur_dst_addr,

    // --- FIFO write port (filled by read engine via axi4_master) ---
    input  wire                     fifo_wr_en,
    input  wire [DATA_WIDTH-1:0]    fifo_wr_data,
    input  wire [STRB_WIDTH-1:0]    fifo_wr_strb,
    output wire                     fifo_wr_full,

    // --- FIFO read port (drained by write engine via axi4_master) ---
    input  wire                     fifo_rd_en,
    output wire [DATA_WIDTH-1:0]    fifo_rd_data,
    output wire [STRB_WIDTH-1:0]    fifo_rd_strb,
    output wire                     fifo_rd_empty
);

    // =========================================================================
    // FSM State Encoding
    // =========================================================================
    localparam [3:0]
        ST_IDLE       = 4'd0,
        ST_FETCH_DESC = 4'd1,
        ST_SETUP      = 4'd2,
        ST_RD_ARB     = 4'd3,
        ST_RD_BURST   = 4'd4,
        ST_WR_ARB     = 4'd5,
        ST_WR_BURST   = 4'd6,
        ST_NEXT_DESC  = 4'd7,
        ST_DONE       = 4'd8,
        ST_ERROR      = 4'd9;

    reg [3:0] state, next_state;

    // =========================================================================
    // Transfer Tracking Registers
    // =========================================================================
    reg [ADDR_WIDTH-1:0]    src_addr_r;     // current working source address
    reg [ADDR_WIDTH-1:0]    dst_addr_r;     // current working destination address
    reg [31:0]              xfer_rem;       // bytes remaining in this descriptor
    reg [31:0]              total_rem;      // bytes remaining total (simple mode)
    reg [7:0]               burst_len_r;    // latched burst length
    reg [2:0]               burst_size_r;   // latched burst size
    reg [31:0]              burst_bytes;    // bytes per burst = (burst_len+1) << burst_size
    reg                     sg_last_r;      // last scatter-gather descriptor

    // Beat / byte counters
    reg [7:0]               rd_beat_cnt;    // beats issued in current read burst
    reg [7:0]               wr_beat_cnt;    // beats issued in current write burst
    reg [31:0]              rd_bytes_done;  // bytes read so far
    reg [31:0]              wr_bytes_done;  // bytes written so far

    // =========================================================================
    // FIFO Instantiation (internal, per-channel)
    // =========================================================================
    // The FIFO is instantiated in dma_top via dma_fifo, and FIFO ports are
    // wired directly into this module. The channel FSM controls read/write
    // indirectly through rd_req/wr_req grants.
    // NOTE: fifo_wr_* and fifo_rd_* are driven by dma_axi4_master when granted.

    // =========================================================================
    // Compute bytes per burst
    // =========================================================================
    always @(*) begin
        burst_bytes = (32'd1 << burst_size_r) * (32'(burst_len_r) + 32'd1);
    end

    // =========================================================================
    // FSM - Sequential
    // =========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn)
            state <= ST_IDLE;
        else
            state <= next_state;
    end

    // =========================================================================
    // FSM - Combinational next-state logic
    // =========================================================================
    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                // Start if channel enabled and (peripheral req or no req needed)
                if (ch_enable && (dma_req || !ch_sg_mode))
                    next_state = ch_sg_mode ? ST_FETCH_DESC : ST_SETUP;
            end
            ST_FETCH_DESC: begin
                if (desc_fetch_done)
                    next_state = ST_SETUP;
            end
            ST_SETUP: begin
                next_state = ST_RD_ARB;
            end
            ST_RD_ARB: begin
                if (rd_gnt)
                    next_state = ST_RD_BURST;
            end
            ST_RD_BURST: begin
                // Move to write once all bytes for this burst block have been read
                if (rd_bytes_done >= xfer_rem)
                    next_state = ST_WR_ARB;
            end
            ST_WR_ARB: begin
                if (wr_gnt)
                    next_state = ST_WR_BURST;
            end
            ST_WR_BURST: begin
                if (wr_bytes_done >= xfer_rem) begin
                    if (ch_sg_mode && !sg_last_r)
                        next_state = ST_NEXT_DESC;
                    else
                        next_state = ST_DONE;
                end
            end
            ST_NEXT_DESC: begin
                next_state = ST_FETCH_DESC;
            end
            ST_DONE: begin
                next_state = ST_IDLE;
            end
            ST_ERROR: begin
                // Stay in error until channel is disabled/reset
                if (!ch_enable)
                    next_state = ST_IDLE;
            end
            default: next_state = ST_IDLE;
        endcase
    end

    // =========================================================================
    // FSM - Output logic and datapath registers
    // =========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ch_busy        <= 1'b0;
            ch_done        <= 1'b0;
            ch_err         <= 1'b0;
            ch_done_pulse  <= 1'b0;
            ch_err_pulse   <= 1'b0;
            dma_ack        <= 1'b0;
            desc_fetch_req <= 1'b0;
            rd_req         <= 1'b0;
            wr_req         <= 1'b0;
            bytes_xfered   <= 32'h0;
            cur_src_addr   <= {ADDR_WIDTH{1'b0}};
            cur_dst_addr   <= {ADDR_WIDTH{1'b0}};
            src_addr_r     <= {ADDR_WIDTH{1'b0}};
            dst_addr_r     <= {ADDR_WIDTH{1'b0}};
            xfer_rem       <= 32'h0;
            total_rem      <= 32'h0;
            burst_len_r    <= 8'hF;
            burst_size_r   <= 3'h3;
            sg_last_r      <= 1'b0;
            rd_beat_cnt    <= 8'h0;
            wr_beat_cnt    <= 8'h0;
            rd_bytes_done  <= 32'h0;
            wr_bytes_done  <= 32'h0;
        end else begin
            // Default pulse deasserts
            ch_done_pulse <= 1'b0;
            ch_err_pulse  <= 1'b0;
            dma_ack       <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                ST_IDLE: begin
                    ch_busy       <= 1'b0;
                    ch_done       <= 1'b0;
                    rd_req        <= 1'b0;
                    wr_req        <= 1'b0;
                    rd_bytes_done <= 32'h0;
                    wr_bytes_done <= 32'h0;
                    bytes_xfered  <= 32'h0;
                    desc_fetch_req<= 1'b0;
                    if (ch_enable && (dma_req || !ch_sg_mode)) begin
                        ch_busy  <= 1'b1;
                        dma_ack  <= 1'b1;  // acknowledge peripheral request
                        if (!ch_sg_mode) begin
                            // Simple mode: latch register values directly
                            src_addr_r  <= ch_src_addr;
                            dst_addr_r  <= ch_dst_addr;
                            xfer_rem    <= ch_xfer_len;
                            total_rem   <= ch_xfer_len;
                            burst_len_r <= ch_burst_len;
                            burst_size_r<= ch_burst_size;
                            sg_last_r   <= 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------
                ST_FETCH_DESC: begin
                    desc_fetch_req <= 1'b1;
                    if (desc_fetch_done) begin
                        desc_fetch_req <= 1'b0;
                        // Latch descriptor fields
                        src_addr_r  <= desc_src_addr;
                        dst_addr_r  <= desc_dst_addr;
                        xfer_rem    <= desc_xfer_len;
                        burst_len_r <= desc_burst_len;
                        burst_size_r<= 3'h3; // fixed 64-bit for now
                        sg_last_r   <= desc_last;
                        rd_bytes_done <= 32'h0;
                        wr_bytes_done <= 32'h0;
                    end
                end

                // ---------------------------------------------------------
                ST_SETUP: begin
                    cur_src_addr  <= src_addr_r;
                    cur_dst_addr  <= dst_addr_r;
                    rd_bytes_done <= 32'h0;
                    wr_bytes_done <= 32'h0;
                end

                // ---------------------------------------------------------
                ST_RD_ARB: begin
                    rd_req <= 1'b1;
                end

                // ---------------------------------------------------------
                ST_RD_BURST: begin
                    rd_req <= 1'b0;
                    // Track read progress (axi4_master drives FIFO write side)
                    if (fifo_wr_en) begin
                        rd_bytes_done <= rd_bytes_done + (1 << burst_size_r);
                        cur_src_addr  <= cur_src_addr + (ch_src_inc == 2'b01 ?
                                         (1 << burst_size_r) : 0);
                    end
                end

                // ---------------------------------------------------------
                ST_WR_ARB: begin
                    wr_req <= 1'b1;
                end

                // ---------------------------------------------------------
                ST_WR_BURST: begin
                    wr_req <= 1'b0;
                    // Track write progress (axi4_master drives FIFO read side)
                    if (fifo_rd_en) begin
                        wr_bytes_done <= wr_bytes_done + (1 << burst_size_r);
                        bytes_xfered  <= bytes_xfered  + (1 << burst_size_r);
                        cur_dst_addr  <= cur_dst_addr + (ch_dst_inc == 2'b01 ?
                                         (1 << burst_size_r) : 0);
                    end
                end

                // ---------------------------------------------------------
                ST_NEXT_DESC: begin
                    rd_bytes_done <= 32'h0;
                    wr_bytes_done <= 32'h0;
                end

                // ---------------------------------------------------------
                ST_DONE: begin
                    ch_done       <= 1'b1;
                    ch_done_pulse <= 1'b1;
                    ch_busy       <= 1'b0;
                end

                // ---------------------------------------------------------
                ST_ERROR: begin
                    ch_err        <= 1'b1;
                    ch_err_pulse  <= 1'b1;
                    ch_busy       <= 1'b0;
                end

                default: ;
            endcase

            // AXI error detection: if RRESP or BRESP indicates error
            // (driven externally via error injection from axi4_master)
        end
    end

    // =========================================================================
    // Unused ports tied for FIFO pass-through
    // (FIFO is instantiated in dma_top, ports wired back here for monitoring)
    // =========================================================================
    assign fifo_wr_full  = 1'b0; // driven from dma_fifo in dma_top
    assign fifo_rd_empty = 1'b0; // driven from dma_fifo in dma_top
    assign fifo_rd_data  = {DATA_WIDTH{1'b0}};
    assign fifo_rd_strb  = {STRB_WIDTH{1'b0}};

endmodule
