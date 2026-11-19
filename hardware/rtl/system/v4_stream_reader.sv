`timescale 1ns/1ps
// Independent traversal of the core's read order. Credits include requests,
// MIG reads in flight, response FIFO entries, and lines not yet consumed.
module v4_stream_reader #(parameter int KIND = 0, CREDIT = 32) (
    input logic clk, rst_n, start,
    input logic [5:0] credit_limit,
    input attn_pkg::job_t job,
    input logic [31:0] base,
    output logic req_valid,
    input logic req_ready,
    output logic [31:0] req_addr,
    input logic consume,
    output logic [6:0] outstanding,
    output logic [19:0] expected_line
);
    import attn_pkg::*;
    blk_t blk;
    logic valid, next, run;
    logic [19:0] line;
    logic [8:0] left;
    v4_sched sched(.clk, .rst_n, .start, .job, .next, .valid, .blk);
    wire wanted = KIND == 0 ? blk.first : blk.kvfirst;
    wire take = req_valid && req_ready;
    assign req_valid = run && outstanding < (credit_limit == 0 ? 7'(CREDIT) : {1'b0,credit_limit});
    assign req_addr = base + {6'd0,line,6'd0};
    assign next = valid && !run && !start;
    // Debug address of the next request (stream order is checked by the testbench).
    assign expected_line = line;
    always_ff @(posedge clk) begin
        if (!rst_n || start) begin run <= 0; outstanding <= 0; line <= 0; left <= 0; end
        else begin
            outstanding <= outstanding + take - consume;
            if (next && wanted) begin
                run <= 1;
                if (KIND == 0) begin
                    line <= 20'(blk.qrow0)*4 + 20'(blk.tile)*64;
                    left <= 9'(blk.npos)*16;
                end else begin
                    line <= 20'(blk.kabs0)*4;
                    left <= KIND == 1 ? 9'(blk.nkf)*4 : 9'(blk.nv)*4;
                end
            end
            if (take) begin
                line <= line + 1'b1; left <= left - 1'b1;
                if (left == 1) run <= 0;
            end
        end
    end
endmodule
