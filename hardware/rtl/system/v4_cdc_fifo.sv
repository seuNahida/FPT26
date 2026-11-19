`timescale 1ns/1ps
// Wrapper around the existing, licensed asynchronous AXI FIFO. DEPTH is entries.
module v4_cdc_fifo #(parameter int WIDTH=32, DEPTH=64, parameter STYLE="auto") (
    input logic s_clk, s_rst_n, m_clk, m_rst_n,
    input logic [WIDTH-1:0] s_data,
    input logic s_valid,
    output logic s_ready,
    output logic [$clog2(DEPTH):0] s_depth,
    output logic [WIDTH-1:0] m_data,
    output logic m_valid,
    input logic m_ready
);
    fpt_mem_axis_async_fifo #(.DEPTH(DEPTH), .RAM_STYLE(STYLE), .DATA_WIDTH(WIDTH), .KEEP_ENABLE(0), .KEEP_WIDTH(1),
        .LAST_ENABLE(0), .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)) fifo (
        .s_clk, .s_rst(!s_rst_n), .s_axis_tdata(s_data), .s_axis_tkeep(1'b1),
        .s_axis_tvalid(s_valid), .s_axis_tready(s_ready), .s_axis_tlast(1'b0),
        .s_axis_tid(8'd0), .s_axis_tdest(8'd0), .s_axis_tuser(1'b0),
        .m_clk, .m_rst(!m_rst_n), .m_axis_tdata(m_data), .m_axis_tvalid(m_valid),
        .m_axis_tready(m_ready), .m_axis_tkeep(), .m_axis_tlast(), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
        .s_pause_req(1'b0), .m_pause_req(1'b0), .s_pause_ack(), .m_pause_ack(),
        .s_status_depth(s_depth), .s_status_depth_commit(), .s_status_overflow(), .s_status_bad_frame(), .s_status_good_frame(),
        .m_status_depth(), .m_status_depth_commit(), .m_status_overflow(), .m_status_bad_frame(), .m_status_good_frame());
endmodule
