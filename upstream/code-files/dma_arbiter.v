`timescale 1ns / 1ps

module dma_arbiter #(
    parameter NUM_CH = 4
)(
    input  wire                         aclk,
    input  wire                         aresetn,

    input  wire [1:0]                   arb_mode,

    // --- Read bus arbitration ---
    input  wire [NUM_CH-1:0]            rd_req,
    output reg  [NUM_CH-1:0]            rd_gnt,
    output reg  [$clog2(NUM_CH)-1:0]    rd_active_ch,
    output reg                          rd_busy,

    // --- Write bus arbitration ---
    input  wire [NUM_CH-1:0]            wr_req,
    output reg  [NUM_CH-1:0]            wr_gnt,
    output reg  [$clog2(NUM_CH)-1:0]    wr_active_ch,
    output reg                          wr_busy
);

    // =========================================================================
    // Round-Robin pointer registers
    // =========================================================================
    reg [$clog2(NUM_CH)-1:0]    rd_rr_ptr;      // last-granted channel (RR)
    reg [$clog2(NUM_CH)-1:0]    wr_rr_ptr;

    // =========================================================================
    // Read Arbiter
    // =========================================================================
    integer i;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_gnt       <= {NUM_CH{1'b0}};
            rd_active_ch <= {$clog2(NUM_CH){1'b0}};
            rd_busy      <= 1'b0;
            rd_rr_ptr    <= {$clog2(NUM_CH){1'b0}};
        end else begin
            if (!rd_busy) begin
                // Arbitrate: find next channel to grant
                if (|rd_req) begin
                    case (arb_mode)
                        2'b00, 2'b10: begin
                            // Round-Robin: start scanning from rr_ptr+1
                            begin : rd_rr
                                integer n;
                                reg [$clog2(NUM_CH)-1:0] candidate;
                                reg found;
                                found = 1'b0;
                                for (n = 0; n < NUM_CH; n = n + 1) begin
                                    candidate = (rd_rr_ptr + 1 + n) % NUM_CH;
                                    if (!found && rd_req[candidate]) begin
                                        rd_gnt[candidate] <= 1'b1;
                                        rd_active_ch      <= candidate;
                                        rd_busy           <= 1'b1;
                                        rd_rr_ptr         <= candidate;
                                        found = 1'b1;
                                    end
                                end
                            end
                        end
                        2'b01: begin
                            // Fixed Priority: Channel 0 has highest priority
                            begin : rd_fp
                                integer n;
                                reg found;
                                found = 1'b0;
                                for (n = 0; n < NUM_CH; n = n + 1) begin
                                    if (!found && rd_req[n]) begin
                                        rd_gnt[n]    <= 1'b1;
                                        rd_active_ch <= n[$clog2(NUM_CH)-1:0];
                                        rd_busy      <= 1'b1;
                                        found = 1'b1;
                                    end
                                end
                            end
                        end
                        default: begin
                            // Default: fixed priority
                            begin : rd_def
                                integer n;
                                reg found;
                                found = 1'b0;
                                for (n = 0; n < NUM_CH; n = n + 1) begin
                                    if (!found && rd_req[n]) begin
                                        rd_gnt[n]    <= 1'b1;
                                        rd_active_ch <= n[$clog2(NUM_CH)-1:0];
                                        rd_busy      <= 1'b1;
                                        found = 1'b1;
                                    end
                                end
                            end
                        end
                    endcase
                end
            end else begin
                // Hold grant until channel drops request
                if (!rd_req[rd_active_ch]) begin
                    rd_gnt  <= {NUM_CH{1'b0}};
                    rd_busy <= 1'b0;
                end
            end
        end
    end

    // =========================================================================
    // Write Arbiter (identical logic, separate state)
    // =========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_gnt       <= {NUM_CH{1'b0}};
            wr_active_ch <= {$clog2(NUM_CH){1'b0}};
            wr_busy      <= 1'b0;
            wr_rr_ptr    <= {$clog2(NUM_CH){1'b0}};
        end else begin
            if (!wr_busy) begin
                if (|wr_req) begin
                    case (arb_mode)
                        2'b00, 2'b10: begin
                            begin : wr_rr
                                integer n;
                                reg [$clog2(NUM_CH)-1:0] candidate;
                                reg found;
                                found = 1'b0;
                                for (n = 0; n < NUM_CH; n = n + 1) begin
                                    candidate = (wr_rr_ptr + 1 + n) % NUM_CH;
                                    if (!found && wr_req[candidate]) begin
                                        wr_gnt[candidate] <= 1'b1;
                                        wr_active_ch      <= candidate;
                                        wr_busy           <= 1'b1;
                                        wr_rr_ptr         <= candidate;
                                        found = 1'b1;
                                    end
                                end
                            end
                        end
                        2'b01: begin
                            begin : wr_fp
                                integer n;
                                reg found;
                                found = 1'b0;
                                for (n = 0; n < NUM_CH; n = n + 1) begin
                                    if (!found && wr_req[n]) begin
                                        wr_gnt[n]    <= 1'b1;
                                        wr_active_ch <= n[$clog2(NUM_CH)-1:0];
                                        wr_busy      <= 1'b1;
                                        found = 1'b1;
                                    end
                                end
                            end
                        end
                        default: begin
                            begin : wr_def
                                integer n;
                                reg found;
                                found = 1'b0;
                                for (n = 0; n < NUM_CH; n = n + 1) begin
                                    if (!found && wr_req[n]) begin
                                        wr_gnt[n]    <= 1'b1;
                                        wr_active_ch <= n[$clog2(NUM_CH)-1:0];
                                        wr_busy      <= 1'b1;
                                        found = 1'b1;
                                    end
                                end
                            end
                        end
                    endcase
                end
            end else begin
                if (!wr_req[wr_active_ch]) begin
                    wr_gnt  <= {NUM_CH{1'b0}};
                    wr_busy <= 1'b0;
                end
            end
        end
    end

endmodule
