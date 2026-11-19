`timescale 1ns/1ps
// Small building blocks for the v4 core.

// Synchronous FIFO with registered state (data read combinationally). The
// storage has no reset, so deeper FIFOs can map to distributed RAM.
module v4_fifo #(parameter int WIDTH = 32, parameter int DEPTH = 4) (
    input  logic clk,
    input  logic rst_n,
    input  logic push,
    input  logic [WIDTH-1:0] din,
    output logic full,
    input  logic pop,
    output logic [WIDTH-1:0] dout,
    output logic empty
);
    localparam int AW = $clog2(DEPTH);
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [AW-1:0] rd, wr;
    logic [AW:0] count;
    assign full = count == DEPTH;
    assign empty = count == 0;
    assign dout = mem[rd];
    always_ff @(posedge clk) if (push && !full) mem[wr] <= din;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd <= 0; wr <= 0; count <= 0;
        end else begin
            if (push && !full) wr <= AW'(wr + 1'b1);
            if (pop && !empty) rd <= AW'(rd + 1'b1);
            count <= count + (push && !full) - (pop && !empty);
        end
    end
endmodule

// FIFO with a registered head. Prefetch separates the distributed RAM select
// from downstream dispatch/enable logic; capacity remains exactly DEPTH.
module v4_fifo_head #(parameter int WIDTH=32, DEPTH=16) (
    input logic clk, rst_n, push,
    input logic [WIDTH-1:0] din,
    output logic full,
    input logic pop,
    output logic [WIDTH-1:0] dout,
    output logic empty
);
    localparam int CW=$clog2(DEPTH+1);
    logic [CW-1:0] used;
    logic valid, body_empty;
    logic [WIDTH-1:0] next_data;
    wire take=pop && valid;
    wire accept=push && !full;
    wire load=!body_empty && (!valid || take);
    assign full=used==CW'(DEPTH);
    assign empty=!valid;
    v4_fifo #(.WIDTH(WIDTH),.DEPTH(DEPTH)) body(
        .clk,.rst_n,.push(accept),.din,.full(),.pop(load),.dout(next_data),.empty(body_empty));
    always_ff @(posedge clk) begin
        if(!rst_n) begin used<=0;valid<=0;end
        else begin
            used<=used+CW'(accept)-CW'(take);
            if(!valid || take) valid<=!body_empty;
        end
        if(load) dout<=next_data;
    end
endmodule

// Simple dual-port RAM, registered read; LAT = 2 adds the output register
// (DOB_REG of a block RAM) so the read data leaves the RAM from a flip-flop.
module v4_sdp_ram #(parameter int WIDTH = 32, parameter int DEPTH = 64, parameter STYLE = "auto",
                    parameter int LAT = 1) (
    input  logic clk,
    input  logic we,
    input  logic [$clog2(DEPTH)-1:0] waddr,
    input  logic [WIDTH-1:0] wdata,
    input  logic [$clog2(DEPTH)-1:0] raddr,
    output logic [WIDTH-1:0] rdata
);
    (* ram_style = STYLE *) logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [WIDTH-1:0] rd1;
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rd1 <= mem[raddr];
    end
    if (LAT == 1) begin : g_lat1
        assign rdata = rd1;
    end else begin : g_lat2
        always_ff @(posedge clk) rdata <= rd1;
    end
endmodule

// Distributed RAM with an asynchronous read port (the reader registers the data).
module v4_lutram #(parameter int WIDTH = 32, parameter int DEPTH = 8) (
    input  logic clk,
    input  logic we,
    input  logic [$clog2(DEPTH)-1:0] waddr,
    input  logic [WIDTH-1:0] wdata,
    input  logic [$clog2(DEPTH)-1:0] raddr,
    output logic [WIDTH-1:0] rdata
);
    (* ram_style = "distributed" *) logic [WIDTH-1:0] mem [0:DEPTH-1];
    always_ff @(posedge clk) if (we) mem[waddr] <= wdata;
    assign rdata = mem[raddr];
endmodule

// Ring of N buffer slots shared by one producer and one consumer:
// the producer may fill when a slot is free, the consumer may drain when one is full.
module v4_slots #(parameter int N = 2) (
    input  logic clk,
    input  logic rst_n,
    input  logic produce,                 // producer finished filling slot `wr`
    input  logic consume,                 // consumer finished with slot `rd`
    output logic [$clog2(N > 1 ? N : 2)-1:0] wr,
    output logic [$clog2(N > 1 ? N : 2)-1:0] rd,
    output logic can_produce,
    output logic can_consume
);
    logic [$clog2(N+1)-1:0] used;
    assign can_produce = used < N;
    assign can_consume = used > 0;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr <= 0; rd <= 0; used <= 0;
        end else begin
            if (produce) wr <= wr == N - 1 ? '0 : wr + 1'b1;
            if (consume) rd <= rd == N - 1 ? '0 : rd + 1'b1;
            used <= used + produce - consume;
        end
    end
endmodule
