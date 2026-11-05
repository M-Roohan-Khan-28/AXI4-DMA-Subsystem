`timescale 1ns / 1ps

module dma_axi4lite_slave #(
    parameter ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 32
)(
    input  wire                     aclk,
    input  wire                     aresetn,

    // --- AXI4-Lite Slave Ports ---
    input  wire [ADDR_WIDTH-1:0]    s_axil_awaddr,
    input  wire [2:0]               s_axil_awprot,
    input  wire                     s_axil_awvalid,
    output wire                     s_axil_awready,

    input  wire [DATA_WIDTH-1:0]    s_axil_wdata,
    input  wire [DATA_WIDTH/8-1:0]  s_axil_wstrb,
    input  wire                     s_axil_wvalid,
    output wire                     s_axil_wready,

    output wire [1:0]               s_axil_bresp,
    output wire                     s_axil_bvalid,
    input  wire                     s_axil_bready,

    input  wire [ADDR_WIDTH-1:0]    s_axil_araddr,
    input  wire [2:0]               s_axil_arprot,
    input  wire                     s_axil_arvalid,
    output wire                     s_axil_arready,

    output wire [DATA_WIDTH-1:0]    s_axil_rdata,
    output wire [1:0]               s_axil_rresp,
    output wire                     s_axil_rvalid,
    input  wire                     s_axil_rready,

    // --- Internal register interface ---
    output wire [ADDR_WIDTH-1:0]    reg_wr_addr,
    output wire [DATA_WIDTH-1:0]    reg_wr_data,
    output wire [DATA_WIDTH/8-1:0]  reg_wr_strb,
    output wire                     reg_wr_en,      // pulse: write strobe

    output wire [ADDR_WIDTH-1:0]    reg_rd_addr,
    output wire                     reg_rd_en,      // pulse: read strobe
    input  wire [DATA_WIDTH-1:0]    reg_rd_data,
    input  wire                     reg_rd_ready    // 1 = data available same cycle
);

    // =========================================================================
    // Write State Machine
    // =========================================================================
    localparam WR_IDLE  = 2'd0;
    localparam WR_DATA  = 2'd1;
    localparam WR_RESP  = 2'd2;

    reg [1:0]               wr_state;
    reg [ADDR_WIDTH-1:0]    wr_addr_lat;
    reg [DATA_WIDTH-1:0]    wr_data_lat;
    reg [DATA_WIDTH/8-1:0]  wr_strb_lat;
    reg                     aw_received;
    reg                     w_received;
    reg                     wr_en_r;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_state    <= WR_IDLE;
            aw_received <= 1'b0;
            w_received  <= 1'b0;
            wr_en_r     <= 1'b0;
        end else begin
            wr_en_r <= 1'b0;
            case (wr_state)
                WR_IDLE: begin
                    if (s_axil_awvalid) begin
                        wr_addr_lat <= s_axil_awaddr;
                        aw_received <= 1'b1;
                    end
                    if (s_axil_wvalid) begin
                        wr_data_lat <= s_axil_wdata;
                        wr_strb_lat <= s_axil_wstrb;
                        w_received  <= 1'b1;
                    end
                    if ((aw_received || s_axil_awvalid) &&
                        (w_received  || s_axil_wvalid)) begin
                        wr_en_r     <= 1'b1;
                        aw_received <= 1'b0;
                        w_received  <= 1'b0;
                        wr_state    <= WR_RESP;
                    end
                end
                WR_RESP: begin
                    if (s_axil_bvalid && s_axil_bready)
                        wr_state <= WR_IDLE;
                end
                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Read State Machine
    // =========================================================================
    localparam RD_IDLE = 1'b0;
    localparam RD_RESP = 1'b1;

    reg             rd_state;
    reg [ADDR_WIDTH-1:0] rd_addr_lat;
    reg             rd_en_r;
    reg [DATA_WIDTH-1:0] rd_data_lat;
    reg             rd_valid_r;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_state   <= RD_IDLE;
            rd_en_r    <= 1'b0;
            rd_valid_r <= 1'b0;
        end else begin
            rd_en_r <= 1'b0;
            case (rd_state)
                RD_IDLE: begin
                    if (s_axil_arvalid) begin
                        rd_addr_lat <= s_axil_araddr;
                        rd_en_r     <= 1'b1;
                        rd_state    <= RD_RESP;
                    end
                end
                RD_RESP: begin
                    if (reg_rd_ready) begin
                        rd_data_lat <= reg_rd_data;
                        rd_valid_r  <= 1'b1;
                    end
                    if (s_axil_rvalid && s_axil_rready) begin
                        rd_valid_r <= 1'b0;
                        rd_state   <= RD_IDLE;
                    end
                end
                default: rd_state <= RD_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Output assignments
    // =========================================================================
    // Write channel readies: accept whenever in IDLE
    assign s_axil_awready = (wr_state == WR_IDLE);
    assign s_axil_wready  = (wr_state == WR_IDLE);
    assign s_axil_bvalid  = (wr_state == WR_RESP);
    assign s_axil_bresp   = 2'b00; // OKAY

    assign s_axil_arready = (rd_state == RD_IDLE);
    assign s_axil_rvalid  = rd_valid_r;
    assign s_axil_rdata   = rd_data_lat;
    assign s_axil_rresp   = 2'b00; // OKAY

    // Register bus
    assign reg_wr_addr = wr_addr_lat;
    assign reg_wr_data = wr_data_lat;
    assign reg_wr_strb = wr_strb_lat;
    assign reg_wr_en   = wr_en_r;

    assign reg_rd_addr = rd_addr_lat;
    assign reg_rd_en   = rd_en_r;

endmodule
