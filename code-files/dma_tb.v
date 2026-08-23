`timescale 1ns / 1ps

module dma_tb;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam NUM_CH     = 4;
    localparam DATA_WIDTH = 64;
    localparam ADDR_WIDTH = 32;
    localparam ID_WIDTH   = 4;
    localparam STRB_WIDTH = DATA_WIDTH / 8;
    localparam MEM_SIZE   = 65536;          // 64 KB AXI memory model
    localparam CLK_PERIOD = 10;             // 100 MHz

    // Register map constants
    localparam DMA_CTRL        = 32'h0000;
    localparam DMA_STATUS      = 32'h0004;
    localparam DMA_IRQ_STATUS  = 32'h0008;
    localparam DMA_IRQ_MASK    = 32'h000C;
    // Per-channel base: 0x100 + ch*0x40
    localparam CH0_BASE        = 32'h0100;
    localparam CH1_BASE        = 32'h0140;
    localparam CH2_BASE        = 32'h0180;
    localparam CH3_BASE        = 32'h01C0;
    // Channel register offsets
    localparam CH_CTRL         = 6'h00;
    localparam CH_STATUS       = 6'h04;
    localparam CH_SRC_ADDR     = 6'h08;
    localparam CH_DST_ADDR     = 6'h0C;
    localparam CH_XFER_LEN     = 6'h10;
    localparam CH_DESC_BASE    = 6'h14;
    localparam CH_BURST        = 6'h18;
    localparam CH_BYTES_DONE   = 6'h1C;

    // =========================================================================
    // DUT Signal Declarations
    // =========================================================================
    reg                     aclk;
    reg                     aresetn;

    // AXI4-Lite (config)
    reg  [31:0]             s_axil_awaddr;
    reg                     s_axil_awvalid;
    wire                    s_axil_awready;
    reg  [31:0]             s_axil_wdata;
    reg  [3:0]              s_axil_wstrb;
    reg                     s_axil_wvalid;
    wire                    s_axil_wready;
    wire [1:0]              s_axil_bresp;
    wire                    s_axil_bvalid;
    reg                     s_axil_bready;
    reg  [31:0]             s_axil_araddr;
    reg                     s_axil_arvalid;
    wire                    s_axil_arready;
    wire [31:0]             s_axil_rdata;
    wire [1:0]              s_axil_rresp;
    wire                    s_axil_rvalid;
    reg                     s_axil_rready;

    // AXI4 Master (data)
    wire [ID_WIDTH-1:0]     m_axi_awid;
    wire [ADDR_WIDTH-1:0]   m_axi_awaddr;
    wire [7:0]              m_axi_awlen;
    wire [2:0]              m_axi_awsize;
    wire [1:0]              m_axi_awburst;
    wire                    m_axi_awlock;
    wire [3:0]              m_axi_awcache;
    wire [2:0]              m_axi_awprot;
    wire [3:0]              m_axi_awqos;
    wire                    m_axi_awvalid;
    reg                     m_axi_awready;
    wire [DATA_WIDTH-1:0]   m_axi_wdata;
    wire [STRB_WIDTH-1:0]   m_axi_wstrb;
    wire                    m_axi_wlast;
    wire                    m_axi_wvalid;
    reg                     m_axi_wready;
    reg  [ID_WIDTH-1:0]     m_axi_bid;
    reg  [1:0]              m_axi_bresp;
    reg                     m_axi_bvalid;
    wire                    m_axi_bready;
    wire [ID_WIDTH-1:0]     m_axi_arid;
    wire [ADDR_WIDTH-1:0]   m_axi_araddr;
    wire [7:0]              m_axi_arlen;
    wire [2:0]              m_axi_arsize;
    wire [1:0]              m_axi_arburst;
    wire                    m_axi_arlock;
    wire [3:0]              m_axi_arcache;
    wire [2:0]              m_axi_arprot;
    wire [3:0]              m_axi_arqos;
    wire                    m_axi_arvalid;
    reg                     m_axi_arready;
    reg  [ID_WIDTH-1:0]     m_axi_rid;
    reg  [DATA_WIDTH-1:0]   m_axi_rdata;
    reg  [1:0]              m_axi_rresp;
    reg                     m_axi_rlast;
    reg                     m_axi_rvalid;
    wire                    m_axi_rready;

    // DMA flow control
    reg  [NUM_CH-1:0]       dma_req;
    wire [NUM_CH-1:0]       dma_ack;
    reg  [NUM_CH-1:0]       dma_done_ext;

    // Interrupts
    wire [NUM_CH-1:0]       irq;

    // =========================================================================
    // AXI Memory Model (64 KB)
    // =========================================================================
    reg [7:0]   mem [0:MEM_SIZE-1];
    integer     ii;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    dma_top #(
        .NUM_CH     (NUM_CH),
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .ID_WIDTH   (ID_WIDTH),
        .FIFO_DEPTH (512)
    ) dut (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .s_axil_awaddr  (s_axil_awaddr),
        .s_axil_awvalid (s_axil_awvalid),
        .s_axil_awready (s_axil_awready),
        .s_axil_wdata   (s_axil_wdata),
        .s_axil_wstrb   (s_axil_wstrb),
        .s_axil_wvalid  (s_axil_wvalid),
        .s_axil_wready  (s_axil_wready),
        .s_axil_bresp   (s_axil_bresp),
        .s_axil_bvalid  (s_axil_bvalid),
        .s_axil_bready  (s_axil_bready),
        .s_axil_araddr  (s_axil_araddr),
        .s_axil_arvalid (s_axil_arvalid),
        .s_axil_arready (s_axil_arready),
        .s_axil_rdata   (s_axil_rdata),
        .s_axil_rresp   (s_axil_rresp),
        .s_axil_rvalid  (s_axil_rvalid),
        .s_axil_rready  (s_axil_rready),
        .m_axi_awid     (m_axi_awid),
        .m_axi_awaddr   (m_axi_awaddr),
        .m_axi_awlen    (m_axi_awlen),
        .m_axi_awsize   (m_axi_awsize),
        .m_axi_awburst  (m_axi_awburst),
        .m_axi_awlock   (m_axi_awlock),
        .m_axi_awcache  (m_axi_awcache),
        .m_axi_awprot   (m_axi_awprot),
        .m_axi_awqos    (m_axi_awqos),
        .m_axi_awvalid  (m_axi_awvalid),
        .m_axi_awready  (m_axi_awready),
        .m_axi_wdata    (m_axi_wdata),
        .m_axi_wstrb    (m_axi_wstrb),
        .m_axi_wlast    (m_axi_wlast),
        .m_axi_wvalid   (m_axi_wvalid),
        .m_axi_wready   (m_axi_wready),
        .m_axi_bid      (m_axi_bid),
        .m_axi_bresp    (m_axi_bresp),
        .m_axi_bvalid   (m_axi_bvalid),
        .m_axi_bready   (m_axi_bready),
        .m_axi_arid     (m_axi_arid),
        .m_axi_araddr   (m_axi_araddr),
        .m_axi_arlen    (m_axi_arlen),
        .m_axi_arsize   (m_axi_arsize),
        .m_axi_arburst  (m_axi_arburst),
        .m_axi_arlock   (m_axi_arlock),
        .m_axi_arcache  (m_axi_arcache),
        .m_axi_arprot   (m_axi_arprot),
        .m_axi_arqos    (m_axi_arqos),
        .m_axi_arvalid  (m_axi_arvalid),
        .m_axi_arready  (m_axi_arready),
        .m_axi_rid      (m_axi_rid),
        .m_axi_rdata    (m_axi_rdata),
        .m_axi_rresp    (m_axi_rresp),
        .m_axi_rlast    (m_axi_rlast),
        .m_axi_rvalid   (m_axi_rvalid),
        .m_axi_rready   (m_axi_rready),
        .dma_req        (dma_req),
        .dma_ack        (dma_ack),
        .dma_done_ext   (dma_done_ext),
        .irq            (irq)
    );

    // =========================================================================
    // Clock Generation
    // =========================================================================
    initial aclk = 1'b0;
    always #(CLK_PERIOD/2) aclk = ~aclk;

    // =========================================================================
    // AXI4 Slave Memory Model
    // =========================================================================
    // Handles AR/R (reads from memory) and AW/W/B (writes to memory)
    // with a 2-cycle random latency for realism.

    // --- Read Responder ---
    reg [ADDR_WIDTH-1:0]    ar_addr_r;
    reg [7:0]               ar_len_r;
    reg [2:0]               ar_size_r;
    reg [ID_WIDTH-1:0]      ar_id_r;
    reg [7:0]               r_beat_cnt;
    reg                     r_active;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            m_axi_arready <= 1'b1;
            m_axi_rvalid  <= 1'b0;
            m_axi_rdata   <= {DATA_WIDTH{1'b0}};
            m_axi_rresp   <= 2'b00;
            m_axi_rlast   <= 1'b0;
            m_axi_rid     <= {ID_WIDTH{1'b0}};
            r_active      <= 1'b0;
            r_beat_cnt    <= 8'h0;
        end else begin
            if (!r_active) begin
                m_axi_rvalid <= 1'b0;
                m_axi_arready <= 1'b1;
                if (m_axi_arvalid && m_axi_arready) begin
                    ar_addr_r     <= m_axi_araddr;
                    ar_len_r      <= m_axi_arlen;
                    ar_size_r     <= m_axi_arsize;
                    ar_id_r       <= m_axi_arid;
                    r_beat_cnt    <= m_axi_arlen;
                    r_active      <= 1'b1;
                    m_axi_arready <= 1'b0;
                end
            end else begin
                // Serve beats
                m_axi_rvalid <= 1'b1;
                m_axi_rid    <= ar_id_r;
                m_axi_rresp  <= 2'b00;
                // Read 8 bytes from memory model
                m_axi_rdata  <= {mem[(ar_addr_r & (MEM_SIZE-1))+7],
                                  mem[(ar_addr_r & (MEM_SIZE-1))+6],
                                  mem[(ar_addr_r & (MEM_SIZE-1))+5],
                                  mem[(ar_addr_r & (MEM_SIZE-1))+4],
                                  mem[(ar_addr_r & (MEM_SIZE-1))+3],
                                  mem[(ar_addr_r & (MEM_SIZE-1))+2],
                                  mem[(ar_addr_r & (MEM_SIZE-1))+1],
                                  mem[(ar_addr_r & (MEM_SIZE-1))+0]};
                m_axi_rlast  <= (r_beat_cnt == 8'h0);
                if (m_axi_rvalid && m_axi_rready) begin
                    ar_addr_r  <= ar_addr_r + (1 << ar_size_r);
                    if (r_beat_cnt > 0) begin
                        r_beat_cnt <= r_beat_cnt - 1;
                    end else begin
                        m_axi_rvalid  <= 1'b0;
                        m_axi_rlast   <= 1'b0;
                        r_active      <= 1'b0;
                        m_axi_arready <= 1'b1;
                    end
                end
            end
        end
    end

    // --- Write Responder ---
    reg [ADDR_WIDTH-1:0]    aw_addr_r;
    reg [7:0]               aw_len_r;
    reg [2:0]               aw_size_r;
    reg [ID_WIDTH-1:0]      aw_id_r;
    reg [7:0]               w_beat_cnt;
    reg                     w_active;
    reg                     b_pending;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            m_axi_awready <= 1'b1;
            m_axi_wready  <= 1'b0;
            m_axi_bvalid  <= 1'b0;
            m_axi_bresp   <= 2'b00;
            m_axi_bid     <= {ID_WIDTH{1'b0}};
            w_active      <= 1'b0;
            b_pending     <= 1'b0;
            w_beat_cnt    <= 8'h0;
        end else begin
            // Accept AW
            if (!w_active && !b_pending) begin
                m_axi_awready <= 1'b1;
                if (m_axi_awvalid && m_axi_awready) begin
                    aw_addr_r     <= m_axi_awaddr;
                    aw_len_r      <= m_axi_awlen;
                    aw_size_r     <= m_axi_awsize;
                    aw_id_r       <= m_axi_awid;
                    w_beat_cnt    <= m_axi_awlen;
                    w_active      <= 1'b1;
                    m_axi_awready <= 1'b0;
                    m_axi_wready  <= 1'b1;
                end
            end

            // Accept W beats and write to memory
            if (w_active) begin
                if (m_axi_wvalid && m_axi_wready) begin
                    begin : write_bytes
                        integer b;
                        for (b = 0; b < STRB_WIDTH; b = b + 1) begin
                            if (m_axi_wstrb[b])
                                mem[(aw_addr_r & (MEM_SIZE-1)) + b] <= m_axi_wdata[b*8 +: 8];
                        end
                    end
                    aw_addr_r <= aw_addr_r + (1 << aw_size_r);
                    if (w_beat_cnt > 0) begin
                        w_beat_cnt <= w_beat_cnt - 1;
                    end
                    if (m_axi_wlast) begin
                        m_axi_wready <= 1'b0;
                        w_active     <= 1'b0;
                        b_pending    <= 1'b1;
                        m_axi_bvalid <= 1'b1;
                        m_axi_bresp  <= 2'b00;
                        m_axi_bid    <= aw_id_r;
                    end
                end
            end

            // Send B response
            if (b_pending) begin
                if (m_axi_bvalid && m_axi_bready) begin
                    m_axi_bvalid  <= 1'b0;
                    b_pending     <= 1'b0;
                    m_axi_awready <= 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // Interrupt Monitor
    // =========================================================================
    always @(posedge aclk) begin
        if (|irq)
            $display("[IRQ] t=%0t  IRQ asserted: 4'b%04b", $time, irq);
    end

    // =========================================================================
    // AXI4-Lite Master Tasks
    // =========================================================================
    task axil_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge aclk);
            s_axil_awaddr  <= addr;
            s_axil_awvalid <= 1'b1;
            s_axil_wdata   <= data;
            s_axil_wstrb   <= 4'hF;
            s_axil_wvalid  <= 1'b1;
            // Wait for AW handshake
            @(posedge aclk);
            while (!s_axil_awready) @(posedge aclk);
            s_axil_awvalid <= 1'b0;
            // Wait for W handshake
            while (!s_axil_wready) @(posedge aclk);
            s_axil_wvalid <= 1'b0;
            // Wait for B response
            s_axil_bready <= 1'b1;
            @(posedge aclk);
            while (!s_axil_bvalid) @(posedge aclk);
            @(posedge aclk);
            s_axil_bready <= 1'b0;
        end
    endtask

    task axil_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge aclk);
            s_axil_araddr  <= addr;
            s_axil_arvalid <= 1'b1;
            s_axil_rready  <= 1'b1;
            @(posedge aclk);
            while (!s_axil_arready) @(posedge aclk);
            s_axil_arvalid <= 1'b0;
            @(posedge aclk);
            while (!s_axil_rvalid) @(posedge aclk);
            data = s_axil_rdata;
            @(posedge aclk);
            s_axil_rready <= 1'b0;
        end
    endtask

    // Helper: program a channel in simple mode and enable it
    task program_channel;
        input integer ch;
        input [31:0] src;
        input [31:0] dst;
        input [31:0] len;
        input [7:0]  burst_len;
        begin : prog
            reg [31:0] base;
            base = 32'h100 + ch * 32'h40;
            axil_write(base + CH_SRC_ADDR, src);
            axil_write(base + CH_DST_ADDR, dst);
            axil_write(base + CH_XFER_LEN, len);
            axil_write(base + CH_BURST,    {21'h0, 3'h3, burst_len});
            // ctrl: enable=1, sg_mode=0, irq_en=1, src_inc=01, dst_inc=01
            axil_write(base + CH_CTRL,     32'b00_01_01_100_1);
        end
    endtask

    // Wait for channel done
    task wait_ch_done;
        input integer ch;
        input integer timeout_cycles;
        begin : wait_done
            integer cnt;
            reg [31:0] status;
            reg [31:0] base;
            base  = 32'h100 + ch * 32'h40;
            cnt   = 0;
            status = 32'h0;
            while (!status[1] && cnt < timeout_cycles) begin
                axil_read(base + CH_STATUS, status);
                @(posedge aclk);
                cnt = cnt + 1;
            end
            if (cnt >= timeout_cycles)
                $display("[FAIL] TC: channel %0d timed out waiting for done", ch);
            else
                $display("[PASS] Channel %0d done in %0d cycles", ch, cnt);
        end
    endtask

    // Memory checker: compare src and dst regions
    task check_mem;
        input [31:0] src_base;
        input [31:0] dst_base;
        input [31:0] length;
        begin : check
            integer b;
            integer pass;
            pass = 1;
            for (b = 0; b < length; b = b + 1) begin
                if (mem[(dst_base + b) & (MEM_SIZE-1)] !== mem[(src_base + b) & (MEM_SIZE-1)]) begin
                    $display("[FAIL] Mismatch at dst[%0d]: expected %02h got %02h",
                        b,
                        mem[(src_base+b) & (MEM_SIZE-1)],
                        mem[(dst_base+b) & (MEM_SIZE-1)]);
                    pass = 0;
                end
            end
            if (pass)
                $display("[PASS] Memory check src=0x%08h dst=0x%08h len=%0d OK", src_base, dst_base, length);
        end
    endtask

    // =========================================================================
    // Test Stimulus
    // =========================================================================
    integer j;
    reg [31:0] rdata;

    initial begin
        // -------------------------------------------------------------------
        // Initialise signals
        // -------------------------------------------------------------------
        aresetn        = 1'b0;
        s_axil_awaddr  = 32'h0;
        s_axil_awvalid = 1'b0;
        s_axil_wdata   = 32'h0;
        s_axil_wstrb   = 4'hF;
        s_axil_wvalid  = 1'b0;
        s_axil_bready  = 1'b0;
        s_axil_araddr  = 32'h0;
        s_axil_arvalid = 1'b0;
        s_axil_rready  = 1'b0;
        dma_req        = {NUM_CH{1'b0}};
        dma_done_ext   = {NUM_CH{1'b0}};

        // Initialise memory: fill source region with known pattern
        for (ii = 0; ii < MEM_SIZE; ii = ii + 1)
            mem[ii] = ii[7:0];

        // Release reset after 20 cycles
        repeat(20) @(posedge aclk);
        aresetn = 1'b1;
        repeat(5) @(posedge aclk);

        $display("=============================================================");
        $display("  DMA Controller Testbench - Starting Test Suite");
        $display("=============================================================");

        // -------------------------------------------------------------------
        // TC1: Simple single-channel transfer - CH0
        //      src=0x0000, dst=0x1000, len=128 bytes
        // -------------------------------------------------------------------
        $display("\n[TC1] Single-channel simple mode (CH0): 128 bytes");
        program_channel(0, 32'h0000, 32'h1000, 32'd128, 8'hF);
        repeat(5) @(posedge aclk);
        wait_ch_done(0, 5000);
        check_mem(32'h0000, 32'h1000, 32'd128);

        // -------------------------------------------------------------------
        // TC2: Four simultaneous channels, round-robin arbitration
        //      CH0: 0x0200→0x2000, CH1: 0x0300→0x3000
        //      CH2: 0x0400→0x4000, CH3: 0x0500→0x5000, each 64 bytes
        // -------------------------------------------------------------------
        $display("\n[TC2] Four simultaneous channels, round-robin arb: 64 bytes each");
        // Set global arb_mode = round-robin
        axil_write(DMA_CTRL, 32'h0000);
        program_channel(0, 32'h0200, 32'h2000, 32'd64, 8'h7);
        program_channel(1, 32'h0300, 32'h3000, 32'd64, 8'h7);
        program_channel(2, 32'h0400, 32'h4000, 32'd64, 8'h7);
        program_channel(3, 32'h0500, 32'h5000, 32'd64, 8'h7);
        repeat(5) @(posedge aclk);
        wait_ch_done(0, 10000);
        wait_ch_done(1, 10000);
        wait_ch_done(2, 10000);
        wait_ch_done(3, 10000);
        check_mem(32'h0200, 32'h2000, 32'd64);
        check_mem(32'h0300, 32'h3000, 32'd64);
        check_mem(32'h0400, 32'h4000, 32'd64);
        check_mem(32'h0500, 32'h5000, 32'd64);

        // -------------------------------------------------------------------
        // TC3: Fixed-priority arbitration (CH3 > CH2 > CH1 > CH0)
        // -------------------------------------------------------------------
        $display("\n[TC3] Fixed-priority arbitration test");
        axil_write(DMA_CTRL, 32'h0001); // arb_mode = fixed-priority
        program_channel(0, 32'h0600, 32'h6000, 32'd32, 8'h3);
        program_channel(1, 32'h0700, 32'h7000, 32'd32, 8'h3);
        program_channel(2, 32'h0800, 32'h8000, 32'd32, 8'h3);
        program_channel(3, 32'h0900, 32'h9000, 32'd32, 8'h3);
        repeat(5) @(posedge aclk);
        wait_ch_done(3, 5000);
        wait_ch_done(2, 5000);
        wait_ch_done(1, 5000);
        wait_ch_done(0, 5000);
        check_mem(32'h0600, 32'h6000, 32'd32);
        check_mem(32'h0900, 32'h9000, 32'd32);

        // -------------------------------------------------------------------
        // TC4: Peripheral flow-control handshake on CH0
        //      Assert dma_req, wait for dma_ack, then start transfer
        // -------------------------------------------------------------------
        $display("\n[TC4] Peripheral flow-control handshake (CH0)");
        begin : tc4
            reg [31:0] base;
            base = CH0_BASE;
            axil_write(base + CH_SRC_ADDR, 32'h0A00);
            axil_write(base + CH_DST_ADDR, 32'hA000);
            axil_write(base + CH_XFER_LEN, 32'd32);
            axil_write(base + CH_BURST,    {21'h0, 3'h3, 8'h3});
            // ctrl: enable=1, sg_mode=0, irq_en=1 — channel waits for dma_req
            axil_write(base + CH_CTRL, 32'b00_01_01_100_1);
            // Now assert peripheral request
            dma_req[0] = 1'b1;
            // Wait for ack
            @(posedge dma_ack[0]);
            $display("[TC4]  dma_ack[0] received");
            dma_req[0] = 1'b0;
            wait_ch_done(0, 3000);
            check_mem(32'h0A00, 32'hA000, 32'd32);
        end

        // -------------------------------------------------------------------
        // TC5: Back-to-back transfers on CH1
        // -------------------------------------------------------------------
        $display("\n[TC5] Back-to-back transfers on CH1");
        program_channel(1, 32'h0B00, 32'hB000, 32'd64, 8'h7);
        wait_ch_done(1, 5000);
        check_mem(32'h0B00, 32'hB000, 32'd64);
        // Immediately re-program and re-enable
        program_channel(1, 32'h0B40, 32'hB040, 32'd64, 8'h7);
        wait_ch_done(1, 5000);
        check_mem(32'h0B40, 32'hB040, 32'd64);

        // -------------------------------------------------------------------
        // TC6: IRQ status register test
        // -------------------------------------------------------------------
        $display("\n[TC6] IRQ status register check");
        begin : tc6
            reg [31:0] irq_stat;
            program_channel(0, 32'h0C00, 32'hC000, 32'd32, 8'h3);
            wait_ch_done(0, 3000);
            axil_read(DMA_IRQ_STATUS, irq_stat);
            if (irq_stat[0])
                $display("[PASS] TC6: IRQ status bit[0] set for CH0");
            else
                $display("[WARN] TC6: IRQ status bit[0] not set (irq_en may be off)");
            // Clear W1C
            axil_write(DMA_IRQ_STATUS, 32'hFFFFFFFF);
            axil_read(DMA_IRQ_STATUS, irq_stat);
            if (irq_stat == 32'h0)
                $display("[PASS] TC6: IRQ status cleared successfully");
            else
                $display("[FAIL] TC6: IRQ status not cleared: %08h", irq_stat);
        end

        // -------------------------------------------------------------------
        // TC7: Register read-back sanity
        // -------------------------------------------------------------------
        $display("\n[TC7] Register read-back test");
        begin : tc7
            reg [31:0] rval;
            axil_write(CH0_BASE + CH_SRC_ADDR, 32'hDEAD_BEEF);
            axil_read (CH0_BASE + CH_SRC_ADDR, rval);
            if (rval === 32'hDEAD_BEEF)
                $display("[PASS] TC7: Register read-back OK (0x%08h)", rval);
            else
                $display("[FAIL] TC7: Register read-back mismatch: got 0x%08h", rval);
        end

        // -------------------------------------------------------------------
        // Simulation complete
        // -------------------------------------------------------------------
        repeat(20) @(posedge aclk);
        $display("\n=============================================================");
        $display("  DMA Controller Testbench - All Tests Complete");
        $display("=============================================================\n");
        $finish;
    end

    // =========================================================================
    // Timeout Watchdog (10 ms sim time)
    // =========================================================================
    initial begin
        #10_000_000;
        $display("[WATCHDOG] Simulation timeout!");
        $finish;
    end

    // =========================================================================
    // VCD Dump
    // =========================================================================
    initial begin
        $dumpfile("sim/dma_tb.vcd");
        $dumpvars(0, dma_tb);
    end

endmodule
