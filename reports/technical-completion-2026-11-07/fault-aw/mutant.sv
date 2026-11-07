`timescale 1ns/1ps

// Bounded one-channel DMA derived from the jointly developed MIT DMA-PROTOCOL
// project. Original upstream RTL is preserved under upstream/code-files/.
module axi4_dma_subsystem (
    input  logic        aclk,
    input  logic        aresetn,

    input  logic [31:0] s_axil_awaddr,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,
    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,
    output logic [1:0]  s_axil_bresp,
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,
    input  logic [31:0] s_axil_araddr,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,
    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp,
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,
    output logic        irq,

    output logic [3:0]  m_axi_awid,
    output logic [31:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [63:0] m_axi_wdata,
    output logic [7:0]  m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    input  logic [3:0]  m_axi_bid,
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    output logic [3:0]  m_axi_arid,
    output logic [31:0] m_axi_araddr,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    input  logic [3:0]  m_axi_rid,
    input  logic [63:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rlast,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready
);
    localparam logic [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;
    localparam logic [2:0] ERR_NONE = 0, ERR_REQUEST = 1,
                           ERR_READ = 2, ERR_WRITE = 3;
    typedef enum logic [2:0] {
        IDLE, PLAN, SEND_AR, READ_DATA, WRITE_CHANNELS, WAIT_B
    } state_t;
    state_t state;

    logic [31:0] src_reg, dst_reg, len_reg;
    logic [31:0] cur_src, cur_dst, remaining;
    logic [4:0]  beats, read_index, write_index;
    logic [12:0] chunk_bytes;
    logic [63:0] burst_buffer [0:15];
    logic        read_fault;
    logic        aw_done, w_done;
    logic        done_reg, error_reg;
    logic [2:0]  error_code;

    logic        aw_held, w_held;
    logic [31:0] aw_address, w_data;
    logic [3:0]  w_strobes;

    logic [12:0] plan_beats, plan_bytes;
    logic [12:0] source_page_beats, dest_page_beats;
    logic [32:0] source_end, dest_end;
    logic        invalid_request;

    always_comb begin
        plan_beats = (remaining + 32'd7) >> 3;
        source_page_beats = (13'd4096 - {1'b0, cur_src[11:0]}) >> 3;
        dest_page_beats = (13'd4096 - {1'b0, cur_dst[11:0]}) >> 3;
        if (plan_beats > 13'd16) plan_beats = 13'd16;
        if (plan_beats > source_page_beats) plan_beats = source_page_beats;
        if (plan_beats > dest_page_beats) plan_beats = dest_page_beats;
        if (remaining < (plan_beats << 3)) plan_bytes = remaining[12:0];
        else plan_bytes = plan_beats << 3;

        source_end = {1'b0, src_reg} + {1'b0, len_reg};
        dest_end   = {1'b0, dst_reg} + {1'b0, len_reg};
        invalid_request = (len_reg > 32'd4096) ||
                          (src_reg[2:0] != 3'b000) ||
                          (dst_reg[2:0] != 3'b000) ||
                          (source_end > 33'h1_0000_0000) ||
                          (dest_end > 33'h1_0000_0000) ||
                          (({1'b0, src_reg} < dest_end) &&
                           ({1'b0, dst_reg} < source_end));
    end

    assign irq = done_reg;
    assign s_axil_awready = !aw_held && !s_axil_bvalid;
    assign s_axil_wready  = !w_held && !s_axil_bvalid;
    assign s_axil_arready = !s_axil_rvalid;

    assign m_axi_awid = 4'd0;
    assign m_axi_awaddr = cur_dst;
    assign m_axi_awlen = {3'b000, beats} - 8'd1;
    assign m_axi_awsize = 3'd3;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awvalid = (state == WRITE_CHANNELS) && !aw_done;
    assign m_axi_wdata = burst_buffer[write_index[3:0]];
    assign m_axi_wlast = (write_index == beats - 5'd1);
    assign m_axi_wvalid = (state == WRITE_CHANNELS) && !w_done;
    assign m_axi_bready = (state == WAIT_B);
    always_comb begin
        m_axi_wstrb = 8'hFF;
        if ((write_index == beats - 5'd1) && (chunk_bytes[2:0] != 3'd0))
            m_axi_wstrb = 8'hFF >> (4'd8 - {1'b0, chunk_bytes[2:0]});
    end

    assign m_axi_arid = 4'd0;
    assign m_axi_araddr = cur_src;
    assign m_axi_arlen = {3'b000, beats} - 8'd1;
    assign m_axi_arsize = 3'd3;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arvalid = (state == SEND_AR);
    assign m_axi_rready = (state == READ_DATA);

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state <= IDLE;
            src_reg <= 0; dst_reg <= 0; len_reg <= 0;
            cur_src <= 0; cur_dst <= 0; remaining <= 0;
            beats <= 0; read_index <= 0; write_index <= 0;
            chunk_bytes <= 0; read_fault <= 0;
            aw_done <= 0; w_done <= 0;
            done_reg <= 0; error_reg <= 0; error_code <= ERR_NONE;
            aw_held <= 0; w_held <= 0; aw_address <= 0;
            w_data <= 0; w_strobes <= 0;
            s_axil_bvalid <= 0; s_axil_bresp <= RESP_OKAY;
            s_axil_rvalid <= 0; s_axil_rresp <= RESP_OKAY; s_axil_rdata <= 0;
        end else begin
            if (s_axil_awvalid && s_axil_awready) begin
                aw_held <= 1;
                aw_address <= s_axil_awaddr;
            end
            if (s_axil_wvalid && s_axil_wready) begin
                w_held <= 1;
                w_data <= s_axil_wdata;
                w_strobes <= s_axil_wstrb;
            end
            if (s_axil_bvalid && s_axil_bready) s_axil_bvalid <= 0;
            if (aw_held && w_held && !s_axil_bvalid) begin
                aw_held <= 0;
                w_held <= 0;
                s_axil_bvalid <= 1;
                s_axil_bresp <= RESP_OKAY;
                if (w_strobes != 4'hF) begin
                    s_axil_bresp <= RESP_SLVERR;
                end else begin
                    case (aw_address)
                        32'h00: if (state == IDLE) src_reg <= w_data;
                                 else s_axil_bresp <= RESP_SLVERR;
                        32'h04: if (state == IDLE) dst_reg <= w_data;
                                 else s_axil_bresp <= RESP_SLVERR;
                        32'h08: if (state == IDLE) len_reg <= w_data;
                                 else s_axil_bresp <= RESP_SLVERR;
                        32'h0C: begin
                            if (state != IDLE || w_data[31:2] != 0 ||
                                w_data[1:0] == 2'b11) begin
                                s_axil_bresp <= RESP_SLVERR;
                            end else if (w_data[1]) begin
                                done_reg <= 0; error_reg <= 0;
                                error_code <= ERR_NONE;
                            end else if (w_data[0]) begin
                                done_reg <= 0; error_reg <= 0;
                                error_code <= ERR_NONE;
                                if (len_reg == 0) begin
                                    done_reg <= 1;
                                end else if (invalid_request) begin
                                    done_reg <= 1;
                                    error_reg <= 1;
                                    error_code <= ERR_REQUEST;
                                end else begin
                                    cur_src <= src_reg;
                                    cur_dst <= dst_reg;
                                    remaining <= len_reg;
                                    state <= PLAN;
                                end
                            end
                        end
                        default: s_axil_bresp <= RESP_SLVERR;
                    endcase
                end
            end
            if (s_axil_rvalid && s_axil_rready) s_axil_rvalid <= 0;
            if (s_axil_arvalid && s_axil_arready) begin
                s_axil_rvalid <= 1;
                s_axil_rresp <= RESP_OKAY;
                case (s_axil_araddr)
                    32'h00: s_axil_rdata <= src_reg;
                    32'h04: s_axil_rdata <= dst_reg;
                    32'h08: s_axil_rdata <= len_reg;
                    32'h0C: s_axil_rdata <= 0;
                    32'h10: s_axil_rdata <= {28'd0, done_reg, error_reg,
                                             done_reg, (state != IDLE)};
                    32'h14: s_axil_rdata <= {29'd0, error_code};
                    default: begin
                        s_axil_rdata <= 0;
                        s_axil_rresp <= RESP_SLVERR;
                    end
                endcase
            end

            case (state)
                IDLE: ;
                PLAN: begin
                    beats <= plan_beats[4:0];
                    chunk_bytes <= plan_bytes;
                    read_index <= 0;
                    write_index <= 0;
                    read_fault <= 0;
                    aw_done <= 0;
                    w_done <= 0;
                    state <= SEND_AR;
                end
                SEND_AR: if (m_axi_arvalid && m_axi_arready) state <= READ_DATA;
                READ_DATA: if (m_axi_rvalid && m_axi_rready) begin
                    burst_buffer[read_index[3:0]] <= m_axi_rdata;
                    if (m_axi_rresp != RESP_OKAY || m_axi_rid != 4'd0 ||
                        m_axi_rlast != (read_index == beats - 5'd1))
                        read_fault <= 1;
                    if (m_axi_rlast || read_index == beats - 5'd1) begin
                        if (read_fault || m_axi_rresp != RESP_OKAY ||
                            m_axi_rid != 4'd0 ||
                            m_axi_rlast != (read_index == beats - 5'd1)) begin
                            state <= IDLE;
                            done_reg <= 1;
                            error_reg <= 1;
                            error_code <= ERR_READ;
                        end else begin
                            state <= WRITE_CHANNELS;
                        end
                    end else read_index <= read_index + 5'd1;
                end
                WRITE_CHANNELS: begin
                    if (m_axi_awvalid && m_axi_awready) aw_done <= 0;
                    if (m_axi_wvalid && m_axi_wready) begin
                        if (write_index == beats - 5'd1) w_done <= 1;
                        else write_index <= write_index + 5'd1;
                    end
                    if ((aw_done || (m_axi_awvalid && m_axi_awready)) &&
                        (w_done || (m_axi_wvalid && m_axi_wready &&
                                    write_index == beats - 5'd1)))
                        state <= WAIT_B;
                end
                WAIT_B: if (m_axi_bvalid && m_axi_bready) begin
                    if (m_axi_bresp != RESP_OKAY || m_axi_bid != 4'd0) begin
                        state <= IDLE;
                        done_reg <= 1;
                        error_reg <= 1;
                        error_code <= ERR_WRITE;
                    end else if (remaining <= {19'd0, chunk_bytes}) begin
                        state <= IDLE;
                        done_reg <= 1;
                    end else begin
                        cur_src <= cur_src + {19'd0, chunk_bytes};
                        cur_dst <= cur_dst + {19'd0, chunk_bytes};
                        remaining <= remaining - {19'd0, chunk_bytes};
                        state <= PLAN;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
