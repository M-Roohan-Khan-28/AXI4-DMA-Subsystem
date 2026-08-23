`timescale 1ns / 1ps

module dma_top #(
    parameter NUM_CH     = 4,
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 32,
    parameter ID_WIDTH   = 4,
    parameter FIFO_DEPTH = 512,
    parameter STRB_WIDTH = DATA_WIDTH / 8
)(
    // -------------------------------------------------------------------------
    // Global Signals
    // -------------------------------------------------------------------------
    input  wire                     aclk,
    input  wire                     aresetn,

    // -------------------------------------------------------------------------
    // AXI4-Lite Slave Interface (Configuration / CSR)
    // -------------------------------------------------------------------------
    // Write Address Channel
    input  wire [31:0]              s_axil_awaddr,
    input  wire                     s_axil_awvalid,
    output wire                     s_axil_awready,
    // Write Data Channel
    input  wire [31:0]              s_axil_wdata,
    input  wire [3:0]               s_axil_wstrb,
    input  wire                     s_axil_wvalid,
    output wire                     s_axil_wready,
    // Write Response Channel
    output wire [1:0]               s_axil_bresp,
    output wire                     s_axil_bvalid,
    input  wire                     s_axil_bready,
    // Read Address Channel
    input  wire [31:0]              s_axil_araddr,
    input  wire                     s_axil_arvalid,
    output wire                     s_axil_arready,
    // Read Data Channel
    output wire [31:0]              s_axil_rdata,
    output wire [1:0]               s_axil_rresp,
    output wire                     s_axil_rvalid,
    input  wire                     s_axil_rready,

    // -------------------------------------------------------------------------
    // AXI4 Master Interface (Memory Read/Write)
    // -------------------------------------------------------------------------
    // Write Address Channel
    output wire [ID_WIDTH-1:0]      m_axi_awid,
    output wire [ADDR_WIDTH-1:0]    m_axi_awaddr,
    output wire [7:0]               m_axi_awlen,
    output wire [2:0]               m_axi_awsize,
    output wire [1:0]               m_axi_awburst,
    output wire                     m_axi_awlock,
    output wire [3:0]               m_axi_awcache,
    output wire [2:0]               m_axi_awprot,
    output wire [3:0]               m_axi_awqos,
    output wire                     m_axi_awvalid,
    input  wire                     m_axi_awready,
    // Write Data Channel
    output wire [DATA_WIDTH-1:0]    m_axi_wdata,
    output wire [STRB_WIDTH-1:0]    m_axi_wstrb,
    output wire                     m_axi_wlast,
    output wire                     m_axi_wvalid,
    input  wire                     m_axi_wready,
    // Write Response Channel
    input  wire [ID_WIDTH-1:0]      m_axi_bid,
    input  wire [1:0]               m_axi_bresp,
    input  wire                     m_axi_bvalid,
    output wire                     m_axi_bready,
    // Read Address Channel
    output wire [ID_WIDTH-1:0]      m_axi_arid,
    output wire [ADDR_WIDTH-1:0]    m_axi_araddr,
    output wire [7:0]               m_axi_arlen,
    output wire [2:0]               m_axi_arsize,
    output wire [1:0]               m_axi_arburst,
    output wire                     m_axi_arlock,
    output wire [3:0]               m_axi_arcache,
    output wire [2:0]               m_axi_arprot,
    output wire [3:0]               m_axi_arqos,
    output wire                     m_axi_arvalid,
    input  wire                     m_axi_arready,
    // Read Data Channel
    input  wire [ID_WIDTH-1:0]      m_axi_rid,
    input  wire [DATA_WIDTH-1:0]    m_axi_rdata,
    input  wire [1:0]               m_axi_rresp,
    input  wire                     m_axi_rlast,
    input  wire                     m_axi_rvalid,
    output wire                     m_axi_rready,

    // -------------------------------------------------------------------------
    // DMA Flow Control (per-channel peripheral handshake)
    // -------------------------------------------------------------------------
    input  wire [NUM_CH-1:0]        dma_req,       // peripheral requests transfer
    output wire [NUM_CH-1:0]        dma_ack,       // DMA acknowledges request
    input  wire [NUM_CH-1:0]        dma_done_ext,  // external done signal (optional)

    // -------------------------------------------------------------------------
    // Interrupt Output
    // -------------------------------------------------------------------------
    output wire [NUM_CH-1:0]        irq            // per-channel interrupt
);

    // =========================================================================
    // Internal Wire Declarations
    // =========================================================================

    // --- Register File Outputs ---
    wire [NUM_CH-1:0]           ch_enable;
    wire [NUM_CH-1:0]           ch_sg_mode;       // scatter-gather mode
    wire [NUM_CH-1:0]           ch_irq_en;
    wire [1:0]                  arb_mode;         // 00=round-robin, 01=fixed-priority
    wire [NUM_CH*32-1:0]        ch_src_addr;
    wire [NUM_CH*32-1:0]        ch_dst_addr;
    wire [NUM_CH*32-1:0]        ch_xfer_len;
    wire [NUM_CH*32-1:0]        ch_desc_base;
    wire [NUM_CH*8-1:0]         ch_burst_len;
    wire [NUM_CH*3-1:0]         ch_burst_size;
    wire [NUM_CH*2-1:0]         ch_src_inc;       // address increment mode
    wire [NUM_CH*2-1:0]         ch_dst_inc;
    // --- Channel Status Inputs to RegFile ---
    wire [NUM_CH-1:0]           ch_busy;
    wire [NUM_CH-1:0]           ch_done;
    wire [NUM_CH-1:0]           ch_err;
    wire [NUM_CH*32-1:0]        ch_bytes_xfered;
    wire [NUM_CH*32-1:0]        ch_cur_src;
    wire [NUM_CH*32-1:0]        ch_cur_dst;

    // --- Channel Controller <-> Arbiter ---
    wire [NUM_CH-1:0]           ch_rd_req;
    wire [NUM_CH-1:0]           ch_wr_req;
    wire [NUM_CH-1:0]           ch_rd_gnt;
    wire [NUM_CH-1:0]           ch_wr_gnt;

    // --- Channel Controller <-> Descriptor Engine ---
    wire [NUM_CH-1:0]           desc_fetch_req;
    wire [NUM_CH-1:0]           desc_fetch_done;
    wire [NUM_CH*32-1:0]        desc_src_addr;
    wire [NUM_CH*32-1:0]        desc_dst_addr;
    wire [NUM_CH*32-1:0]        desc_xfer_len;
    wire [NUM_CH*8-1:0]         desc_burst_len;
    wire [NUM_CH-1:0]           desc_last;        // last descriptor in chain
    wire [NUM_CH*32-1:0]        desc_next_ptr;

    // --- Descriptor Engine <-> AXI4 Master (for desc fetch) ---
    wire [ADDR_WIDTH-1:0]       desc_axi_araddr;
    wire [7:0]                  desc_axi_arlen;
    wire                        desc_axi_arvalid;
    wire                        desc_axi_arready;
    wire [DATA_WIDTH-1:0]       desc_axi_rdata;
    wire [1:0]                  desc_axi_rresp;
    wire                        desc_axi_rlast;
    wire                        desc_axi_rvalid;
    wire                        desc_axi_rready;

    // --- Active channel muxed signals to AXI4 Master ---
    wire [ADDR_WIDTH-1:0]       axi_rd_addr;
    wire [7:0]                  axi_rd_len;
    wire [2:0]                  axi_rd_size;
    wire                        axi_rd_req;
    wire                        axi_rd_gnt;

    wire [ADDR_WIDTH-1:0]       axi_wr_addr;
    wire [7:0]                  axi_wr_len;
    wire [2:0]                  axi_wr_size;
    wire                        axi_wr_req;
    wire                        axi_wr_gnt;

    // --- FIFO per channel ---
    wire [NUM_CH-1:0]           fifo_wr_en;
    wire [NUM_CH*DATA_WIDTH-1:0] fifo_wr_data;
    wire [NUM_CH-1:0]           fifo_wr_full;
    wire [NUM_CH-1:0]           fifo_rd_en;
    wire [NUM_CH*DATA_WIDTH-1:0] fifo_rd_data;
    wire [NUM_CH-1:0]           fifo_rd_empty;
    wire [NUM_CH*STRB_WIDTH-1:0] fifo_wr_strb;
    wire [NUM_CH*STRB_WIDTH-1:0] fifo_rd_strb;

    // --- AXI Master read data path to active channel FIFO ---
    wire [DATA_WIDTH-1:0]       rd_fifo_data;
    wire [STRB_WIDTH-1:0]       rd_fifo_strb;
    wire                        rd_fifo_wr_en;
    wire                        rd_fifo_full;
    wire                        wr_fifo_rd_en;
    wire [DATA_WIDTH-1:0]       wr_fifo_data;
    wire [STRB_WIDTH-1:0]       wr_fifo_strb;
    wire                        wr_fifo_empty;

    // --- Arbiter active channel index ---
    wire [$clog2(NUM_CH)-1:0]   rd_active_ch;
    wire [$clog2(NUM_CH)-1:0]   wr_active_ch;
    wire                        rd_busy;
    wire                        wr_busy;

    // --- Interrupt Controller ---
    wire [NUM_CH-1:0]           ch_done_pulse;
    wire [NUM_CH-1:0]           ch_err_pulse;

    // =========================================================================
    // AXI4-Lite Slave / Register File
    // =========================================================================
    dma_regfile #(
        .NUM_CH     (NUM_CH)
    ) u_regfile (
        .aclk           (aclk),
        .aresetn        (aresetn),
        // AXI4-Lite Slave
        .s_awaddr       (s_axil_awaddr),
        .s_awvalid      (s_axil_awvalid),
        .s_awready      (s_axil_awready),
        .s_wdata        (s_axil_wdata),
        .s_wstrb        (s_axil_wstrb),
        .s_wvalid       (s_axil_wvalid),
        .s_wready       (s_axil_wready),
        .s_bresp        (s_axil_bresp),
        .s_bvalid       (s_axil_bvalid),
        .s_bready       (s_axil_bready),
        .s_araddr       (s_axil_araddr),
        .s_arvalid      (s_axil_arvalid),
        .s_arready      (s_axil_arready),
        .s_rdata        (s_axil_rdata),
        .s_rresp        (s_axil_rresp),
        .s_rvalid       (s_axil_rvalid),
        .s_rready       (s_axil_rready),
        // Channel configuration outputs
        .ch_enable      (ch_enable),
        .ch_sg_mode     (ch_sg_mode),
        .ch_irq_en      (ch_irq_en),
        .arb_mode       (arb_mode),
        .ch_src_addr    (ch_src_addr),
        .ch_dst_addr    (ch_dst_addr),
        .ch_xfer_len    (ch_xfer_len),
        .ch_desc_base   (ch_desc_base),
        .ch_burst_len   (ch_burst_len),
        .ch_burst_size  (ch_burst_size),
        .ch_src_inc     (ch_src_inc),
        .ch_dst_inc     (ch_dst_inc),
        // Channel status inputs
        .ch_busy        (ch_busy),
        .ch_done        (ch_done),
        .ch_err         (ch_err),
        .ch_bytes_xfered(ch_bytes_xfered),
        .ch_cur_src     (ch_cur_src),
        .ch_cur_dst     (ch_cur_dst)
    );

    // =========================================================================
    // DMA Channel Controllers (one per channel)
    // =========================================================================
    genvar i;
    generate
        for (i = 0; i < NUM_CH; i = i + 1) begin : gen_ch
            dma_channel #(
                .ADDR_WIDTH  (ADDR_WIDTH),
                .DATA_WIDTH  (DATA_WIDTH),
                .FIFO_DEPTH  (FIFO_DEPTH)
            ) u_channel (
                .aclk           (aclk),
                .aresetn        (aresetn),
                // Configuration
                .ch_enable      (ch_enable[i]),
                .ch_sg_mode     (ch_sg_mode[i]),
                .ch_src_addr    (ch_src_addr[i*32 +: 32]),
                .ch_dst_addr    (ch_dst_addr[i*32 +: 32]),
                .ch_xfer_len    (ch_xfer_len[i*32 +: 32]),
                .ch_burst_len   (ch_burst_len[i*8 +: 8]),
                .ch_burst_size  (ch_burst_size[i*3 +: 3]),
                .ch_src_inc     (ch_src_inc[i*2 +: 2]),
                .ch_dst_inc     (ch_dst_inc[i*2 +: 2]),
                // Peripheral handshake
                .dma_req        (dma_req[i]),
                .dma_ack        (dma_ack[i]),
                .dma_done_ext   (dma_done_ext[i]),
                // Descriptor engine
                .desc_fetch_req (desc_fetch_req[i]),
                .desc_fetch_done(desc_fetch_done[i]),
                .desc_src_addr  (desc_src_addr[i*32 +: 32]),
                .desc_dst_addr  (desc_dst_addr[i*32 +: 32]),
                .desc_xfer_len  (desc_xfer_len[i*32 +: 32]),
                .desc_burst_len (desc_burst_len[i*8 +: 8]),
                .desc_last      (desc_last[i]),
                // Arbiter request/grant
                .rd_req         (ch_rd_req[i]),
                .rd_gnt         (ch_rd_gnt[i]),
                .wr_req         (ch_wr_req[i]),
                .wr_gnt         (ch_wr_gnt[i]),
                // Status
                .ch_busy        (ch_busy[i]),
                .ch_done        (ch_done[i]),
                .ch_err         (ch_err[i]),
                .ch_done_pulse  (ch_done_pulse[i]),
                .ch_err_pulse   (ch_err_pulse[i]),
                .bytes_xfered   (ch_bytes_xfered[i*32 +: 32]),
                .cur_src_addr   (ch_cur_src[i*32 +: 32]),
                .cur_dst_addr   (ch_cur_dst[i*32 +: 32]),
                // FIFO write (from read engine)
                .fifo_wr_en     (fifo_wr_en[i]),
                .fifo_wr_data   (fifo_wr_data[i*DATA_WIDTH +: DATA_WIDTH]),
                .fifo_wr_strb   (fifo_wr_strb[i*STRB_WIDTH +: STRB_WIDTH]),
                .fifo_wr_full   (fifo_wr_full[i]),
                // FIFO read (to write engine)
                .fifo_rd_en     (fifo_rd_en[i]),
                .fifo_rd_data   (fifo_rd_data[i*DATA_WIDTH +: DATA_WIDTH]),
                .fifo_rd_strb   (fifo_rd_strb[i*STRB_WIDTH +: STRB_WIDTH]),
                .fifo_rd_empty  (fifo_rd_empty[i])
            );
        end
    endgenerate

    // =========================================================================
    // Descriptor Engine
    // =========================================================================
    dma_descriptor #(
        .NUM_CH     (NUM_CH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_descriptor (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .ch_sg_mode     (ch_sg_mode),
        .ch_desc_base   (ch_desc_base),
        // Fetch requests from channels
        .fetch_req      (desc_fetch_req),
        .fetch_done     (desc_fetch_done),
        // Decoded descriptor outputs
        .desc_src_addr  (desc_src_addr),
        .desc_dst_addr  (desc_dst_addr),
        .desc_xfer_len  (desc_xfer_len),
        .desc_burst_len (desc_burst_len),
        .desc_last      (desc_last),
        .desc_next_ptr  (desc_next_ptr),
        // AXI4 Read interface to fetch descriptors from memory
        .m_axi_araddr   (desc_axi_araddr),
        .m_axi_arlen    (desc_axi_arlen),
        .m_axi_arvalid  (desc_axi_arvalid),
        .m_axi_arready  (desc_axi_arready),
        .m_axi_rdata    (desc_axi_rdata),
        .m_axi_rresp    (desc_axi_rresp),
        .m_axi_rlast    (desc_axi_rlast),
        .m_axi_rvalid   (desc_axi_rvalid),
        .m_axi_rready   (desc_axi_rready)
    );

    // =========================================================================
    // Channel Arbiter
    // =========================================================================
    dma_arbiter #(
        .NUM_CH     (NUM_CH)
    ) u_arbiter (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .arb_mode       (arb_mode),
        // Read channel requests/grants
        .rd_req         (ch_rd_req),
        .rd_gnt         (ch_rd_gnt),
        .rd_active_ch   (rd_active_ch),
        .rd_busy        (rd_busy),
        // Write channel requests/grants
        .wr_req         (ch_wr_req),
        .wr_gnt         (ch_wr_gnt),
        .wr_active_ch   (wr_active_ch),
        .wr_busy        (wr_busy)
    );

    // =========================================================================
    // Per-Channel FIFOs
    // =========================================================================
    generate
        for (i = 0; i < NUM_CH; i = i + 1) begin : gen_fifo
            dma_fifo #(
                .DATA_WIDTH (DATA_WIDTH + STRB_WIDTH),
                .DEPTH      (FIFO_DEPTH)
            ) u_fifo (
                .aclk       (aclk),
                .aresetn    (aresetn),
                .wr_en      (fifo_wr_en[i]),
                .wr_data    ({fifo_wr_strb[i*STRB_WIDTH +: STRB_WIDTH],
                              fifo_wr_data[i*DATA_WIDTH +: DATA_WIDTH]}),
                .wr_full    (fifo_wr_full[i]),
                .rd_en      (fifo_rd_en[i]),
                .rd_data    ({fifo_rd_strb[i*STRB_WIDTH +: STRB_WIDTH],
                              fifo_rd_data[i*DATA_WIDTH +: DATA_WIDTH]}),
                .rd_empty   (fifo_rd_empty[i])
            );
        end
    endgenerate

    // =========================================================================
    // AXI4 Master Interface
    // =========================================================================
    dma_axi4_master #(
        .NUM_CH     (NUM_CH),
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) u_axi4_master (
        .aclk               (aclk),
        .aresetn            (aresetn),
        // From Arbiter
        .rd_active_ch       (rd_active_ch),
        .wr_active_ch       (wr_active_ch),
        .rd_busy            (rd_busy),
        .wr_busy            (wr_busy),
        // Channel read parameters (muxed by arbiter-selected channel)
        .ch_rd_req          (ch_rd_req),
        .ch_rd_gnt          (ch_rd_gnt),
        .ch_wr_req          (ch_wr_req),
        .ch_wr_gnt          (ch_wr_gnt),
        .ch_src_addr        (ch_src_addr),
        .ch_dst_addr        (ch_dst_addr),
        .ch_xfer_len        (ch_xfer_len),
        .ch_burst_len       (ch_burst_len),
        .ch_burst_size      (ch_burst_size),
        // FIFO interfaces (indexed by active channel)
        .fifo_wr_en         (fifo_wr_en),
        .fifo_wr_data       (fifo_wr_data),
        .fifo_wr_strb       (fifo_wr_strb),
        .fifo_wr_full       (fifo_wr_full),
        .fifo_rd_en         (fifo_rd_en),
        .fifo_rd_data       (fifo_rd_data),
        .fifo_rd_strb       (fifo_rd_strb),
        .fifo_rd_empty      (fifo_rd_empty),
        // Descriptor engine AXI port (muxed)
        .desc_axi_araddr    (desc_axi_araddr),
        .desc_axi_arlen     (desc_axi_arlen),
        .desc_axi_arvalid   (desc_axi_arvalid),
        .desc_axi_arready   (desc_axi_arready),
        .desc_axi_rdata     (desc_axi_rdata),
        .desc_axi_rresp     (desc_axi_rresp),
        .desc_axi_rlast     (desc_axi_rlast),
        .desc_axi_rvalid    (desc_axi_rvalid),
        .desc_axi_rready    (desc_axi_rready),
        // AXI4 Master outputs
        .m_axi_awid         (m_axi_awid),
        .m_axi_awaddr       (m_axi_awaddr),
        .m_axi_awlen        (m_axi_awlen),
        .m_axi_awsize       (m_axi_awsize),
        .m_axi_awburst      (m_axi_awburst),
        .m_axi_awlock       (m_axi_awlock),
        .m_axi_awcache      (m_axi_awcache),
        .m_axi_awprot       (m_axi_awprot),
        .m_axi_awqos        (m_axi_awqos),
        .m_axi_awvalid      (m_axi_awvalid),
        .m_axi_awready      (m_axi_awready),
        .m_axi_wdata        (m_axi_wdata),
        .m_axi_wstrb        (m_axi_wstrb),
        .m_axi_wlast        (m_axi_wlast),
        .m_axi_wvalid       (m_axi_wvalid),
        .m_axi_wready       (m_axi_wready),
        .m_axi_bid          (m_axi_bid),
        .m_axi_bresp        (m_axi_bresp),
        .m_axi_bvalid       (m_axi_bvalid),
        .m_axi_bready       (m_axi_bready),
        .m_axi_arid         (m_axi_arid),
        .m_axi_araddr       (m_axi_araddr),
        .m_axi_arlen        (m_axi_arlen),
        .m_axi_arsize       (m_axi_arsize),
        .m_axi_arburst      (m_axi_arburst),
        .m_axi_arlock       (m_axi_arlock),
        .m_axi_arcache      (m_axi_arcache),
        .m_axi_arprot       (m_axi_arprot),
        .m_axi_arqos        (m_axi_arqos),
        .m_axi_arvalid      (m_axi_arvalid),
        .m_axi_arready      (m_axi_arready),
        .m_axi_rid          (m_axi_rid),
        .m_axi_rdata        (m_axi_rdata),
        .m_axi_rresp        (m_axi_rresp),
        .m_axi_rlast        (m_axi_rlast),
        .m_axi_rvalid       (m_axi_rvalid),
        .m_axi_rready       (m_axi_rready)
    );

    // =========================================================================
    // Interrupt Controller
    // =========================================================================
    dma_interrupt #(
        .NUM_CH (NUM_CH)
    ) u_interrupt (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .ch_irq_en      (ch_irq_en),
        .ch_done_pulse  (ch_done_pulse),
        .ch_err_pulse   (ch_err_pulse),
        .irq            (irq)
    );

endmodule
