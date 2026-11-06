`timescale 1ns/1ps
module tb_dma_portable;
    localparam int MEM_SIZE = 32768;
    logic aclk = 0;
    always #5 aclk = ~aclk;
    logic aresetn = 0;
    logic [31:0] s_axil_awaddr, s_axil_wdata, s_axil_araddr;
    logic [3:0] s_axil_wstrb;
    logic s_axil_awvalid, s_axil_awready, s_axil_wvalid, s_axil_wready;
    logic [1:0] s_axil_bresp, s_axil_rresp;
    logic s_axil_bvalid, s_axil_bready, s_axil_arvalid, s_axil_arready;
    logic [31:0] s_axil_rdata;
    logic s_axil_rvalid, s_axil_rready, irq;
    logic [3:0] m_axi_awid, m_axi_bid, m_axi_arid, m_axi_rid;
    logic [31:0] m_axi_awaddr, m_axi_araddr;
    logic [7:0] m_axi_awlen, m_axi_wstrb, m_axi_arlen;
    logic [2:0] m_axi_awsize, m_axi_arsize;
    logic [1:0] m_axi_awburst, m_axi_bresp, m_axi_arburst, m_axi_rresp;
    logic m_axi_awvalid, m_axi_awready, m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic m_axi_bvalid, m_axi_bready, m_axi_arvalid, m_axi_arready;
    logic m_axi_rlast, m_axi_rvalid, m_axi_rready;
    logic [63:0] m_axi_wdata, m_axi_rdata;
    axi4_dma_subsystem dut (.*);

    byte unsigned mem [0:MEM_SIZE-1];
    byte unsigned expected [0:MEM_SIZE-1];
    int cycle_count = 0;
    int checks = 0;
    int protocol_checks = 0;
    int cases = 0;
    int ar_count = 0, aw_count = 0, r_count = 0, w_count = 0, written_bytes = 0;
    int read_addr, read_beats, read_index, write_addr, write_beats, write_index;
    int b_delay;
    bit read_active, write_active, b_pending;
    bit inject_read_error, inject_write_error;
    bit aw_stalled, ar_stalled, w_stalled;
    logic [31:0] aw_hold_addr, ar_hold_addr;
    logic [7:0] aw_hold_len, ar_hold_len, w_hold_strb;
    logic [63:0] w_hold_data;
    logic w_hold_last;
    bit oracle_active, oracle_ar_seen, oracle_aw_seen;
    bit aw_waits_wvalid, w_before_aw_mode, early_w_done;
    logic [63:0] early_w_data;
    logic [7:0] early_w_strb;
    int aw_only_stalls, w_only_stalls;
    int oracle_src, oracle_dst, oracle_remaining, oracle_chunk;
    int oracle_r_index, oracle_w_index, oracle_beats;

    assign m_axi_awready = aresetn && !write_active && !b_pending &&
                           !m_axi_bvalid && ((cycle_count % 5) != 0) &&
                           (!aw_waits_wvalid || m_axi_wvalid) &&
                           (!w_before_aw_mode || early_w_done);
    assign m_axi_arready = aresetn && !read_active && !m_axi_rvalid &&
                           ((cycle_count % 7) != 0);
    assign m_axi_wready = aresetn &&
                          (write_active || (w_before_aw_mode && !early_w_done && !b_pending)) &&
                          ((cycle_count % 4) != 0);

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            cycle_count <= 0;
            read_active <= 0; read_addr <= 0; read_beats <= 0; read_index <= 0;
            write_active <= 0; write_addr <= 0; write_beats <= 0; write_index <= 0;
            b_pending <= 0; b_delay <= 0;
            m_axi_rvalid <= 0; m_axi_rdata <= 0; m_axi_rresp <= 0;
            m_axi_rlast <= 0; m_axi_rid <= 0;
            m_axi_bvalid <= 0; m_axi_bresp <= 0; m_axi_bid <= 0;
            aw_stalled <= 0; ar_stalled <= 0; w_stalled <= 0;
            early_w_done <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (m_axi_awvalid && !m_axi_awready && m_axi_wvalid && m_axi_wready)
                aw_only_stalls++;
            if (m_axi_wvalid && !m_axi_wready && m_axi_awvalid && m_axi_awready)
                w_only_stalls++;
            if (aw_stalled &&
                (!m_axi_awvalid || m_axi_awaddr !== aw_hold_addr ||
                 m_axi_awlen !== aw_hold_len))
                $fatal(1, "AW payload changed while stalled");
            if (ar_stalled &&
                (!m_axi_arvalid || m_axi_araddr !== ar_hold_addr ||
                 m_axi_arlen !== ar_hold_len))
                $fatal(1, "AR payload changed while stalled");
            if (w_stalled &&
                (!m_axi_wvalid || m_axi_wdata !== w_hold_data ||
                 m_axi_wstrb !== w_hold_strb || m_axi_wlast !== w_hold_last))
                $fatal(1, "W payload changed while stalled");
            aw_stalled <= m_axi_awvalid && !m_axi_awready;
            ar_stalled <= m_axi_arvalid && !m_axi_arready;
            w_stalled <= m_axi_wvalid && !m_axi_wready;
            if (m_axi_awvalid && !m_axi_awready) begin
                aw_hold_addr <= m_axi_awaddr; aw_hold_len <= m_axi_awlen;
            end
            if (m_axi_arvalid && !m_axi_arready) begin
                ar_hold_addr <= m_axi_araddr; ar_hold_len <= m_axi_arlen;
            end
            if (m_axi_wvalid && !m_axi_wready) begin
                w_hold_data <= m_axi_wdata; w_hold_strb <= m_axi_wstrb;
                w_hold_last <= m_axi_wlast;
            end

            if (m_axi_arvalid && m_axi_arready) begin
                if (oracle_active) begin
                    if (oracle_ar_seen || oracle_remaining <= 0)
                        $fatal(1, "Unexpected or duplicate AR");
                    oracle_chunk = first_chunk(oracle_src, oracle_dst, oracle_remaining);
                    oracle_beats = (oracle_chunk + 7) / 8;
                    if (m_axi_araddr !== oracle_src || m_axi_arlen !== oracle_beats-1)
                        $fatal(1, "AR oracle mismatch got=%h/%0d expected=%h/%0d",
                               m_axi_araddr, m_axi_arlen, oracle_src, oracle_beats-1);
                    oracle_ar_seen = 1;
                    oracle_r_index = 0;
                    oracle_w_index = 0;
                    protocol_checks += 2;
                end
                if (m_axi_arid !== 0 || m_axi_arsize !== 3 ||
                    m_axi_arburst !== 2'b01 || m_axi_arlen > 15 ||
                    m_axi_araddr[2:0] !== 0 ||
                    (int'(m_axi_araddr[11:0]) + (int'(m_axi_arlen)+1)*8) > 4096 ||
                    (int'(m_axi_araddr) + (int'(m_axi_arlen)+1)*8) > MEM_SIZE)
                    $fatal(1, "Invalid AR burst addr=%h len=%d", m_axi_araddr, m_axi_arlen);
                read_active <= 1;
                read_addr <= int'(m_axi_araddr);
                read_beats <= int'(m_axi_arlen) + 1;
                read_index <= 0;
                ar_count <= ar_count + 1;
                protocol_checks++;
            end
            if (m_axi_rvalid && m_axi_rready) begin
                if (oracle_active) begin
                    if (!oracle_ar_seen || oracle_r_index >= oracle_beats ||
                        m_axi_rlast !== (oracle_r_index == oracle_beats-1))
                        $fatal(1, "R progression mismatch index=%0d", oracle_r_index);
                    for (int lane=0; lane<8; lane++) begin
                        if (oracle_r_index*8+lane < oracle_chunk &&
                            m_axi_rdata[lane*8 +: 8] !== expected[oracle_src+oracle_r_index*8+lane])
                            $fatal(1, "R source-data mismatch at %h", oracle_src+oracle_r_index*8+lane);
                        protocol_checks++;
                    end
                    oracle_r_index++;
                end
                r_count <= r_count + 1;
                protocol_checks++;
                m_axi_rvalid <= 0;
                if (read_index == read_beats - 1) read_active <= 0;
                else read_index <= read_index + 1;
            end else if (read_active && !m_axi_rvalid && (cycle_count % 3 != 0)) begin
                for (int lane = 0; lane < 8; lane++)
                    m_axi_rdata[lane*8 +: 8] <= mem[read_addr + read_index*8 + lane];
                m_axi_rid <= 0;
                m_axi_rresp <= (inject_read_error && read_index == 0) ? 2'b10 : 2'b00;
                m_axi_rlast <= (read_index == read_beats - 1);
                m_axi_rvalid <= 1;
            end

            if (m_axi_awvalid && m_axi_awready) begin
                if (oracle_active) begin
                    if (!oracle_ar_seen || oracle_aw_seen || oracle_r_index != oracle_beats)
                        $fatal(1, "Unexpected or premature AW");
                    if (m_axi_awaddr !== oracle_dst || m_axi_awlen !== oracle_beats-1)
                        $fatal(1, "AW oracle mismatch got=%h/%0d expected=%h/%0d",
                               m_axi_awaddr, m_axi_awlen, oracle_dst, oracle_beats-1);
                    oracle_aw_seen = 1;
                    protocol_checks += 2;
                end
                if (m_axi_awid !== 0 || m_axi_awsize !== 3 ||
                    m_axi_awburst !== 2'b01 || m_axi_awlen > 15 ||
                    m_axi_awaddr[2:0] !== 0 ||
                    (int'(m_axi_awaddr[11:0]) + (int'(m_axi_awlen)+1)*8) > 4096 ||
                    (int'(m_axi_awaddr) + (int'(m_axi_awlen)+1)*8) > MEM_SIZE)
                    $fatal(1, "Invalid AW burst addr=%h len=%d", m_axi_awaddr, m_axi_awlen);
                write_addr <= int'(m_axi_awaddr);
                write_beats <= int'(m_axi_awlen) + 1;
                write_index <= 0;
                if (w_before_aw_mode && early_w_done) begin
                    if (m_axi_awlen != 0) $fatal(1,"W-first model only supports one beat");
                    for (int lane=0; lane<8; lane++)
                        if (early_w_strb[lane]) begin
                            mem[int'(m_axi_awaddr)+lane] <= early_w_data[lane*8 +: 8];
                            written_bytes++;
                        end
                    b_pending <= 1;
                    b_delay <= 4;
                end else write_active <= 1;
                aw_count <= aw_count + 1;
                protocol_checks++;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                w_count <= w_count + 1;
                protocol_checks++;
                if (oracle_active) begin
                    if (!oracle_ar_seen || oracle_w_index >= oracle_beats ||
                        m_axi_wlast !== (oracle_w_index == oracle_beats-1))
                        $fatal(1, "W progression mismatch index=%0d", oracle_w_index);
                    for (int lane=0; lane<8; lane++) begin
                        bit should_write;
                        should_write = oracle_w_index*8+lane < oracle_chunk;
                        if (m_axi_wstrb[lane] !== should_write)
                            $fatal(1, "W strobe mismatch beat=%0d lane=%0d",oracle_w_index,lane);
                        if (should_write && m_axi_wdata[lane*8 +: 8] !==
                            expected[oracle_src+oracle_w_index*8+lane])
                            $fatal(1, "W data mismatch source=%h",oracle_src+oracle_w_index*8+lane);
                        protocol_checks++;
                    end
                    oracle_w_index++;
                end
                if (w_before_aw_mode && !write_active) begin
                    if (!m_axi_wlast) $fatal(1,"Expected one W-first beat");
                    early_w_data <= m_axi_wdata;
                    early_w_strb <= m_axi_wstrb;
                    early_w_done <= 1;
                end else begin
                if (m_axi_wlast !== (write_index == write_beats - 1))
                    $fatal(1, "WLAST mismatch beat=%0d total=%0d", write_index, write_beats);
                for (int lane = 0; lane < 8; lane++)
                    if (m_axi_wstrb[lane]) begin
                        mem[write_addr + write_index*8 + lane] <= m_axi_wdata[lane*8 +: 8];
                        written_bytes++;
                    end
                if (write_index == write_beats - 1) begin
                    write_active <= 0;
                    b_pending <= 1;
                    b_delay <= 4;
                end else write_index <= write_index + 1;
                end
            end
            if (b_pending && !m_axi_bvalid) begin
                if (b_delay != 0) b_delay <= b_delay - 1;
                else begin
                    m_axi_bvalid <= 1;
                    m_axi_bid <= 0;
                    m_axi_bresp <= inject_write_error ? 2'b10 : 2'b00;
                end
            end
            if (m_axi_bvalid && m_axi_bready) begin
                if (oracle_active) begin
                    if (!oracle_ar_seen || !oracle_aw_seen ||
                        oracle_r_index != oracle_beats || oracle_w_index != oracle_beats)
                        $fatal(1, "B before complete oracle burst");
                    oracle_src += oracle_chunk;
                    oracle_dst += oracle_chunk;
                    oracle_remaining -= oracle_chunk;
                    oracle_ar_seen = 0; oracle_aw_seen = 0;
                    protocol_checks++;
                end
                m_axi_bvalid <= 0;
                b_pending <= 0;
                protocol_checks++;
            end
        end
    end

    task automatic reset_case;
        int unsigned init_rng;
        oracle_active = 0;
        s_axil_awaddr = 0; s_axil_awvalid = 0;
        s_axil_wdata = 0; s_axil_wstrb = 4'hF; s_axil_wvalid = 0;
        s_axil_bready = 0; s_axil_araddr = 0; s_axil_arvalid = 0;
        s_axil_rready = 0;
        inject_read_error = 0; inject_write_error = 0;
        aw_waits_wvalid = 0; w_before_aw_mode = 0;
        aresetn = 0;
        repeat (3) @(negedge aclk);
        init_rng = 32'h28A6_BEEF;
        for (int i = 0; i < MEM_SIZE; i++) begin
            init_rng = init_rng * 32'd1664525 + 32'd1013904223;
            mem[i] = init_rng[31:24];
            expected[i] = mem[i];
        end
        aresetn = 1;
        repeat (2) @(negedge aclk);
    endtask

    task automatic write_reg_split(input logic [31:0] addr, input logic [31:0] data,
                                   input bit address_first);
        @(negedge aclk);
        s_axil_bready = 0;
        s_axil_awaddr = addr; s_axil_wdata = data; s_axil_wstrb = 4'hF;
        if (address_first) begin
            s_axil_awvalid = 1;
            do @(posedge aclk); while (!s_axil_awready);
            @(negedge aclk); s_axil_awvalid = 0;
            repeat (3) @(negedge aclk);
            s_axil_wvalid = 1;
            do @(posedge aclk); while (!s_axil_wready);
            @(negedge aclk); s_axil_wvalid = 0;
        end else begin
            s_axil_wvalid = 1;
            do @(posedge aclk); while (!s_axil_wready);
            @(negedge aclk); s_axil_wvalid = 0;
            repeat (3) @(negedge aclk);
            s_axil_awvalid = 1;
            do @(posedge aclk); while (!s_axil_awready);
            @(negedge aclk); s_axil_awvalid = 0;
        end
        while (!s_axil_bvalid) @(negedge aclk);
        if (s_axil_bresp !== 2'b00)
            $fatal(1, "Split AXI-Lite write response addr=%h got=%b", addr, s_axil_bresp);
        checks++;
        s_axil_bready = 1;
        @(negedge aclk); s_axil_bready = 0;
    endtask

    task automatic write_reg(input logic [31:0] addr, input logic [31:0] data,
                             input logic [1:0] expected_resp, input logic [3:0] strb = 4'hF);
        bit aw_done, w_done;
        @(negedge aclk);
        s_axil_awaddr = addr; s_axil_awvalid = 1;
        s_axil_wdata = data; s_axil_wstrb = strb; s_axil_wvalid = 1;
        s_axil_bready = 0; aw_done = 0; w_done = 0;
        while (!aw_done || !w_done) begin
            @(posedge aclk);
            if (s_axil_awvalid && s_axil_awready) aw_done = 1;
            if (s_axil_wvalid && s_axil_wready) w_done = 1;
            @(negedge aclk);
            if (aw_done) s_axil_awvalid = 0;
            if (w_done) s_axil_wvalid = 0;
        end
        while (!s_axil_bvalid) @(negedge aclk);
        if (s_axil_bresp !== expected_resp)
            $fatal(1, "AXI-Lite write response addr=%h got=%b expected=%b",
                   addr, s_axil_bresp, expected_resp);
        checks++;
        s_axil_bready = 1;
        @(negedge aclk);
        s_axil_bready = 0;
    endtask

    task automatic read_reg(input logic [31:0] addr, input logic [1:0] expected_resp,
                            output logic [31:0] data);
        @(negedge aclk);
        s_axil_araddr = addr; s_axil_arvalid = 1; s_axil_rready = 0;
        do @(posedge aclk); while (!(s_axil_arvalid && s_axil_arready));
        @(negedge aclk); s_axil_arvalid = 0;
        while (!s_axil_rvalid) @(negedge aclk);
        data = s_axil_rdata;
        if (s_axil_rresp !== expected_resp)
            $fatal(1, "AXI-Lite read response addr=%h got=%b expected=%b",
                   addr, s_axil_rresp, expected_resp);
        checks++;
        s_axil_rready = 1;
        @(negedge aclk); s_axil_rready = 0;
    endtask

    function automatic int first_chunk(input int src, input int dst, input int len);
        int beats;
        beats = (len + 7) / 8;
        if (beats > 16) beats = 16;
        if (beats > (4096 - (src % 4096))/8) beats = (4096 - (src % 4096))/8;
        if (beats > (4096 - (dst % 4096))/8) beats = (4096 - (dst % 4096))/8;
        first_chunk = (len < beats*8) ? len : beats*8;
    endfunction

    function automatic int expected_bursts(input int src, input int dst, input int len);
        int n, remaining_bytes, s, d;
        expected_bursts = 0; remaining_bytes = len; s = src; d = dst;
        while (remaining_bytes > 0) begin
            n = first_chunk(s, d, remaining_bytes);
            remaining_bytes -= n; s += n; d += n;
            expected_bursts++;
        end
    endfunction

    task automatic wait_irq;
        int timeout;
        timeout = 0;
        while (!irq && timeout < 50000) begin
            @(negedge aclk);
            timeout++;
        end
        if (!irq) $fatal(1, "DMA completion timeout");
        checks++;
    endtask

    task automatic run_case(input string label, input int src, input int dst,
                            input int len, input bit read_error = 0,
                            input bit write_error = 0, input bit busy_probe = 0);
        int ar_before, aw_before, r_before, w_before, bytes_before;
        int aw_stalls_before, w_stalls_before;
        int bytes_to_copy, burst_expected, beats_expected;
        logic [31:0] status, code;
        bit invalid;
        reset_case();
        invalid = len > 4096 || ((src % 8) != 0) || ((dst % 8) != 0) ||
                  ((len > 0) && (({1'b0,src[31:0]} + len > 33'h1_0000_0000) ||
                                 ({1'b0,dst[31:0]} + len > 33'h1_0000_0000) ||
                                 ((src < dst+len) && (dst < src+len))));
        if (len == 0) invalid = 0;
        inject_read_error = read_error;
        inject_write_error = write_error;
        ar_before = ar_count; aw_before = aw_count;
        r_before = r_count; w_before = w_count;
        bytes_before = written_bytes;
        aw_stalls_before = aw_only_stalls;
        w_stalls_before = w_only_stalls;
        if (label == "axil_aw_first") write_reg_split(32'h00, src, 1);
        else if (label == "axil_w_first") write_reg_split(32'h00, src, 0);
        else write_reg(32'h00, src, 0);
        write_reg(32'h04, dst, 0);
        write_reg(32'h08, len, 0);
        oracle_src = src; oracle_dst = dst; oracle_remaining = len;
        oracle_ar_seen = 0; oracle_aw_seen = 0;
        oracle_r_index = 0; oracle_w_index = 0; oracle_active = 1;
        aw_waits_wvalid = (label == "awready_waits_wvalid");
        w_before_aw_mode = (label == "w_before_aw");
        read_reg(32'h00, 0, status);
        if (status !== src) $fatal(1, "%s source register readback", label);
        read_reg(32'h04, 0, status);
        if (status !== dst) $fatal(1, "%s destination register readback", label);
        read_reg(32'h08, 0, status);
        if (status !== len) $fatal(1, "%s length register readback", label);
        checks += 3;
        write_reg(32'h0C, 1, 0);
        if (busy_probe) begin
            write_reg(32'h00, 32'h1234, 2'b10);
            write_reg(32'h0C, 1, 2'b10);
            write_reg(32'h0C, 2, 2'b10);
        end
        wait_irq();
        read_reg(32'h10, 0, status);
        read_reg(32'h14, 0, code);
        if (status[3:0] !== {1'b1, (invalid || read_error || write_error), 1'b1, 1'b0})
            $fatal(1, "%s status=%h", label, status);
        if (code[2:0] !== (invalid ? 3'd1 : read_error ? 3'd2 : write_error ? 3'd3 : 3'd0))
            $fatal(1, "%s code=%h", label, code);
        checks += 2;
        bytes_to_copy = 0;
        if (!invalid && len > 0 && !read_error)
            bytes_to_copy = write_error ? first_chunk(src,dst,len) : len;
        for (int j = 0; j < bytes_to_copy; j++) expected[dst+j] = expected[src+j];
        for (int j = 0; j < MEM_SIZE; j++) begin
            if (mem[j] !== expected[j])
                $fatal(1, "%s memory mismatch address=%h got=%h expected=%h",
                       label, j, mem[j], expected[j]);
            checks++;
        end
        burst_expected = (!invalid && len > 0) ?
                         ((read_error || write_error) ? 1 : expected_bursts(src,dst,len)) : 0;
        beats_expected = (!invalid && len > 0) ?
                         ((read_error || write_error) ? ((first_chunk(src,dst,len)+7)/8) : ((len+7)/8)) : 0;
        if (ar_count - ar_before != burst_expected ||
            aw_count - aw_before != (read_error ? 0 : burst_expected) ||
            r_count - r_before != beats_expected ||
            w_count - w_before != (read_error ? 0 : beats_expected) ||
            written_bytes - bytes_before != bytes_to_copy)
            $fatal(1, "%s accepted bus mismatch AR=%0d AW=%0d R=%0d W=%0d expected bursts=%0d beats=%0d",
                   label, ar_count-ar_before, aw_count-aw_before,
                   r_count-r_before, w_count-w_before, burst_expected, beats_expected);
        checks++;
        if (label == "awready_waits_wvalid" && w_only_stalls == w_stalls_before)
            $fatal(1,"AWREADY-WVALID dependency did not stall W independently");
        if (label == "w_before_aw" && aw_only_stalls == aw_stalls_before)
            $fatal(1,"W-before-AW ordering not observed");
        if (label == "awready_waits_wvalid" || label == "w_before_aw") checks++;
        if (!read_error && !write_error && !invalid && oracle_remaining != 0)
            $fatal(1, "%s oracle remaining=%0d",label,oracle_remaining);
        oracle_active = 0;
        write_reg(32'h0C, 2, 0);
        read_reg(32'h10, 0, status);
        if (status != 0 || irq) $fatal(1, "%s acknowledge failed", label);
        checks++;
        cases++;
        $display("DMA_CASE_PASS %s length=%0d bursts=%0d", label, len, burst_expected);
    endtask

    initial begin
        logic [31:0] value;
        int unsigned rng;
        #20000000 $fatal(1, "Global DMA watchdog");
    end
    initial begin
        logic [31:0] value;
        int unsigned rng;
        reset_case();
        read_reg(32'h18, 2'b10, value);
        write_reg(32'h18, 32'h1, 2'b10);
        write_reg(32'h00, 32'h1234, 2'b10, 4'b0001);
        run_case("zero", 3, 5, 0);
        run_case("one", 'h100, 'h2000, 1);
        run_case("eight", 'h180, 'h2080, 8);
        run_case("nine", 'h200, 'h2100, 9);
        run_case("axil_aw_first", 'h200, 'h2100, 16);
        run_case("axil_w_first", 'h200, 'h2100, 16);
        run_case("awready_waits_wvalid", 'h280, 'h2180, 16);
        run_case("w_before_aw", 'h2c0, 'h21c0, 8);
        run_case("burst128", 'h300, 'h2200, 128);
        run_case("burst129", 'h400, 'h2300, 129);
        run_case("source_boundary", 'h0FF8, 'h2400, 24);
        run_case("destination_boundary", 'h500, 'h2FF8, 24);
        run_case("max4096_busy", 'h1000, 'h4000, 4096, 0, 0, 1);
        run_case("bad_source_alignment", 'h101, 'h3000, 8);
        run_case("bad_destination_alignment", 'h100, 'h3001, 8);
        run_case("overlap", 'h100, 'h108, 32);
        run_case("too_long", 'h100, 'h3000, 4097);
        run_case("source_overflow", 'hFFFF_FFF8, 'h3000, 16);
        run_case("destination_overflow", 'h100, 'hFFFF_FFF8, 16);
        run_case("read_error", 'h100, 'h3000, 24, 1, 0);
        run_case("write_error", 'h100, 'h3000, 24, 0, 1);
        reset_case();
        write_reg(32'h00, 'h1000, 0);
        write_reg(32'h04, 'h4000, 0);
        write_reg(32'h08, 4096, 0);
        write_reg(32'h0C, 1, 0);
        begin
            int before_ar, before_aw, guard;
            before_ar = ar_count; before_aw = aw_count; guard = 0;
            while (ar_count == before_ar && guard < 100) begin
                @(negedge aclk);
                guard++;
            end
            if (ar_count == before_ar || aw_count != before_aw)
                $fatal(1, "Reset test did not interrupt first read burst");
        end
        @(negedge aclk); aresetn = 0;
        repeat (3) @(negedge aclk);
        aresetn = 1;
        repeat (3) @(negedge aclk);
        read_reg(32'h10, 0, value);
        if (value != 0 || irq || m_axi_arvalid || m_axi_awvalid || m_axi_wvalid)
            $fatal(1, "Reset did not clear DMA state");
        for (int j = 0; j < MEM_SIZE; j++)
            if (mem[j] !== expected[j]) $fatal(1, "Reset test changed memory at %h", j);
            else checks++;
        cases++;
        $display("DMA_CASE_PASS reset_during_read");
        rng = 32'h28A6_BEEF;
        for (int k = 0; k < 5; k++) begin
            rng = rng * 32'd1664525 + 32'd1013904223;
            run_case($sformatf("seeded_%0d", k), 32'h800 + ((rng[7:0] & 8'hF8)),
                     32'h5000 + ((rng[15:8] & 8'hF8)), 1 + int'(rng[11:0]));
        end
        $display("DMA_REGRESSION_PASS cases=%0d checks=%0d seed=0x28A6BEEF",
                 cases, checks + protocol_checks);
        $finish;
    end
endmodule
