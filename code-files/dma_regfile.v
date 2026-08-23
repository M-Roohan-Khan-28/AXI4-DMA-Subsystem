`timescale 1ns / 1ps

module dma_regfile #(
    parameter NUM_CH = 4
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    // AXI4-Lite Slave Interface
    input  wire [31:0]          s_awaddr,
    input  wire                 s_awvalid,
    output reg                  s_awready,
    input  wire [31:0]          s_wdata,
    input  wire [3:0]           s_wstrb,
    input  wire                 s_wvalid,
    output reg                  s_wready,
    output reg  [1:0]           s_bresp,
    output reg                  s_bvalid,
    input  wire                 s_bready,
    input  wire [31:0]          s_araddr,
    input  wire                 s_arvalid,
    output reg                  s_arready,
    output reg  [31:0]          s_rdata,
    output reg  [1:0]           s_rresp,
    output reg                  s_rvalid,
    input  wire                 s_rready,

    // Configuration outputs
    output reg  [NUM_CH-1:0]    ch_enable,
    output reg  [NUM_CH-1:0]    ch_sg_mode,
    output reg  [NUM_CH-1:0]    ch_irq_en,
    output reg  [1:0]           arb_mode,
    output reg  [NUM_CH*32-1:0] ch_src_addr,
    output reg  [NUM_CH*32-1:0] ch_dst_addr,
    output reg  [NUM_CH*32-1:0] ch_xfer_len,
    output reg  [NUM_CH*32-1:0] ch_desc_base,
    output reg  [NUM_CH*8-1:0]  ch_burst_len,
    output reg  [NUM_CH*3-1:0]  ch_burst_size,
    output reg  [NUM_CH*2-1:0]  ch_src_inc,
    output reg  [NUM_CH*2-1:0]  ch_dst_inc,

    // Status inputs from channels
    input  wire [NUM_CH-1:0]    ch_busy,
    input  wire [NUM_CH-1:0]    ch_done,
    input  wire [NUM_CH-1:0]    ch_err,
    input  wire [NUM_CH*32-1:0] ch_bytes_xfered,
    input  wire [NUM_CH*32-1:0] ch_cur_src,
    input  wire [NUM_CH*32-1:0] ch_cur_dst
);

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam RESP_OKAY   = 2'b00;
    localparam RESP_SLVERR = 2'b10;

    // Global register offsets
    localparam ADDR_DMA_CTRL       = 12'h000;
    localparam ADDR_DMA_STATUS     = 12'h004;
    localparam ADDR_DMA_IRQ_STATUS = 12'h008;
    localparam ADDR_DMA_IRQ_MASK   = 12'h00C;

    // Per-channel stride and base
    localparam CH_STRIDE = 12'h040;
    localparam CH_BASE   = 12'h100;

    // Per-channel offsets
    localparam CH_OFF_CTRL       = 6'h00;
    localparam CH_OFF_STATUS     = 6'h04;
    localparam CH_OFF_SRC_ADDR   = 6'h08;
    localparam CH_OFF_DST_ADDR   = 6'h0C;
    localparam CH_OFF_XFER_LEN   = 6'h10;
    localparam CH_OFF_DESC_BASE  = 6'h14;
    localparam CH_OFF_BURST      = 6'h18;
    localparam CH_OFF_BYTES_DONE = 6'h1C;
    localparam CH_OFF_CUR_SRC    = 6'h20;
    localparam CH_OFF_CUR_DST    = 6'h24;

    // =========================================================================
    // Internal Registers
    // =========================================================================
    reg [31:0]  global_ctrl;        // [1:0]=arb_mode, [2]=global_reset
    reg [31:0]  irq_mask;
    reg [31:0]  irq_status;         // W1C

    // AXI handshake state
    reg [31:0]  aw_addr_latch;
    reg         aw_done;
    reg         w_done;
    reg [31:0]  w_data_latch;
    reg [3:0]   w_strb_latch;

    integer j;

    // =========================================================================
    // Write Address Channel
    // =========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_awready   <= 1'b1;
            aw_done     <= 1'b0;
            aw_addr_latch <= 32'h0;
        end else begin
            if (s_awvalid && s_awready) begin
                aw_addr_latch <= s_awaddr;
                s_awready     <= 1'b0;
                aw_done       <= 1'b1;
            end else if (s_bvalid && s_bready) begin
                s_awready <= 1'b1;
                aw_done   <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Write Data Channel
    // =========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_wready     <= 1'b1;
            w_done       <= 1'b0;
            w_data_latch <= 32'h0;
            w_strb_latch <= 4'h0;
        end else begin
            if (s_wvalid && s_wready) begin
                w_data_latch <= s_wdata;
                w_strb_latch <= s_wstrb;
                s_wready     <= 1'b0;
                w_done       <= 1'b1;
            end else if (s_bvalid && s_bready) begin
                s_wready <= 1'b1;
                w_done   <= 1'b0;
            end
        end
    end

    // Helper function: apply write strobe
    function [31:0] apply_strobe;
        input [31:0] orig;
        input [31:0] wdata;
        input [3:0]  wstrb;
        integer k;
        begin
            apply_strobe = orig;
            for (k = 0; k < 4; k = k + 1)
                if (wstrb[k]) apply_strobe[k*8 +: 8] = wdata[k*8 +: 8];
        end
    endfunction

    // =========================================================================
    // Write Response & Register Write
    // =========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_bvalid      <= 1'b0;
            s_bresp       <= RESP_OKAY;
            global_ctrl   <= 32'h0;
            irq_mask      <= 32'hFFFFFFFF;
            irq_status    <= 32'h0;
            ch_enable     <= {NUM_CH{1'b0}};
            ch_sg_mode    <= {NUM_CH{1'b0}};
            ch_irq_en     <= {NUM_CH{1'b0}};
            arb_mode      <= 2'b00;
            for (j = 0; j < NUM_CH; j = j + 1) begin
                ch_src_addr[j*32 +: 32]   <= 32'h0;
                ch_dst_addr[j*32 +: 32]   <= 32'h0;
                ch_xfer_len[j*32 +: 32]   <= 32'h0;
                ch_desc_base[j*32 +: 32]  <= 32'h0;
                ch_burst_len[j*8 +: 8]    <= 8'hF; // default 16-beat burst
                ch_burst_size[j*3 +: 3]   <= 3'h3; // default 8-byte size
                ch_src_inc[j*2 +: 2]      <= 2'b01; // auto-increment
                ch_dst_inc[j*2 +: 2]      <= 2'b01;
            end
        end else begin
            // Update IRQ status from hardware
            irq_status <= irq_status | (ch_done & ch_irq_en) | (ch_err & ch_irq_en);

            if (aw_done && w_done && !s_bvalid) begin
                s_bvalid <= 1'b1;
                s_bresp  <= RESP_OKAY;

                // Decode address
                if (aw_addr_latch[11:0] == ADDR_DMA_CTRL) begin
                    global_ctrl <= apply_strobe(global_ctrl, w_data_latch, w_strb_latch);
                    arb_mode    <= apply_strobe(global_ctrl, w_data_latch, w_strb_latch)[1:0];
                end else if (aw_addr_latch[11:0] == ADDR_DMA_IRQ_STATUS) begin
                    // W1C: clear bits where wdata=1
                    irq_status <= irq_status & ~w_data_latch;
                end else if (aw_addr_latch[11:0] == ADDR_DMA_IRQ_MASK) begin
                    irq_mask <= apply_strobe(irq_mask, w_data_latch, w_strb_latch);
                end else begin
                    // Per-channel registers
                    if (aw_addr_latch[11:8] >= 4'h1) begin
                        // Channel index
                        begin : ch_write_decode
                            integer ch;
                            reg [11:0] ch_off;
                            for (ch = 0; ch < NUM_CH; ch = ch + 1) begin
                                if (aw_addr_latch[11:0] >= (CH_BASE + ch*CH_STRIDE) &&
                                    aw_addr_latch[11:0] <  (CH_BASE + ch*CH_STRIDE + CH_STRIDE)) begin
                                    ch_off = aw_addr_latch[11:0] - (CH_BASE + ch*CH_STRIDE);
                                    case (ch_off[5:0])
                                        CH_OFF_CTRL: begin
                                            if (w_strb_latch[0]) begin
                                                ch_enable[ch]  <= w_data_latch[0];
                                                ch_sg_mode[ch] <= w_data_latch[1];
                                                ch_irq_en[ch]  <= w_data_latch[2];
                                                ch_src_inc[ch*2 +: 2] <= w_data_latch[4:3];
                                                ch_dst_inc[ch*2 +: 2] <= w_data_latch[6:5];
                                            end
                                        end
                                        CH_OFF_SRC_ADDR:
                                            ch_src_addr[ch*32 +: 32]  <= apply_strobe(ch_src_addr[ch*32 +: 32],  w_data_latch, w_strb_latch);
                                        CH_OFF_DST_ADDR:
                                            ch_dst_addr[ch*32 +: 32]  <= apply_strobe(ch_dst_addr[ch*32 +: 32],  w_data_latch, w_strb_latch);
                                        CH_OFF_XFER_LEN:
                                            ch_xfer_len[ch*32 +: 32]  <= apply_strobe(ch_xfer_len[ch*32 +: 32],  w_data_latch, w_strb_latch);
                                        CH_OFF_DESC_BASE:
                                            ch_desc_base[ch*32 +: 32] <= apply_strobe(ch_desc_base[ch*32 +: 32], w_data_latch, w_strb_latch);
                                        CH_OFF_BURST: begin
                                            if (w_strb_latch[0]) ch_burst_len[ch*8 +: 8]  <= w_data_latch[7:0];
                                            if (w_strb_latch[1]) ch_burst_size[ch*3 +: 3] <= w_data_latch[10:8];
                                        end
                                        default: s_bresp <= RESP_SLVERR;
                                    endcase
                                end
                            end
                        end
                    end else begin
                        s_bresp <= RESP_SLVERR;
                    end
                end
            end else if (s_bvalid && s_bready) begin
                s_bvalid <= 1'b0;
                s_bresp  <= RESP_OKAY;
            end
        end
    end

    // =========================================================================
    // Read Channel
    // =========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_arready <= 1'b1;
            s_rvalid  <= 1'b0;
            s_rdata   <= 32'h0;
            s_rresp   <= RESP_OKAY;
        end else begin
            if (s_arvalid && s_arready) begin
                s_arready <= 1'b0;
                s_rvalid  <= 1'b1;
                s_rresp   <= RESP_OKAY;

                // Global registers
                if (s_araddr[11:0] == ADDR_DMA_CTRL) begin
                    s_rdata <= global_ctrl;
                end else if (s_araddr[11:0] == ADDR_DMA_STATUS) begin
                    s_rdata <= {28'h0, ch_err[3:0]};
                end else if (s_araddr[11:0] == ADDR_DMA_IRQ_STATUS) begin
                    s_rdata <= irq_status;
                end else if (s_araddr[11:0] == ADDR_DMA_IRQ_MASK) begin
                    s_rdata <= irq_mask;
                end else begin
                    // Per-channel read
                    begin : ch_read_decode
                        integer ch;
                        reg [11:0] ch_off;
                        reg found;
                        found = 1'b0;
                        for (ch = 0; ch < NUM_CH; ch = ch + 1) begin
                            if (!found &&
                                s_araddr[11:0] >= (CH_BASE + ch*CH_STRIDE) &&
                                s_araddr[11:0] <  (CH_BASE + ch*CH_STRIDE + CH_STRIDE)) begin
                                found  = 1'b1;
                                ch_off = s_araddr[11:0] - (CH_BASE + ch*CH_STRIDE);
                                case (ch_off[5:0])
                                    CH_OFF_CTRL:
                                        s_rdata <= {25'h0,
                                                    ch_dst_inc[ch*2 +: 2],
                                                    ch_src_inc[ch*2 +: 2],
                                                    ch_irq_en[ch],
                                                    ch_sg_mode[ch],
                                                    ch_enable[ch]};
                                    CH_OFF_STATUS:
                                        s_rdata <= {29'h0, ch_err[ch], ch_done[ch], ch_busy[ch]};
                                    CH_OFF_SRC_ADDR:
                                        s_rdata <= ch_src_addr[ch*32 +: 32];
                                    CH_OFF_DST_ADDR:
                                        s_rdata <= ch_dst_addr[ch*32 +: 32];
                                    CH_OFF_XFER_LEN:
                                        s_rdata <= ch_xfer_len[ch*32 +: 32];
                                    CH_OFF_DESC_BASE:
                                        s_rdata <= ch_desc_base[ch*32 +: 32];
                                    CH_OFF_BURST:
                                        s_rdata <= {21'h0, ch_burst_size[ch*3 +: 3], ch_burst_len[ch*8 +: 8]};
                                    CH_OFF_BYTES_DONE:
                                        s_rdata <= ch_bytes_xfered[ch*32 +: 32];
                                    CH_OFF_CUR_SRC:
                                        s_rdata <= ch_cur_src[ch*32 +: 32];
                                    CH_OFF_CUR_DST:
                                        s_rdata <= ch_cur_dst[ch*32 +: 32];
                                    default: begin
                                        s_rdata <= 32'hDEADBEEF;
                                        s_rresp <= RESP_SLVERR;
                                    end
                                endcase
                            end
                        end
                        if (!found) begin
                            s_rdata <= 32'hDEADBEEF;
                            s_rresp <= RESP_SLVERR;
                        end
                    end
                end
            end else if (s_rvalid && s_rready) begin
                s_rvalid  <= 1'b0;
                s_arready <= 1'b1;
            end
        end
    end

endmodule
