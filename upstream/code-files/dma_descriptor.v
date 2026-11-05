`timescale 1ns / 1ps

module dma_descriptor #(
    parameter NUM_CH     = 4,
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 64
)(
    input  wire                     aclk,
    input  wire                     aresetn,

    // --- Channel configuration ---
    input  wire [NUM_CH-1:0]        ch_sg_mode,
    input  wire [NUM_CH*32-1:0]     ch_desc_base,   // descriptor list base address per channel

    // --- Channel fetch request/done handshake ---
    input  wire [NUM_CH-1:0]        fetch_req,      // channel wants a descriptor
    output reg  [NUM_CH-1:0]        fetch_done,     // descriptor ready for channel

    // --- Decoded descriptor outputs (per channel, registered) ---
    output reg  [NUM_CH*32-1:0]     desc_src_addr,
    output reg  [NUM_CH*32-1:0]     desc_dst_addr,
    output reg  [NUM_CH*32-1:0]     desc_xfer_len,
    output reg  [NUM_CH*8-1:0]      desc_burst_len,
    output reg  [NUM_CH-1:0]        desc_last,
    output reg  [NUM_CH*32-1:0]     desc_next_ptr,

    // --- AXI4 Read interface to fetch descriptors from memory ---
    output reg  [ADDR_WIDTH-1:0]    m_axi_araddr,
    output reg  [7:0]               m_axi_arlen,
    output reg                      m_axi_arvalid,
    input  wire                     m_axi_arready,
    input  wire [DATA_WIDTH-1:0]    m_axi_rdata,
    input  wire [1:0]               m_axi_rresp,
    input  wire                     m_axi_rlast,
    input  wire                     m_axi_rvalid,
    output reg                      m_axi_rready
);

    // =========================================================================
    // FSM States
    // =========================================================================
    localparam [2:0]
        ST_IDLE    = 3'd0,
        ST_ARB     = 3'd1,
        ST_ARADDR  = 3'd2,
        ST_RDATA   = 3'd3,
        ST_DECODE  = 3'd4,
        ST_DONE    = 3'd5;

    reg [2:0]   state;

    // =========================================================================
    // Internal Registers
    // =========================================================================
    reg [$clog2(NUM_CH)-1:0]    active_ch;      // channel being served
    reg [ADDR_WIDTH-1:0]        cur_ptr;         // current descriptor pointer
    reg [31:0]                  raw_word [0:7]; // captured descriptor words
    reg [2:0]                   word_idx;        // word index during fetch

    // Next-descriptor pointer table (per channel, updated as chain is walked)
    reg [ADDR_WIDTH-1:0]        next_ptr_r [0:NUM_CH-1];

    integer i;

    // =========================================================================
    // Descriptor Fetch FSM
    // =========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state       <= ST_IDLE;
            active_ch   <= {$clog2(NUM_CH){1'b0}};
            fetch_done  <= {NUM_CH{1'b0}};
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b0;
            m_axi_araddr  <= {ADDR_WIDTH{1'b0}};
            m_axi_arlen   <= 8'h3;  // 4 beats (32 bytes, covers 4 x 64-bit words)
            word_idx      <= 3'h0;
            for (i = 0; i < NUM_CH; i = i + 1) begin
                next_ptr_r[i]        <= 32'h0;
                desc_src_addr[i*32 +: 32] <= 32'h0;
                desc_dst_addr[i*32 +: 32] <= 32'h0;
                desc_xfer_len[i*32 +: 32] <= 32'h0;
                desc_burst_len[i*8 +: 8]  <= 8'hF;
                desc_last[i]              <= 1'b0;
                desc_next_ptr[i*32 +: 32] <= 32'h0;
            end
        end else begin
            fetch_done <= {NUM_CH{1'b0}};  // default: pulse for 1 cycle only

            case (state)
                // --------------------------------------------------------
                ST_IDLE: begin
                    // Simple round-robin arbitration for descriptor fetch
                    if (|fetch_req) begin
                        state <= ST_ARB;
                    end
                end

                // --------------------------------------------------------
                ST_ARB: begin
                    // Find lowest requesting channel
                    begin : arb_block
                        integer ch;
                        reg found;
                        found = 1'b0;
                        for (ch = 0; ch < NUM_CH; ch = ch + 1) begin
                            if (!found && fetch_req[ch] && ch_sg_mode[ch]) begin
                                active_ch <= ch[$clog2(NUM_CH)-1:0];
                                found = 1'b1;
                            end
                        end
                    end
                    state <= ST_ARADDR;
                end

                // --------------------------------------------------------
                ST_ARADDR: begin
                    // Determine descriptor address:
                    // If next_ptr==0, use ch_desc_base (first fetch), else use next_ptr
                    cur_ptr <= (next_ptr_r[active_ch] == 32'h0) ?
                                ch_desc_base[active_ch*32 +: 32] :
                                next_ptr_r[active_ch];
                    m_axi_araddr  <= (next_ptr_r[active_ch] == 32'h0) ?
                                      ch_desc_base[active_ch*32 +: 32] :
                                      next_ptr_r[active_ch];
                    m_axi_arlen   <= 8'h3;      // 4 x 64-bit = 32 bytes (descriptor)
                    m_axi_arvalid <= 1'b1;
                    word_idx      <= 3'h0;
                    if (m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        state         <= ST_RDATA;
                    end
                end

                // --------------------------------------------------------
                ST_RDATA: begin
                    if (m_axi_rvalid) begin
                        // Capture each 64-bit word; split into two 32-bit halves
                        raw_word[{word_idx, 1'b0}]   <= m_axi_rdata[31:0];
                        raw_word[{word_idx, 1'b1}]   <= m_axi_rdata[63:32];
                        word_idx <= word_idx + 3'h1;
                        if (m_axi_rlast) begin
                            m_axi_rready <= 1'b0;
                            state        <= ST_DECODE;
                        end
                        if (m_axi_rresp != 2'b00) begin
                            // Error during descriptor fetch
                            m_axi_rready <= 1'b0;
                            state        <= ST_IDLE;
                        end
                    end
                end

                // --------------------------------------------------------
                ST_DECODE: begin
                    // Parse descriptor fields from raw_word array
                    // Word 0: Next Descriptor Pointer
                    desc_next_ptr[active_ch*32 +: 32] <= raw_word[0];
                    next_ptr_r[active_ch]              <= raw_word[0];
                    // Word 1: Source Address
                    desc_src_addr[active_ch*32 +: 32] <= raw_word[2];
                    // Word 2: Destination Address
                    desc_dst_addr[active_ch*32 +: 32] <= raw_word[4];
                    // Word 3: Transfer Length
                    desc_xfer_len[active_ch*32 +: 32] <= raw_word[6];
                    // Word 4: Control fields
                    desc_burst_len[active_ch*8 +: 8]  <= raw_word[8][7:0];
                    // LAST flag: set if next pointer is 0 OR LAST bit set
                    desc_last[active_ch]               <= raw_word[8][11] | (raw_word[0] == 32'h0);
                    state <= ST_DONE;
                end

                // --------------------------------------------------------
                ST_DONE: begin
                    fetch_done[active_ch] <= 1'b1;
                    // Reset next_ptr if this was the last descriptor
                    if (desc_last[active_ch])
                        next_ptr_r[active_ch] <= 32'h0;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // =========================================================================
    // raw_word initialization
    // =========================================================================
    integer k;
    initial begin
        for (k = 0; k < 8; k = k + 1)
            raw_word[k] = 32'h0;
    end

endmodule
