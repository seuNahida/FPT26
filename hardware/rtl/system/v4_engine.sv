`timescale 1ns/1ps
// Core-clock side of the DDR integration. Stream traversal prefetches real
// tensors (no address wrapping); DDR latency is absorbed by asynchronous FIFOs.
module v4_engine (
    input logic clk, rst_n, ddr_clk, ddr_rst_n, start,
    input logic split_disable,
    input logic [5:0] credit_limit,
    input attn_pkg::job_t job,
    input logic [31:0] bases [4],
    output logic busy, done, fault,
    output logic [255:0] perf,
    output logic [31:0] outputs,
    output logic [31:0] diagnostic [6],
    output logic [2:0] req_valid,
    input logic [2:0] req_ready,
    output logic [31:0] req_addr [3],
    input logic [2:0] rsp_valid,
    output logic [2:0] rsp_ready,
    input logic [511:0] rsp_data [3],
    output logic out_valid,
    input logic out_ready,
    output logic [543:0] out_data,
    input logic [31:0] written_gray
);
    import attn_pkg::*;
    logic core_busy, core_done, core_finished;
    logic [1:0] final_activity;
    logic [2:0] rd_en, available;
    logic [19:0] line [3];
    logic [511:0] rdata [3];
    logic [6:0] outstanding [3];
    logic o_we, o_ready, fifo_ready;
    logic [19:0] o_line;
    logic [511:0] o_data;
    logic [6:0] o_depth;
    (* ASYNC_REG="TRUE" *) logic [31:0] written_meta, written_sync;
    logic [31:0] written_bin, written_decoded, written_delta, written_base, expected;
    logic all_written;
    always_comb begin
        written_decoded[31] = written_sync[31];
        for(int i=30;i>=0;i--) written_decoded[i] = written_decoded[i+1]^written_sync[i];
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin written_bin<=0;written_delta<=0;all_written<=0;end
        else begin
            written_bin<=written_decoded;
            written_delta<=written_bin-written_base;
            all_written<=written_delta==expected;
        end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin written_meta <= 0; written_sync <= 0; end
        else begin written_meta <= written_gray; written_sync <= written_meta; end
        if (!rst_n) begin busy<=0; done<=0; fault<=0; outputs<=0; core_finished<=0; written_base<=0; expected<=0; end
        else begin
            done <= 0;
            if (start) begin
                busy<=1; outputs<=0; core_finished<=0; written_base<=written_bin;
                expected <= 32'(job.q_len)*16*(job.groups == 0 ? 1 : 32'(job.groups));
            end
            if (core_done) core_finished <= 1;
            if (o_we) begin
                outputs <= outputs+32;
                if (!fifo_ready) fault <= 1;
            end
            if (busy && core_finished && all_written) begin busy<=0; done<=1; end
        end
    end
    // Independent event counters; these predicates overlap.
    always_ff @(posedge clk) begin
        if (!rst_n || start) for (int i=0;i<6;i++) diagnostic[i] <= 0;
        else if (busy) begin
            if (!o_ready) diagnostic[0] <= diagnostic[0]+1'b1;
            for (int i=0;i<3;i++) if (!available[i]) diagnostic[1+i] <= diagnostic[1+i]+1'b1;
            if (final_activity[0]) diagnostic[4] <= diagnostic[4]+1'b1;
            if (final_activity[1]) diagnostic[5] <= diagnostic[5]+1'b1;
        end
    end
    // Reserve eight slots for the final converter's pipeline after credit drops.
    assign o_ready = o_depth < 56;
    v4_cdc_fifo #(.WIDTH(544),.DEPTH(64),.STYLE("distributed")) output_fifo (
        .s_clk(clk),.s_rst_n(rst_n),.m_clk(ddr_clk),.m_rst_n(ddr_rst_n),
        .s_data({bases[3]+{6'd0,o_line,6'd0},o_data}),.s_valid(o_we),.s_ready(fifo_ready),.s_depth(o_depth),
        .m_data(out_data),.m_valid(out_valid),.m_ready(out_ready));
    for(genvar p=0;p<3;p++) begin: g_read
        logic rv, rr, dv;
        logic [31:0] addr;
        logic [511:0] data;
        logic [511:0] data_q;
        v4_stream_reader #(.KIND(p)) reader(.clk,.rst_n,.start,.credit_limit,.job,.base(bases[p]),
            .req_valid(rv),.req_ready(rr),.req_addr(addr),.consume(rd_en[p]),.outstanding(outstanding[p]),.expected_line());
        v4_cdc_fifo #(.WIDTH(32),.DEPTH(64)) requests (
            .s_clk(clk),.s_rst_n(rst_n),.m_clk(ddr_clk),.m_rst_n(ddr_rst_n),
            .s_data(addr),.s_valid(rv),.s_ready(rr),.s_depth(),
            .m_data(req_addr[p]),.m_valid(req_valid[p]),.m_ready(req_ready[p]));
        v4_cdc_fifo #(.WIDTH(512),.DEPTH(32),.STYLE("distributed")) responses (
            .s_clk(ddr_clk),.s_rst_n(ddr_rst_n),.m_clk(clk),.m_rst_n(rst_n),
            .s_data(rsp_data[p]),.s_valid(rsp_valid[p]),.s_ready(rsp_ready[p]),.s_depth(),
            .m_data(data),.m_valid(available[p]),.m_ready(rd_en[p]));
        // FIFO output is already registered. One fabric stage aligns with
        // the stream core's CD=1, removing two 512-bit stages per read port.
        always_ff @(posedge clk) data_q <= data;
        assign rdata[p] = data_q;
    end
    v4_core #(.STREAM_PORTS(1)) core(.clk,.rst_n,.start,.split_disable,.job,.rd_ok(1'b1),.mem_ready(available),.o_credit(o_ready),
        .busy(core_busy),.done(core_done),.q_rd_en(rd_en[0]),.q_raddr(line[0]),.q_rdata(rdata[0]),
        .k_rd_en(rd_en[1]),.k_raddr(line[1]),.k_rdata(rdata[1]),
        .v_rd_en(rd_en[2]),.v_raddr(line[2]),.v_rdata(rdata[2]),.o_we,.o_waddr(o_line),.o_wdata(o_data),.final_activity,.perf);
endmodule
