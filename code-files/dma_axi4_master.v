`timescale 1ns / 1ps

module dma_axi4_master #(
    parameter NUM_CH     = 4,
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 32,
    parameter ID_WIDTH   = 4,
    parameter STRB_WIDTH = DATA_WIDTH / 8
)(
    input  wire                         aclk,
    input  wire                         aresetn,

    // --- From Arbiter ---
    input  wire [$clog2(NUM_CH)-1:0]    rd_active_ch,
    input  wire [$clog2(NUM_CH)-1:0]    wr_active_ch,
    input  wire                         rd_busy,
    input  wire                         wr_busy,

    // --- Channel request/grant buses ---
    input  wire [NUM_CH-1:0]            ch_rd_req,
    input  wire [NUM_CH-1:0]            ch_rd_gnt,
    input  wire [NUM_CH-1:0]            ch_wr_req,
    input  wire [NUM_CH-1:0]            ch_wr_gnt,

    // --- Channel parameters (flat bus, indexed by active channel) ---
    input  wire [NUM_CH*32-1:0]         ch_src_addr,
    input  wire [NUM_CH*32-1:0]         ch_dst_addr,
    input  wire [NUM_CH*32-1:0]         ch_xfer_len,
    input  wire [NUM_CH*8-1:0]          ch_burst_len,
    input  wire [NUM_CH*3-1:0]          ch_burst_size,

    // --- Per-channel FIFO write ports (read engine → FIFO) ---
    output reg  [NUM_CH-1:0]            fifo_wr_en,
    output reg  [NUM_CH*DATA_WIDTH-1:0] fifo_wr_data,
    output reg  [NUM_CH*STRB_WIDTH-1:0] fifo_wr_strb,
    input  wire [NUM_CH-1:0]            fifo_wr_full,

    // --- Per-channel FIFO read ports (FIFO → write engine) ---
    output reg  [NUM_CH-1:0]            fifo_rd_en,
    input  wire [NUM_CH*DATA_WIDTH-1:0] fifo_rd_data,
    input  wire [NUM_CH*STRB_WIDTH-1:0] fifo_rd_strb,
    input  wire [NUM_CH-1:0]            fifo_rd_empty,

    // --- Descriptor engine AXI AR/R port ---
    input  wire [ADDR_WIDTH-1:0]        desc_axi_araddr,
    input  wire [7:0]                   desc_axi_arlen,
    input  wire                         desc_axi_arvalid,
    output wire                         desc_axi_arready,
    output wire [DATA_WIDTH-1:0]        desc_axi_rdata,
    output wire [1:0]                   desc_axi_rresp,
    output wire                         desc_axi_rlast,
    output wire                         desc_axi_rvalid,
    input  wire                         desc_axi_rready,

    // --- AXI4 Master Interface ---
    output reg  [ID_WIDTH-1:0]          m_axi_awid,
    output reg  [ADDR_WIDTH-1:0]        m_axi_awaddr,
    output reg  [7:0]                   m_axi_awlen,
    output reg  [2:0]                   m_axi_awsize,
    output reg  [1:0]                   m_axi_awburst,
    output reg                          m_axi_awlock,
    output reg  [3:0]                   m_axi_awcache,
    output reg  [2:0]                   m_axi_awprot,
    output reg  [3:0]                   m_axi_awqos,
    output reg                          m_axi_awvalid,
    input  wire                         m_axi_awready,

    output reg  [DATA_WIDTH-1:0]        m_axi_wdata,
    output reg  [STRB_WIDTH-1:0]        m_axi_wstrb,
    output reg                          m_axi_wlast,
    output reg                          m_axi_wvalid,
    input  wire                         m_axi_wready,

    input  wire [ID_WIDTH-1:0]          m_axi_bid,
    input  wire [1:0]                   m_axi_bresp,
    input  wire                         m_axi_bvalid,
    output reg                          m_axi_bready,

    output reg  [ID_WIDTH-1:0]          m_axi_arid,
    output reg  [ADDR_WIDTH-1:0]        m_axi_araddr,
    output reg  [7:0]                   m_axi_arlen,
    output reg  [2:0]                   m_axi_arsize,
    output reg  [1:0]                   m_axi_arburst,
    output reg                          m_axi_arlock,
    output reg  [3:0]                   m_axi_arcache,
    output reg  [2:0]                   m_axi_arprot,
    output reg  [3:0]                   m_axi_arqos,
    output reg                          m_axi_arvalid,
    input  wire                         m_axi_arready,

    input  wire [ID_WIDTH-1:0]          m_axi_rid,
    input  wire [DATA_WIDTH-1:0]        m_axi_rdata,
    input  wire [1:0]                   m_axi_rresp,
    input  wire                         m_axi_rlast,
    input  wire                         m_axi_rvalid,
    output reg                          m_axi_rready
);

    // =========================================================================
    // Read FSM States
    // =========================================================================
    localparam [2:0]
        RD_IDLE    = 3'd0,
        RD_DESC    = 3'd1,     // descriptor fetch priority
        RD_ARADDR  = 3'd2,     // issue AR channel
        RD_RDATA   = 3'd3,     // receive R channel data → FIFO
        RD_DONE    = 3'd4;

    // Write FSM States
    localparam [2:0]
        WR_IDLE    = 3'd0,
        WR_AWADDR  = 3'd1,     // issue AW channel
        WR_WDATA   = 3'd2,     // drive W channel from FIFO
        WR_BRESP   = 3'd3,     // wait for B channel response
        WR_DONE    = 3'd4;

    // =========================================================================
    // Read Engine Registers
    // =========================================================================
    reg [2:0]                   rd_state;
    reg [$clog2(NUM_CH)-1:0]    rd_ch;          // active read channel
    reg [ADDR_WIDTH-1:0]        rd_addr;         // current burst address
    reg [31:0]                  rd_rem;          // bytes remaining to read
    reg [7:0]                   rd_beat_cnt;     // beats in current burst
    reg [7:0]                   rd_burst_len;    // latched burst len
    reg [2:0]                   rd_burst_size;   // latched burst size
    reg                         rd_desc_pending; // descriptor fetch waiting

    // =========================================================================
    // Write Engine Registers
    // =========================================================================
    reg [2:0]                   wr_state;
    reg [$clog2(NUM_CH)-1:0]    wr_ch;           // active write channel
    reg [ADDR_WIDTH-1:0]        wr_addr;          // current burst address
    reg [31:0]                  wr_rem;           // bytes remaining to write
    reg [7:0]                   wr_beat_cnt;      // beats in current burst
    reg [7:0]                   wr_burst_len;     // latched burst len
    reg [2:0]                   wr_burst_size;    // latched burst size
    reg                         wr_aw_issued;     // AW handshake done

    // =========================================================================
    // Descriptor port mux: descriptor fetch gets AR channel priority
    // =========================================================================
    // When rd_state == RD_DESC, AR channel is driven from descriptor engine.
    assign desc_axi_arready = (rd_state == RD_DESC) ? m_axi_arready  : 1'b0;
    assign desc_axi_rdata   = (rd_state == RD_DESC) ? m_axi_rdata    : {DATA_WIDTH{1'b0}};
    assign desc_axi_rresp   = (rd_state == RD_DESC) ? m_axi_rresp    : 2'b00;
    assign desc_axi_rlast   = (rd_state == RD_DESC) ? m_axi_rlast    : 1'b0;
    assign desc_axi_rvalid  = (rd_state == RD_DESC) ? m_axi_rvalid   : 1'b0;

    // =========================================================================
    // Read Engine FSM
    // =========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_state       <= RD_IDLE;
            rd_ch          <= {$clog2(NUM_CH){1'b0}};
            rd_addr        <= {ADDR_WIDTH{1'b0}};
            rd_rem         <= 32'h0;
            rd_beat_cnt    <= 8'h0;
            rd_burst_len   <= 8'hF;
            rd_burst_size  <= 3'h3;
            rd_desc_pending<= 1'b0;
            m_axi_arvalid  <= 1'b0;
            m_axi_arid     <= {ID_WIDTH{1'b0}};
            m_axi_araddr   <= {ADDR_WIDTH{1'b0}};
            m_axi_arlen    <= 8'h0;
            m_axi_arsize   <= 3'h3;
            m_axi_arburst  <= 2'b01; // INCR
            m_axi_arlock   <= 1'b0;
            m_axi_arcache  <= 4'b0011; // cacheable, bufferable
            m_axi_arprot   <= 3'b000;
            m_axi_arqos    <= 4'h0;
            m_axi_rready   <= 1'b0;
            fifo_wr_en     <= {NUM_CH{1'b0}};
            fifo_wr_data   <= {NUM_CH*DATA_WIDTH{1'b0}};
            fifo_wr_strb   <= {NUM_CH*STRB_WIDTH{1'b0}};
        end else begin
            // Default: clear pulse signals
            fifo_wr_en <= {NUM_CH{1'b0}};

            case (rd_state)
                // --------------------------------------------------------
                RD_IDLE: begin
                    // Descriptor fetch has highest priority
                    if (desc_axi_arvalid) begin
                        rd_state <= RD_DESC;
                    end else if (rd_busy && |ch_rd_gnt) begin
                        rd_ch         <= rd_active_ch;
                        rd_addr       <= ch_src_addr[rd_active_ch*32 +: 32];
                        rd_rem        <= ch_xfer_len[rd_active_ch*32 +: 32];
                        rd_burst_len  <= ch_burst_len[rd_active_ch*8 +: 8];
                        rd_burst_size <= ch_burst_size[rd_active_ch*3 +: 3];
                        rd_beat_cnt   <= 8'h0;
                        rd_state      <= RD_ARADDR;
                    end
                end

                // --------------------------------------------------------
                RD_DESC: begin
                    // Forward descriptor engine AR request
                    m_axi_arvalid <= desc_axi_arvalid;
                    m_axi_araddr  <= desc_axi_araddr;
                    m_axi_arlen   <= desc_axi_arlen;
                    m_axi_arsize  <= 3'h3;
                    m_axi_arburst <= 2'b01;
                    m_axi_arid    <= {ID_WIDTH{1'b1}}; // descriptor ID = all-ones
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                    end
                    // Forward R data back to descriptor engine
                    if (m_axi_rvalid && m_axi_rready && m_axi_rlast) begin
                        m_axi_rready <= 1'b0;
                        rd_state     <= RD_IDLE;
                    end
                end

                // --------------------------------------------------------
                RD_ARADDR: begin
                    // Issue AXI AR with current burst parameters
                    // Clamp burst to remaining bytes
                    begin : rd_ar_compute
                        reg [7:0] blen;
                        reg [31:0] burst_bytes;
                        burst_bytes = (32'd1 << rd_burst_size) * (32'(rd_burst_len) + 32'd1);
                        if (rd_rem <= burst_bytes)
                            blen = ((rd_rem + (32'd1 << rd_burst_size) - 1) >> rd_burst_size) - 1;
                        else
                            blen = rd_burst_len;
                        m_axi_araddr  <= rd_addr;
                        m_axi_arlen   <= blen;
                        m_axi_arsize  <= rd_burst_size;
                        m_axi_arburst <= 2'b01; // INCR
                        m_axi_arid    <= {{(ID_WIDTH-$clog2(NUM_CH)){1'b0}}, rd_ch};
                        m_axi_arlock  <= 1'b0;
                        m_axi_arcache <= 4'b0011;
                        m_axi_arvalid <= 1'b1;
                        rd_beat_cnt   <= blen;
                    end
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        rd_state      <= RD_RDATA;
                    end
                end

                // --------------------------------------------------------
                RD_RDATA: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        // Write beat to the active channel's FIFO
                        if (!fifo_wr_full[rd_ch]) begin
                            fifo_wr_en[rd_ch]                          <= 1'b1;
                            fifo_wr_data[rd_ch*DATA_WIDTH +: DATA_WIDTH] <= m_axi_rdata;
                            fifo_wr_strb[rd_ch*STRB_WIDTH +: STRB_WIDTH] <= {STRB_WIDTH{1'b1}};
                            // Advance address
                            rd_addr <= rd_addr + (1 << rd_burst_size);
                            // Decrement remaining
                            if (rd_rem >= (1 << rd_burst_size))
                                rd_rem <= rd_rem - (1 << rd_burst_size);
                            else
                                rd_rem <= 32'h0;
                        end
                        if (m_axi_rlast) begin
                            m_axi_rready <= 1'b0;
                            if (rd_rem <= (1 << rd_burst_size))
                                rd_state <= RD_DONE;
                            else
                                rd_state <= RD_ARADDR; // more bursts needed
                        end
                    end
                    // Backpressure: hold rready if FIFO is full
                    if (fifo_wr_full[rd_ch])
                        m_axi_rready <= 1'b0;
                    else if (rd_state == RD_RDATA)
                        m_axi_rready <= 1'b1;
                end

                // --------------------------------------------------------
                RD_DONE: begin
                    rd_state <= RD_IDLE;
                end

                default: rd_state <= RD_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Write Engine FSM
    // =========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_state      <= WR_IDLE;
            wr_ch         <= {$clog2(NUM_CH){1'b0}};
            wr_addr       <= {ADDR_WIDTH{1'b0}};
            wr_rem        <= 32'h0;
            wr_beat_cnt   <= 8'h0;
            wr_burst_len  <= 8'hF;
            wr_burst_size <= 3'h3;
            wr_aw_issued  <= 1'b0;
            m_axi_awvalid <= 1'b0;
            m_axi_awid    <= {ID_WIDTH{1'b0}};
            m_axi_awaddr  <= {ADDR_WIDTH{1'b0}};
            m_axi_awlen   <= 8'h0;
            m_axi_awsize  <= 3'h3;
            m_axi_awburst <= 2'b01;
            m_axi_awlock  <= 1'b0;
            m_axi_awcache <= 4'b0011;
            m_axi_awprot  <= 3'b000;
            m_axi_awqos   <= 4'h0;
            m_axi_wvalid  <= 1'b0;
            m_axi_wdata   <= {DATA_WIDTH{1'b0}};
            m_axi_wstrb   <= {STRB_WIDTH{1'b1}};
            m_axi_wlast   <= 1'b0;
            m_axi_bready  <= 1'b0;
            fifo_rd_en    <= {NUM_CH{1'b0}};
        end else begin
            // Default: clear pulse signals
            fifo_rd_en <= {NUM_CH{1'b0}};

            case (wr_state)
                // --------------------------------------------------------
                WR_IDLE: begin
                    wr_aw_issued <= 1'b0;
                    if (wr_busy && |ch_wr_gnt) begin
                        wr_ch         <= wr_active_ch;
                        wr_addr       <= ch_dst_addr[wr_active_ch*32 +: 32];
                        wr_rem        <= ch_xfer_len[wr_active_ch*32 +: 32];
                        wr_burst_len  <= ch_burst_len[wr_active_ch*8 +: 8];
                        wr_burst_size <= ch_burst_size[wr_active_ch*3 +: 3];
                        wr_beat_cnt   <= 8'h0;
                        wr_state      <= WR_AWADDR;
                    end
                end

                // --------------------------------------------------------
                WR_AWADDR: begin
                    // Wait until FIFO has enough data before issuing AW
                    if (!fifo_rd_empty[wr_ch]) begin
                        begin : wr_aw_compute
                            reg [7:0] blen;
                            reg [31:0] burst_bytes;
                            burst_bytes = (32'd1 << wr_burst_size) * (32'(wr_burst_len) + 32'd1);
                            if (wr_rem <= burst_bytes)
                                blen = ((wr_rem + (32'd1 << wr_burst_size) - 1) >> wr_burst_size) - 1;
                            else
                                blen = wr_burst_len;
                            m_axi_awaddr  <= wr_addr;
                            m_axi_awlen   <= blen;
                            m_axi_awsize  <= wr_burst_size;
                            m_axi_awburst <= 2'b01; // INCR
                            m_axi_awid    <= {{(ID_WIDTH-$clog2(NUM_CH)){1'b0}}, wr_ch};
                            m_axi_awlock  <= 1'b0;
                            m_axi_awcache <= 4'b0011;
                            m_axi_awvalid <= 1'b1;
                            wr_beat_cnt   <= blen;
                        end
                        if (m_axi_awvalid && m_axi_awready) begin
                            m_axi_awvalid <= 1'b0;
                            wr_aw_issued  <= 1'b1;
                            wr_state      <= WR_WDATA;
                        end
                    end
                end

                // --------------------------------------------------------
                WR_WDATA: begin
                    if (!fifo_rd_empty[wr_ch]) begin
                        m_axi_wvalid <= 1'b1;
                        m_axi_wdata  <= fifo_rd_data[wr_ch*DATA_WIDTH +: DATA_WIDTH];
                        m_axi_wstrb  <= fifo_rd_strb[wr_ch*STRB_WIDTH +: STRB_WIDTH];
                        m_axi_wlast  <= (wr_beat_cnt == 8'h0);
                        if (m_axi_wvalid && m_axi_wready) begin
                            // Pop FIFO
                            fifo_rd_en[wr_ch] <= 1'b1;
                            // Advance tracking
                            wr_addr <= wr_addr + (1 << wr_burst_size);
                            if (wr_rem >= (1 << wr_burst_size))
                                wr_rem <= wr_rem - (1 << wr_burst_size);
                            else
                                wr_rem <= 32'h0;
                            if (wr_beat_cnt > 0)
                                wr_beat_cnt <= wr_beat_cnt - 1;
                            if (m_axi_wlast) begin
                                m_axi_wvalid <= 1'b0;
                                wr_state     <= WR_BRESP;
                            end
                        end
                    end else begin
                        // Stall W channel if FIFO empty
                        m_axi_wvalid <= 1'b0;
                    end
                end

                // --------------------------------------------------------
                WR_BRESP: begin
                    m_axi_bready <= 1'b1;
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;
                        wr_aw_issued <= 1'b0;
                        if (wr_rem == 32'h0)
                            wr_state <= WR_DONE;
                        else
                            wr_state <= WR_AWADDR; // next burst
                    end
                end

                // --------------------------------------------------------
                WR_DONE: begin
                    wr_state <= WR_IDLE;
                end

                default: wr_state <= WR_IDLE;
            endcase
        end
    end

endmodule
