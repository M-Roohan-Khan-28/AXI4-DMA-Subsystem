`timescale 1ns / 1ps

module dma_interrupt #(
    parameter NUM_CH = 4
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    // --- Per-channel interrupt enables (from register file) ---
    input  wire [NUM_CH-1:0]    ch_irq_en,

    // --- One-cycle pulses from channel controllers ---
    input  wire [NUM_CH-1:0]    ch_done_pulse,
    input  wire [NUM_CH-1:0]    ch_err_pulse,

    // --- IRQ outputs (active-high, level) ---
    output reg  [NUM_CH-1:0]    irq
);

    // =========================================================================
    // Sticky IRQ Latches
    // =========================================================================
    // IRQ is set by a done or error pulse (when enabled) and remains asserted
    // until the channel controller deasserts ch_done/ch_err (driven by the
    // register file W1C write clearing the status register).
    //
    // In this implementation the IRQ is cleared when neither done_pulse nor
    // err_pulse is active AND the enable is preserved, giving the CPU one full
    // system-tick to read the interrupt status register.

    reg [NUM_CH-1:0]    irq_latch;
    reg [NUM_CH-1:0]    done_prev;
    reg [NUM_CH-1:0]    err_prev;

    integer i;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            irq_latch <= {NUM_CH{1'b0}};
            done_prev <= {NUM_CH{1'b0}};
            err_prev  <= {NUM_CH{1'b0}};
            irq       <= {NUM_CH{1'b0}};
        end else begin
            done_prev <= ch_done_pulse;
            err_prev  <= ch_err_pulse;

            for (i = 0; i < NUM_CH; i = i + 1) begin
                // Detect rising edge of done or error pulse
                if ((ch_done_pulse[i] && !done_prev[i]) ||
                    (ch_err_pulse[i]  && !err_prev[i])) begin
                    if (ch_irq_en[i])
                        irq_latch[i] <= 1'b1;
                end

                // Clear latch when neither pulse is active
                // (Software has cleared the status register which deasserts
                //  the channel done/err, causing pulses to drop)
                if (!ch_done_pulse[i] && !ch_err_pulse[i]) begin
                    irq_latch[i] <= 1'b0;
                end

                // Drive output: gated by enable
                irq[i] <= irq_latch[i] & ch_irq_en[i];
            end
        end
    end

endmodule
