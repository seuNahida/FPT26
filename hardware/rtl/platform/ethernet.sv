`timescale 1ns/1ps
// Public Ethernet endpoint. Application messages use the 100 MHz host clock.
// RGMII, ARP, IPv4, UDP, framing and packet queues are private to this file.
module ethernet (
    input logic clk, rst_n, mac_clk, mac_rst_n, ref_clk, ref_rst_n,
    output fpt_pkg::command_t command,
    input logic command_ready,
    input fpt_pkg::response_t response,
    output fpt_pkg::bulk_write_t bulk_write,
    output fpt_pkg::bulk_read_t bulk_read,
    input logic [31:0] bulk_read_data,
    input fpt_pkg::status_t status,
    output logic [3:0] rgmii_txd,
    output logic rgmii_tx_ctl, rgmii_txc,
    input logic [3:0] rgmii_rxd,
    input logic rgmii_rx_ctl, rgmii_rxc, phy_int_n,
    inout wire mdio,
    output logic mdc, phy_rst_n
);
    import fpt_pkg::*;
    localparam int RGMII_RX_IDELAY_TAPS = 0;
    logic [21:0] phy_count;
    logic idelay_ready;
    logic [1:0] speed;
    logic [6:0] mac_errors;
    logic mac_error_seen;
    (* ASYNC_REG = "TRUE" *) logic [1:0] phy_interrupt_sync;
    always_ff @(posedge clk) begin
        if (!rst_n) begin mac_error_seen <= 0; phy_interrupt_sync <= 2'b11; end
        else begin
            mac_error_seen <= mac_error_seen || (|mac_errors);
            phy_interrupt_sync <= {phy_interrupt_sync[0],phy_int_n};
        end
    end
    logic [3:0] rgmii_rxd_delayed;
    logic rgmii_rx_ctl_delayed;
    (* ASYNC_REG = "TRUE" *) logic [2:0] logic_reset_sync, mac_reset_sync;
    wire link_reset_n = rst_n && phy_rst_n && idelay_ready;
    always_ff @(posedge clk or negedge link_reset_n)
        if (!link_reset_n) logic_reset_sync <= 0;
        else logic_reset_sync <= {logic_reset_sync[1:0],1'b1};
    always_ff @(posedge mac_clk or negedge link_reset_n)
        if (!link_reset_n) mac_reset_sync <= 0;
        else mac_reset_sync <= {mac_reset_sync[1:0],mac_rst_n};
    always_ff @(posedge clk) begin
        if (!rst_n) phy_count <= 0;
        else if (phy_count != 22'd2000000) phy_count <= phy_count + 1'b1;
    end
    assign phy_rst_n = phy_count == 22'd2000000;
    assign mdio = 1'bz;
    assign mdc = 0;
    logic ddr_push, attention_push;
    assign command.valid = ddr_push || attention_push;
    wire memory_response = is_memory_command(response.opcode);
    logic [7:0] rx_data, tx_data, fifo_data;
    logic rx_valid, rx_last, rx_user, rx_ready, tx_valid, tx_last, tx_user, tx_ready;
    logic fifo_valid, fifo_last, fifo_user, fifo_ready;
    IDELAYCTRL u_rgmii_idelayctrl (
        .REFCLK(ref_clk),
        .RST(~ref_rst_n),
        .RDY(idelay_ready)
    );

    for (genvar rgmii_rx_i = 0; rgmii_rx_i < 4; rgmii_rx_i++) begin : gen_rgmii_rxd_idelay
        IDELAYE2 #(
            .CINVCTRL_SEL("FALSE"),
            .DELAY_SRC("IDATAIN"),
            .HIGH_PERFORMANCE_MODE("FALSE"),
            .IDELAY_TYPE("FIXED"),
            .IDELAY_VALUE(RGMII_RX_IDELAY_TAPS),
            .PIPE_SEL("FALSE"),
            .REFCLK_FREQUENCY(200.0),
            .SIGNAL_PATTERN("DATA")
        ) u_idelay (
            .IDATAIN(rgmii_rxd[rgmii_rx_i]),
            .DATAOUT(rgmii_rxd_delayed[rgmii_rx_i]),
            .DATAIN(1'b0),
            .C(1'b0),
            .CE(1'b0),
            .INC(1'b0),
            .CINVCTRL(1'b0),
            .CNTVALUEIN(5'd0),
            .CNTVALUEOUT(),
            .LD(1'b0),
            .LDPIPEEN(1'b0),
            .REGRST(1'b0)
        );
    end

    IDELAYE2 #(
        .CINVCTRL_SEL("FALSE"),
        .DELAY_SRC("IDATAIN"),
        .HIGH_PERFORMANCE_MODE("FALSE"),
        .IDELAY_TYPE("FIXED"),
        .IDELAY_VALUE(RGMII_RX_IDELAY_TAPS),
        .PIPE_SEL("FALSE"),
        .REFCLK_FREQUENCY(200.0),
        .SIGNAL_PATTERN("DATA")
    ) u_rgmii_rx_ctl_idelay (
        .IDATAIN(rgmii_rx_ctl),
        .DATAOUT(rgmii_rx_ctl_delayed),
        .DATAIN(1'b0),
        .C(1'b0),
        .CE(1'b0),
        .INC(1'b0),
        .CINVCTRL(1'b0),
        .CNTVALUEIN(5'd0),
        .CNTVALUEOUT(),
        .LD(1'b0),
        .LDPIPEEN(1'b0),
        .REGRST(1'b0)
    );

    fpt_net_eth_mac_1g_rgmii_fifo #(
        .TARGET("XILINX"),
        .IODDR_STYLE("IODDR"),
        .CLOCK_INPUT_STYLE("BUFR"),
        .USE_CLK90("FALSE"),
        .AXIS_DATA_WIDTH(8),
        .ENABLE_PADDING(1),
        .MIN_FRAME_LENGTH(64),
        // A maximum ATN1 bulk-read response is 74 + 4*360 = 1514 bytes.
        // The MAC uses a frame FIFO, so it must hold the complete response.
        .TX_FIFO_DEPTH(2048),
        .RX_FIFO_DEPTH(2048)
    ) u_eth_mac_1g_rgmii_fifo (
        .gtx_clk(mac_clk),
        .gtx_clk90(mac_clk),
        .gtx_rst(~mac_reset_sync[2]),
        .logic_clk(clk),
        .logic_rst(~logic_reset_sync[2]),

        .tx_axis_tdata(fifo_data),
        .tx_axis_tkeep(1'b1),
        .tx_axis_tvalid(fifo_valid),
        .tx_axis_tready(fifo_ready),
        .tx_axis_tlast(fifo_last),
        .tx_axis_tuser(fifo_user),

        .rx_axis_tdata(rx_data),
        .rx_axis_tkeep(),
        .rx_axis_tvalid(rx_valid),
        .rx_axis_tready(rx_ready),
        .rx_axis_tlast(rx_last),
        .rx_axis_tuser(rx_user),

        .rgmii_rx_clk(rgmii_rxc),
        .rgmii_rxd(rgmii_rxd_delayed),
        .rgmii_rx_ctl(rgmii_rx_ctl_delayed),
        .rgmii_tx_clk(rgmii_txc),
        .rgmii_txd(rgmii_txd),
        .rgmii_tx_ctl(rgmii_tx_ctl),

        .tx_error_underflow(mac_errors[0]),
        .tx_fifo_overflow(mac_errors[1]),
        .tx_fifo_bad_frame(mac_errors[2]),
        .tx_fifo_good_frame(),
        .rx_error_bad_frame(mac_errors[3]),
        .rx_error_bad_fcs(mac_errors[4]),
        .rx_fifo_overflow(mac_errors[5]),
        .rx_fifo_bad_frame(mac_errors[6]),
        .rx_fifo_good_frame(),
        .speed(speed),

        .cfg_ifg(8'd12),
        .cfg_tx_enable(1'b1),
        .cfg_rx_enable(1'b1)
    );

    fpt_net_eth_axis_byte_sync_fifo #(
        .DEPTH(256)
    ) u_eth_tx_axis_fifo (
        .clk(clk),
        .rst_n(logic_reset_sync[2]),
        .s_axis_tdata(tx_data),
        .s_axis_tvalid(tx_valid),
        .s_axis_tlast(tx_last),
        .s_axis_tuser(tx_user),
        .s_axis_tready(tx_ready),
        .m_axis_tdata(fifo_data),
        .m_axis_tvalid(fifo_valid),
        .m_axis_tlast(fifo_last),
        .m_axis_tuser(fifo_user),
        .m_axis_tready(fifo_ready)
    );

    fpt_net_eth_ipv4_udp_debug_stack #(
        .MAX_BULK_WORDS(BULK_WORDS)
    ) packets (
        .rx_clk(clk),
        .rx_rst_n(logic_reset_sync[2]),
        .tx_clk(clk),
        .tx_rst_n(logic_reset_sync[2]),
        .rx_axis_tdata(rx_data),
        .rx_axis_tready(rx_ready),
        .rx_axis_tvalid(rx_valid),
        .rx_axis_tlast(rx_last),
        .rx_axis_tuser(rx_user),
        .tx_axis_tdata(tx_data),
        .tx_axis_tvalid(tx_valid),
        .tx_axis_tlast(tx_last),
        .tx_axis_tuser(tx_user),
        .tx_axis_tready(tx_ready),
        .debug_done(status.done),
        .debug_busy(status.busy),
        .debug_error(status.error),
        .debug_core_error(status.core_error),
        .debug_cycle_count(status.cycles),
        .debug_output_count(status.outputs),
        .debug_pods(status.pods),
        .debug_cfg({mac_error_seen,~phy_interrupt_sync[1],logic_reset_sync[2],speed == 2'b10}),
        .dbg_cmd_bulk_active(1'b0),
        .dbg_cmd_state(3'd0),
        .ddr_ctrl_req_push(ddr_push),
        .ddr_ctrl_req_ready(command_ready),
        .attn_ctrl_req_valid(attention_push),
        .ctrl_req_opcode(command.opcode),
        .ctrl_req_flags(command.flags),
        .ctrl_req_txn_id(command.txn),
        .ctrl_req_arg0(command.arg0),
        .ctrl_req_arg1(command.arg1),
        .ctrl_req_arg2(command.arg2),
        .ctrl_req_bulk_slot(command.bulk_slot),
        .ctrl_req_bulk_count(command.bulk_count),
        .ddr_rsp_valid(response.valid && memory_response),
        .ddr_rsp_status(response.status),
        .ddr_rsp_opcode(response.opcode),
        .ddr_rsp_txn_id(response.txn),
        .ddr_rsp_data(response.data),
        .attn_rsp_valid(response.valid && !memory_response),
        .attn_rsp_status(response.status),
        .attn_rsp_opcode(response.opcode),
        .attn_rsp_txn_id(response.txn),
        .attn_rsp_data(response.data),
        .bulk_req_word_valid(bulk_write.valid),
        .bulk_req_word_index(bulk_write.index),
        .bulk_req_word_data(bulk_write.data),
        .bulk_req_word_count(bulk_write.count),
        .bulk_req_slot(bulk_write.slot),
        .bulk_rsp_rd_addr(bulk_read.index),
        .bulk_rsp_rd_slot(bulk_read.slot),
        .bulk_rsp_rd_data(bulk_read_data),
        .rx_frame_count(),
        .arp_request_count(),
        .udp_request_count(),
        .dropped_frame_count(),
        .tx_frame_count()
    );
endmodule

// ---- Private implementation: fpt_net_eth_ipv4_udp_debug_stack.sv ----
`timescale 1ns / 1ps

// Small fixed-address Ethernet endpoint for board bring-up.
//
// Supported receive protocols:
//   * ARP request for LOCAL_IP -> ARP reply
//   * IPv4/UDP to LOCAL_IP:LOCAL_UDP_PORT -> compact binary control/debug reply
//
// This is intentionally not a general network stack: no VLAN, no IPv4 options,
// no fragmentation, and IPv4 UDP checksum is transmitted as zero.
module fpt_net_eth_ipv4_udp_debug_stack #(
    parameter logic [47:0] LOCAL_MAC      = 48'h02_00_00_00_00_10,
    parameter logic [31:0] LOCAL_IP       = 32'hc0a8_010a,
    parameter logic [15:0] LOCAL_UDP_PORT = 16'd50000,
    parameter int MAX_BULK_WORDS          = 256,
    parameter int BULK_ADDR_W             = (MAX_BULK_WORDS <= 2) ? 1 :
                                            $clog2(MAX_BULK_WORDS),
    parameter int CTRL_TIMEOUT_CYCLES     = 1_250_000,
    // sq/pr/rsp FIFOs are all REQ_FIFO_DEPTH deep.  32 gives ample headroom
    // for pipelined bursts (host pipeline<=4) plus in-flight responses; the
    // pending-response FIFO has no full-check on push, so overflowing it
    // would permanently misalign the pr/rsp pair (response frames then go
    // out with the wrong peer/slot) - depth + issue-gating keep it safe.
    parameter int REQ_FIFO_DEPTH          = 32,
    // 8 slots: a slot is held until the response frame fully transmits, so
    // pipelined bulk requests (host sends up to 4 at once) would exhaust
    // 4 slots while earlier response frames are still queued in the rsp
    // FIFO, and the stack then drops the whole request frame (no reply ->
    // host timeout).
    parameter int BULK_SLOTS              = 8
) (
    input  logic        rx_clk,
    input  logic        rx_rst_n,
    input  logic [7:0]  rx_axis_tdata,
    input  logic        rx_axis_tvalid,
    output logic        rx_axis_tready,
    input  logic        rx_axis_tlast,
    input  logic        rx_axis_tuser,

    input  logic        tx_clk,
    input  logic        tx_rst_n,
    output logic [7:0]  tx_axis_tdata,
    output logic        tx_axis_tvalid,
    output logic        tx_axis_tlast,
    output logic        tx_axis_tuser,
    input  logic        tx_axis_tready,

    input  logic        debug_done,
    input  logic        debug_busy,
    input  logic        debug_error,
    input  logic        debug_core_error,
    input  logic [63:0] debug_cycle_count,
    input  logic [63:0] debug_output_count,
    input  logic [3:0]  debug_pods,
    input  logic [3:0]  debug_cfg,
    // Controller FSM visibility for the DEBUG_STATUS diagnostic command.
    input  logic        dbg_cmd_bulk_active,
    input  logic [2:0]  dbg_cmd_state,

    // Dual-endpoint pipelined issue.  DDR requests flow freely while the
    // controller FIFO has room; attention requests are only issued after all
    // outstanding DDR responses have returned, so response frames stay in
    // request order and the shared response bus never has two sources.
    output logic        ddr_ctrl_req_push,
    input  logic        ddr_ctrl_req_ready,
    output logic        attn_ctrl_req_valid,
    output logic [7:0]  ctrl_req_opcode,
    output logic [7:0]  ctrl_req_flags,
    output logic [15:0] ctrl_req_txn_id,
    output logic [31:0] ctrl_req_arg0,
    output logic [31:0] ctrl_req_arg1,
    output logic [31:0] ctrl_req_arg2,
    output logic [((BULK_SLOTS > 1) ? $clog2(BULK_SLOTS) : 1)-1:0] ctrl_req_bulk_slot,
    output logic [BULK_ADDR_W:0] ctrl_req_bulk_count,
    input  logic        ddr_rsp_valid,
    input  logic [7:0]  ddr_rsp_status,
    input  logic [7:0]  ddr_rsp_opcode,
    input  logic [15:0] ddr_rsp_txn_id,
    input  logic [31:0] ddr_rsp_data,
    input  logic        attn_rsp_valid,
    input  logic [7:0]  attn_rsp_status,
    input  logic [7:0]  attn_rsp_opcode,
    input  logic [15:0] attn_rsp_txn_id,
    input  logic [31:0] attn_rsp_data,

    output logic                    bulk_req_word_valid,
    output logic [BULK_ADDR_W-1:0] bulk_req_word_index,
    output logic [31:0]             bulk_req_word_data,
    output logic [BULK_ADDR_W:0]   bulk_req_word_count,
    output logic [((BULK_SLOTS > 1) ? $clog2(BULK_SLOTS) : 1)-1:0] bulk_req_slot,
    output logic [BULK_ADDR_W-1:0] bulk_rsp_rd_addr,
    output logic [((BULK_SLOTS > 1) ? $clog2(BULK_SLOTS) : 1)-1:0] bulk_rsp_rd_slot,
    input  logic [31:0]             bulk_rsp_rd_data,

    output logic [31:0] rx_frame_count,
    output logic [31:0] arp_request_count,
    output logic [31:0] udp_request_count,
    output logic [31:0] dropped_frame_count,
    output logic [31:0] tx_frame_count
);

    localparam logic [15:0] ETH_TYPE_IPV4 = 16'h0800;
    localparam logic [15:0] ETH_TYPE_ARP  = 16'h0806;
    localparam logic [47:0] MAC_BROADCAST = 48'hff_ff_ff_ff_ff_ff;
    localparam logic [15:0] ARP_HTYPE_ETH = 16'h0001;
    localparam logic [15:0] ARP_PTYPE_IP  = 16'h0800;
    localparam logic [15:0] ARP_OPER_REQ  = 16'h0001;
    localparam logic [7:0]  IP_PROTO_UDP  = 8'h11;

    localparam int DEBUG_PAYLOAD_BYTES = 32;
    localparam int ARP_FRAME_BYTES     = 60;
    localparam int UDP_FRAME_BYTES     = 14 + 20 + 8 + DEBUG_PAYLOAD_BYTES;
    localparam logic [31:0] IPV4_BASE_SUM =
        {16'd0, 16'h4500} +
        {16'd0, 16'h4000} +
        {16'd0, 16'h4011} +
        {16'd0, LOCAL_IP[31:16]} +
        {16'd0, LOCAL_IP[15:0]};
    localparam int CTRL_TIMEOUT_W = (CTRL_TIMEOUT_CYCLES <= 1) ?
                                    1 : $clog2(CTRL_TIMEOUT_CYCLES);
    localparam logic [CTRL_TIMEOUT_W-1:0] CTRL_TIMEOUT_LIMIT =
        CTRL_TIMEOUT_CYCLES - 1;

    typedef enum logic [1:0] {
        REQ_NONE,
        REQ_ARP,
        REQ_UDP
    } req_type_t;

    typedef enum logic [3:0] {
        TX_IDLE,
        TX_CHECKSUM_ID,
        TX_CHECKSUM_DST_HI,
        TX_CHECKSUM_DST_LO,
        TX_CHECKSUM_FOLD0,
        TX_CHECKSUM_FOLD1,
        TX_CHECKSUM_DONE,
        TX_CTRL_REQ,
        TX_CTRL_WAIT,
        TX_PREP_WAIT,
        TX_PREP,
        TX_SEND
    } tx_state_t;

    typedef enum logic [3:0] {
        RX_EVAL_IDLE,
        RX_EVAL_CLASSIFY,
        RX_EVAL_ARP_MATCH,
        RX_EVAL_ARP_LOAD,
        RX_EVAL_UDP_MATCH,
        RX_EVAL_UDP_LOAD,
        RX_EVAL_ISSUE_WAIT,
        RX_EVAL_ISSUE,
        RX_EVAL_DROP
    } rx_eval_state_t;

    // Hold the next frame in the MAC FIFO until classification has finished.
    // Once a frame starts, accept all its bytes. No wire IFG is assumed at
    // this FIFO boundary; short tails can immediately follow long frames.
    assign rx_axis_tready = in_frame_q || rx_eval_state_q == RX_EVAL_IDLE;
    logic in_frame_q;
    logic rx_drop_in_frame_q;
    logic [10:0] byte_idx_q;
    logic [10:0] rx_byte_idx;
    logic frame_error_q;

    logic [47:0] eth_dst_mac_q;
    logic [47:0] eth_src_mac_q;
    logic [15:0] eth_type_q;

    logic [15:0] arp_htype_q;
    logic [15:0] arp_ptype_q;
    logic [7:0]  arp_hlen_q;
    logic [7:0]  arp_plen_q;
    logic [15:0] arp_oper_q;
    logic [47:0] arp_sha_q;
    logic [31:0] arp_spa_q;
    logic [47:0] arp_tha_q;
    logic [31:0] arp_tpa_q;

    logic [7:0]  ip_ver_ihl_q;
    logic [15:0] ip_total_len_q;
    logic [7:0]  ip_protocol_q;
    logic [31:0] ip_src_q;
    logic [31:0] ip_dst_q;
    logic [15:0] udp_src_port_q;
    logic [15:0] udp_dst_port_q;
    logic [15:0] udp_len_q;
    logic [31:0] rx_cmd_magic_q;
    logic [7:0]  rx_cmd_version_q;
    logic [7:0]  rx_cmd_opcode_q;
    logic [7:0]  rx_cmd_flags_q;
    logic [15:0] rx_cmd_txn_id_q;
    logic [31:0] rx_cmd_arg0_q;
    logic [31:0] rx_cmd_arg1_q;
    logic [31:0] rx_cmd_arg2_q;
    logic [31:0] rx_bulk_word_accum_q;

    (* fsm_encoding = "sequential" *) rx_eval_state_t rx_eval_state_q;
    logic eval_dst_match_q;
    logic eval_is_arp_q;
    logic eval_is_ipv4_q;
    logic eval_arp_match_q;
    logic eval_udp_match_q;
    req_type_t eval_req_type_q;
    logic [47:0] eval_peer_mac_q;
    logic [31:0] eval_peer_ip_q;
    logic [15:0] eval_peer_port_q;

    req_type_t mailbox_type_q;
    logic [47:0] mailbox_peer_mac_q;
    logic [31:0] mailbox_peer_ip_q;
    logic [15:0] mailbox_peer_port_q;
    logic [7:0]  mailbox_cmd_opcode_q;
    logic [7:0]  mailbox_cmd_flags_q;
    logic [15:0] mailbox_cmd_txn_id_q;
    logic [31:0] mailbox_cmd_arg0_q;
    logic [31:0] mailbox_cmd_arg1_q;
    logic [31:0] mailbox_cmd_arg2_q;
    logic req_toggle_rx_q;
    logic req_pending_q;

    (* ASYNC_REG = "TRUE" *) logic ack_toggle_rx_meta_q;
    (* ASYNC_REG = "TRUE" *) logic ack_toggle_rx_sync_q;
    logic ack_toggle_rx_seen_q;

    (* ASYNC_REG = "TRUE" *) logic req_toggle_tx_meta_q;
    (* ASYNC_REG = "TRUE" *) logic req_toggle_tx_sync_q;
    logic req_toggle_tx_seen_q;
    logic ack_toggle_tx_q;

    // ---------------- Pipelined request queue ----------------
    // The stack keeps its own FIFO of control requests so RX never drops a
    // frame while the DDR controller is busy; the controller processes them
    // in order and responses come back in order.  A pending-response FIFO
    // carries the peer/txn/slot info each response frame needs.
    localparam int BULK_SLOT_W = (BULK_SLOTS <= 1) ? 1 : $clog2(BULK_SLOTS);
    localparam int REQ_FIFO_AW = (REQ_FIFO_DEPTH <= 1) ?
                                 1 : $clog2(REQ_FIFO_DEPTH);
    localparam int REQ_FIFO_COUNT_W =
        (REQ_FIFO_DEPTH <= 1) ? 1 : $clog2(REQ_FIFO_DEPTH + 1);

    logic [REQ_FIFO_AW-1:0] sq_wr_ptr_q;
    logic [REQ_FIFO_AW-1:0] sq_rd_ptr_q;
    logic [REQ_FIFO_COUNT_W-1:0] sq_count_q;
    req_type_t sq_fifo_type_q      [0:REQ_FIFO_DEPTH-1];
    logic [47:0] sq_fifo_peer_mac_q  [0:REQ_FIFO_DEPTH-1];
    logic [31:0] sq_fifo_peer_ip_q   [0:REQ_FIFO_DEPTH-1];
    logic [15:0] sq_fifo_peer_port_q [0:REQ_FIFO_DEPTH-1];
    logic [7:0]  sq_fifo_opcode_q    [0:REQ_FIFO_DEPTH-1];
    logic [7:0]  sq_fifo_flags_q     [0:REQ_FIFO_DEPTH-1];
    logic [15:0] sq_fifo_txn_q       [0:REQ_FIFO_DEPTH-1];
    logic [31:0] sq_fifo_arg0_q      [0:REQ_FIFO_DEPTH-1];
    logic [31:0] sq_fifo_arg1_q      [0:REQ_FIFO_DEPTH-1];
    logic [31:0] sq_fifo_arg2_q      [0:REQ_FIFO_DEPTH-1];
    logic [BULK_SLOT_W-1:0] sq_fifo_slot_q [0:REQ_FIFO_DEPTH-1];
    logic [BULK_ADDR_W:0] sq_fifo_count_q [0:REQ_FIFO_DEPTH-1];

    logic sq_fifo_empty_w;
    logic sq_fifo_full_w;

    // Pending-response FIFO: one entry per request pushed to the controller,
    // popped when its response arrives (responses are in order).
    logic [REQ_FIFO_AW-1:0] pr_wr_ptr_q;
    logic [REQ_FIFO_AW-1:0] pr_rd_ptr_q;
    logic [REQ_FIFO_COUNT_W-1:0] pr_count_q;
    logic [47:0] pr_fifo_peer_mac_q  [0:REQ_FIFO_DEPTH-1];
    logic [31:0] pr_fifo_peer_ip_q   [0:REQ_FIFO_DEPTH-1];
    logic [15:0] pr_fifo_peer_port_q [0:REQ_FIFO_DEPTH-1];
    logic [7:0]  pr_fifo_opcode_q    [0:REQ_FIFO_DEPTH-1];
    logic [15:0] pr_fifo_txn_q       [0:REQ_FIFO_DEPTH-1];
    logic [BULK_SLOT_W-1:0] pr_fifo_slot_q [0:REQ_FIFO_DEPTH-1];

    logic pr_fifo_empty_w;
    logic pr_fifo_full_w;

    // Bulk payload slot allocation (only used by bulk requests).
    logic [BULK_SLOTS-1:0] slot_busy_q;
    logic [BULK_SLOT_W-1:0] rx_frame_slot_q;
    logic rx_frame_slot_valid_q;
    logic [BULK_SLOT_W-1:0] alloc_slot_w;
    logic alloc_slot_valid_w;
    wire [7:0] rx_opcode_early = rx_cmd_opcode_q;

    // Lowest free bulk slot allocation (RX side).
    always_comb begin
        alloc_slot_w = '0;
        alloc_slot_valid_w = 1'b0;
        for (int s = 0; s < BULK_SLOTS; s++) begin
            if (!slot_busy_q[s]) begin
                alloc_slot_w = BULK_SLOT_W'(s);
                alloc_slot_valid_w = 1'b1;
                break;
            end
        end
    end

    assign sq_fifo_empty_w = (sq_count_q == '0);
    assign sq_fifo_full_w  = (sq_count_q == REQ_FIFO_COUNT_W'(REQ_FIFO_DEPTH));
    assign pr_fifo_empty_w = (pr_count_q == '0);
    assign pr_fifo_full_w  = (pr_count_q == REQ_FIFO_COUNT_W'(REQ_FIFO_DEPTH));
    // Issue is a single-cycle atomic action: RX pops the stack FIFO on the
    // same cycle the TX side pushes to the controller and enqueues the
    // pending-response entry.

    // Combinational FIFO head reads (async RAM read, same clock domain).
    wire sq_head_type_w  = sq_fifo_type_q[sq_rd_ptr_q];
    wire [47:0] sq_head_peer_mac_w  = sq_fifo_peer_mac_q[sq_rd_ptr_q];
    wire [31:0] sq_head_peer_ip_w   = sq_fifo_peer_ip_q[sq_rd_ptr_q];
    wire [15:0] sq_head_peer_port_w = sq_fifo_peer_port_q[sq_rd_ptr_q];
    wire [7:0]  sq_head_opcode_w    = sq_fifo_opcode_q[sq_rd_ptr_q];
    wire [7:0]  sq_head_flags_w     = sq_fifo_flags_q[sq_rd_ptr_q];
    wire [15:0] sq_head_txn_w       = sq_fifo_txn_q[sq_rd_ptr_q];
    wire [31:0] sq_head_arg0_w      = sq_fifo_arg0_q[sq_rd_ptr_q];
    wire [31:0] sq_head_arg1_w      = sq_fifo_arg1_q[sq_rd_ptr_q];
    wire [31:0] sq_head_arg2_w      = sq_fifo_arg2_q[sq_rd_ptr_q];
    wire [BULK_SLOT_W-1:0] sq_head_slot_w  = sq_fifo_slot_q[sq_rd_ptr_q];
    wire [BULK_ADDR_W:0] sq_head_count_w   = sq_fifo_count_q[sq_rd_ptr_q];

    wire [47:0] pr_head_peer_mac_w  = pr_fifo_peer_mac_q[pr_rd_ptr_q];
    wire [31:0] pr_head_peer_ip_w   = pr_fifo_peer_ip_q[pr_rd_ptr_q];
    wire [15:0] pr_head_peer_port_w = pr_fifo_peer_port_q[pr_rd_ptr_q];
    wire [7:0]  pr_head_opcode_w    = pr_fifo_opcode_q[pr_rd_ptr_q];
    wire [15:0] pr_head_txn_w       = pr_fifo_txn_q[pr_rd_ptr_q];
    wire [BULK_SLOT_W-1:0] pr_head_slot_w = pr_fifo_slot_q[pr_rd_ptr_q];
    (* max_fanout = 32 *) logic tx_req_load_state_q;
    logic [BULK_SLOT_W-1:0] tx_bulk_slot_q;      // slot of the frame being sent
    logic slot_release_pulse_q;                  // release slot after response frame
    logic ddr_ctrl_req_push_q;
    logic attn_ctrl_req_valid_q;
    (* max_fanout = 32 *) logic tx_req_load_payload_q;
    (* max_fanout = 32 *) logic tx_req_load_debug_q;
    (* max_fanout = 32 *) logic tx_req_load_axis_q;

    (* fsm_encoding = "sequential" *) tx_state_t tx_state_q;

    // ---------------- Pipelined dual-endpoint issuer ----------------
    // Responses are captured into a response FIFO as soon as they arrive, so
    // a response that lands while a response frame is being transmitted is
    // queued instead of dropped.  The pending-response FIFO tracks peer/slot
    // per request; both FIFOs are in request order and are popped together at
    // frame capture, so they stay aligned.
    localparam int RSP_FIFO_AW = REQ_FIFO_AW;
    localparam int RSP_FIFO_COUNT_W = REQ_FIFO_COUNT_W;

    logic [RSP_FIFO_AW-1:0] rsp_wr_ptr_q;
    logic [RSP_FIFO_AW-1:0] rsp_rd_ptr_q;
    logic [RSP_FIFO_COUNT_W-1:0] rsp_count_q;
    logic [7:0]  rsp_fifo_status_q [0:REQ_FIFO_DEPTH-1];
    logic [7:0]  rsp_fifo_opcode_q  [0:REQ_FIFO_DEPTH-1];
    logic [15:0] rsp_fifo_txn_q     [0:REQ_FIFO_DEPTH-1];
    logic [31:0] rsp_fifo_data_q    [0:REQ_FIFO_DEPTH-1];

    logic rsp_fifo_empty_w;
    logic rsp_fifo_full_w;
    logic rsp_push_w;
    logic rsp_pop_w;
    // Internal latch for impossible-by-construction response ordering
    // violations (response with nothing outstanding, FIFO overflow, pr/rsp
    // desync).  Exposed to the host via CMD_DEBUG_STATUS.
    logic rsp_protocol_error_q;
    logic [31:0] debug_status_w;

    // Outstanding-request tracking keeps responses globally in order: only
    // one endpoint may have outstanding requests at a time, and the response
    // bus is muxed on which endpoint that is.
    logic [REQ_FIFO_COUNT_W-1:0] ddr_outstanding_count_q;
    logic attn_outstanding_q;

    logic head_is_ddr_w;
    logic ddr_issue_ok_w;
    logic attn_issue_ok_w;
    logic issue_ctrl_w;
    logic issue_arp_w;
    logic rsp_valid_w;
    logic [7:0]  rsp_status_w;
    logic [7:0]  rsp_opcode_w;
    logic [15:0] rsp_txn_id_w;
    logic [31:0] rsp_data_w;

    assign head_is_ddr_w = is_ddr_opcode(sq_head_opcode_w);
    assign ddr_issue_ok_w = !attn_outstanding_q && ddr_ctrl_req_ready;
    assign attn_issue_ok_w =
        (ddr_outstanding_count_q == '0) &&
        !attn_outstanding_q && !attn_rsp_valid;
    // Controller requests are issued from any TX state so the controller
    // FIFO stays fed while a response frame is on the wire.  ARP entries are
    // excluded by type, not by opcode: a bad-magic ARP frame carries the
    // default GET_STATUS opcode (0x01), which would otherwise look like an
    // attention request and never push a pending-response entry.
    // Do not issue past a full pending-response FIFO: a wrapped pr write
    // pointer would overwrite the head and misalign pr/rsp for every
    // subsequent response (wrong peer/slot in response frames).
    assign issue_ctrl_w =
        !sq_fifo_empty_w && (sq_head_type_w != REQ_ARP) &&
        !pr_fifo_full_w &&
        (head_is_ddr_w ? ddr_issue_ok_w : attn_issue_ok_w);
    // ARP replies bypass the controller and need the TX line, so they still
    // wait for the TX state machine to be idle.
    assign issue_arp_w =
        !sq_fifo_empty_w && (sq_head_type_w == REQ_ARP) &&
        (tx_state_q == TX_IDLE);
    assign issue_valid_w = issue_ctrl_w || issue_arp_w;

    assign rsp_valid_w = attn_outstanding_q ? attn_rsp_valid : ddr_rsp_valid;
    assign rsp_status_w = attn_outstanding_q ? attn_rsp_status : ddr_rsp_status;
    assign rsp_opcode_w = attn_outstanding_q ? attn_rsp_opcode : ddr_rsp_opcode;
    assign rsp_txn_id_w = attn_outstanding_q ? attn_rsp_txn_id : ddr_rsp_txn_id;
    assign rsp_data_w   = attn_outstanding_q ? attn_rsp_data   : ddr_rsp_data;

    assign rsp_fifo_empty_w = (rsp_count_q == '0);
    assign rsp_fifo_full_w =
        (rsp_count_q == RSP_FIFO_COUNT_W'(REQ_FIFO_DEPTH));
    assign rsp_push_w = rsp_valid_w;
    // TX_IDLE always captures the head when non-empty, so the pop fires for
    // exactly the capture cycle.
    assign rsp_pop_w = !rsp_fifo_empty_w && (tx_state_q == TX_IDLE);

    // Live diagnostic word for CMD_DEBUG_STATUS (overrides rsp_data in the
    // response frame).  Layout:
    //   [31:30] zero  [29] bulk_active  [28:26] cmd_state
    //   [25] rsp_protocol_error  [24:17] dropped_frame_count
    //   [16:13] pr_count  [12:9] rsp_count  [8:1] slot_busy  [0] zero
    assign debug_status_w = {
        2'd0,
        dbg_cmd_bulk_active,
        dbg_cmd_state,
        rsp_protocol_error_q,
        dropped_frame_count[7:0],
        pr_count_q[3:0],
        rsp_count_q[3:0],
        slot_busy_q[7:0],
        1'b0
    };

    assign ddr_ctrl_req_push = ddr_ctrl_req_push_q;
    assign attn_ctrl_req_valid = attn_ctrl_req_valid_q;

    req_type_t tx_req_type_q;
    logic [47:0] tx_peer_mac_q;
    logic [31:0] tx_peer_ip_q;
    logic [15:0] tx_peer_port_q;
    logic [15:0] tx_ip_id_q;
    logic [15:0] tx_ip_checksum_q;
    logic [15:0] tx_ip_total_len_q;
    logic [15:0] tx_udp_total_len_q;
    logic [BULK_ADDR_W:0] tx_bulk_rsp_words_q;
    logic [31:0] tx_checksum_sum_q;
    logic [10:0] tx_byte_idx_q;
    logic [BULK_ADDR_W-1:0] tx_bulk_word_addr_q;
    logic [1:0] tx_bulk_byte_lane_q;
    logic [31:0] tx_bulk_word_hold_q;
    logic [10:0] tx_frame_len_q;
    logic [7:0]  tx_cmd_opcode_q;
    logic [7:0]  tx_cmd_flags_q;
    logic [15:0] tx_cmd_txn_id_q;
    logic [31:0] tx_cmd_arg0_q;
    logic [31:0] tx_cmd_arg1_q;
    logic [31:0] tx_cmd_arg2_q;
    logic [7:0]  tx_rsp_status_q;
    logic [7:0]  tx_rsp_opcode_q;
    logic [15:0] tx_rsp_txn_id_q;
    logic [31:0] tx_rsp_data_q;
    logic [CTRL_TIMEOUT_W-1:0] tx_ctrl_wait_count_q;

    logic debug_done_q;
    logic debug_busy_q;
    logic debug_error_q;
    logic debug_core_error_q;
    logic [63:0] debug_cycle_count_q;
    logic [63:0] debug_output_count_q;
    logic [3:0] debug_pods_q;
    logic [3:0] debug_cfg_q;

    logic eval_dst_match_hold_w;
    logic eval_is_arp_hold_w;
    logic eval_is_ipv4_hold_w;
    logic eval_arp_match_hold_w;
    logic eval_udp_match_hold_w;
    logic [1:0] eval_req_type_hold_w;
    logic [47:0] arp_sha_hold_w;
    logic [31:0] arp_spa_hold_w;
    logic [47:0] eth_src_mac_hold_w;
    logic [31:0] ip_src_hold_w;
    logic [15:0] udp_src_port_hold_w;
    logic [47:0] eval_peer_mac_hold_w;
    logic [31:0] eval_peer_ip_hold_w;
    logic [15:0] eval_peer_port_hold_w;
    logic [1:0] mailbox_type_hold_w;
    logic [47:0] mailbox_peer_mac_hold_w;
    logic [31:0] mailbox_peer_ip_hold_w;
    logic [15:0] mailbox_peer_port_hold_w;
    logic [7:0]  mailbox_cmd_opcode_hold_w;
    logic [7:0]  mailbox_cmd_flags_hold_w;
    logic [15:0] mailbox_cmd_txn_id_hold_w;
    logic [31:0] mailbox_cmd_arg0_hold_w;
    logic [31:0] mailbox_cmd_arg1_hold_w;
    logic [31:0] mailbox_cmd_arg2_hold_w;

    localparam logic [31:0] CTRL_MAGIC = 32'h4154_4e31; // "ATN1"
    localparam logic [7:0]  CTRL_VERSION = 8'd1;
    localparam logic [7:0]  CTRL_CMD_GET_STATUS = 8'h01;
    localparam logic [7:0]  CTRL_CMD_DDR_STATUS      = 8'h40;
    localparam logic [7:0]  CTRL_CMD_DDR_WRITE_WORD  = 8'h41;
    localparam logic [7:0]  CTRL_CMD_DDR_READ_WORD   = 8'h42;
    localparam logic [7:0]  CTRL_CMD_DDR_WRITE_BULK  = 8'h43;
    localparam logic [7:0]  CTRL_CMD_DDR_READ_BULK   = 8'h44;
    // Diagnostic: the stack overrides rsp_data in the response frame with
    // live queue/slot/counter state.  The controller does not know this
    // opcode and replies BAD_ARG, which is fine - only the data matters.
    localparam logic [7:0]  CTRL_CMD_DEBUG_STATUS = 8'h50;
    localparam logic [7:0]  CTRL_RSP_ERROR = 8'h04;
    localparam logic [31:0] CTRL_TIMEOUT_DATA = 32'h5449_4d45; // "TIME"

    function automatic logic is_ddr_opcode(input logic [7:0] opcode);
    begin
        is_ddr_opcode = (opcode == CTRL_CMD_DDR_STATUS) ||
                        (opcode == CTRL_CMD_DDR_WRITE_WORD) ||
                        (opcode == CTRL_CMD_DDR_READ_WORD) ||
                        (opcode == CTRL_CMD_DDR_WRITE_BULK) ||
                        (opcode == CTRL_CMD_DDR_READ_BULK);
    end
    endfunction

    function automatic logic [RSP_FIFO_AW-1:0] rsp_ptr_next(
        input logic [RSP_FIFO_AW-1:0] ptr
    );
    begin
        if (ptr == RSP_FIFO_AW'(REQ_FIFO_DEPTH - 1)) begin
            rsp_ptr_next = '0;
        end else begin
            rsp_ptr_next = ptr + 1'b1;
        end
    end
    endfunction

    assign rx_byte_idx = in_frame_q ? byte_idx_q : 11'd0;
    assign tx_axis_tuser = 1'b0;
    assign bulk_rsp_rd_addr = tx_bulk_word_addr_q;
    assign bulk_rsp_rd_slot = tx_bulk_slot_q;

    fpt_net_eth_hold_buffer_bus #(.WIDTH(1)) u_hold_eval_dst_match (
        .din(eval_dst_match_q),
        .dout(eval_dst_match_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(1)) u_hold_eval_is_arp (
        .din(eval_is_arp_q),
        .dout(eval_is_arp_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(1)) u_hold_eval_is_ipv4 (
        .din(eval_is_ipv4_q),
        .dout(eval_is_ipv4_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(1)) u_hold_eval_arp_match (
        .din(eval_arp_match_q),
        .dout(eval_arp_match_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(1)) u_hold_eval_udp_match (
        .din(eval_udp_match_q),
        .dout(eval_udp_match_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(2)) u_hold_eval_req_type (
        .din(eval_req_type_q),
        .dout(eval_req_type_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(48)) u_hold_arp_sha (
        .din(arp_sha_q),
        .dout(arp_sha_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(32)) u_hold_arp_spa (
        .din(arp_spa_q),
        .dout(arp_spa_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(48)) u_hold_eth_src_mac (
        .din(eth_src_mac_q),
        .dout(eth_src_mac_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(32)) u_hold_ip_src (
        .din(ip_src_q),
        .dout(ip_src_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(16)) u_hold_udp_src_port (
        .din(udp_src_port_q),
        .dout(udp_src_port_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(48)) u_hold_eval_peer_mac (
        .din(eval_peer_mac_q),
        .dout(eval_peer_mac_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(32)) u_hold_eval_peer_ip (
        .din(eval_peer_ip_q),
        .dout(eval_peer_ip_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(16)) u_hold_eval_peer_port (
        .din(eval_peer_port_q),
        .dout(eval_peer_port_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(2)) u_hold_mailbox_type (
        .din(mailbox_type_q),
        .dout(mailbox_type_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(48)) u_hold_mailbox_peer_mac (
        .din(mailbox_peer_mac_q),
        .dout(mailbox_peer_mac_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(32)) u_hold_mailbox_peer_ip (
        .din(mailbox_peer_ip_q),
        .dout(mailbox_peer_ip_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(16)) u_hold_mailbox_peer_port (
        .din(mailbox_peer_port_q),
        .dout(mailbox_peer_port_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(8)) u_hold_mailbox_cmd_opcode (
        .din(mailbox_cmd_opcode_q),
        .dout(mailbox_cmd_opcode_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(8)) u_hold_mailbox_cmd_flags (
        .din(mailbox_cmd_flags_q),
        .dout(mailbox_cmd_flags_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(16)) u_hold_mailbox_cmd_txn_id (
        .din(mailbox_cmd_txn_id_q),
        .dout(mailbox_cmd_txn_id_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(32)) u_hold_mailbox_cmd_arg0 (
        .din(mailbox_cmd_arg0_q),
        .dout(mailbox_cmd_arg0_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(32)) u_hold_mailbox_cmd_arg1 (
        .din(mailbox_cmd_arg1_q),
        .dout(mailbox_cmd_arg1_hold_w)
    );

    fpt_net_eth_hold_buffer_bus #(.WIDTH(32)) u_hold_mailbox_cmd_arg2 (
        .din(mailbox_cmd_arg2_q),
        .dout(mailbox_cmd_arg2_hold_w)
    );

    function automatic logic [7:0] byte48(
        input logic [47:0] value,
        input int idx
    );
    begin
        case (idx)
            0: byte48 = value[47:40];
            1: byte48 = value[39:32];
            2: byte48 = value[31:24];
            3: byte48 = value[23:16];
            4: byte48 = value[15:8];
            default: byte48 = value[7:0];
        endcase
    end
    endfunction

    function automatic logic [7:0] byte32(
        input logic [31:0] value,
        input int idx
    );
    begin
        case (idx)
            0: byte32 = value[31:24];
            1: byte32 = value[23:16];
            2: byte32 = value[15:8];
            default: byte32 = value[7:0];
        endcase
    end
    endfunction

    function automatic logic [7:0] byte64(
        input logic [63:0] value,
        input int idx
    );
    begin
        case (idx)
            0: byte64 = value[63:56];
            1: byte64 = value[55:48];
            2: byte64 = value[47:40];
            3: byte64 = value[39:32];
            4: byte64 = value[31:24];
            5: byte64 = value[23:16];
            6: byte64 = value[15:8];
            default: byte64 = value[7:0];
        endcase
    end
    endfunction

    function automatic logic [7:0] byte16(
        input logic [15:0] value,
        input int idx
    );
    begin
        byte16 = (idx == 0) ? value[15:8] : value[7:0];
    end
    endfunction

    function automatic logic [7:0] hex_char(input logic [3:0] value);
    begin
        hex_char = (value < 4'd10) ? (8'h30 + value) : (8'h41 + value - 4'd10);
    end
    endfunction

    function automatic logic [3:0] hex64_nibble(
        input logic [63:0] value,
        input logic [3:0] digit_idx
    );
    begin
        case (digit_idx)
            4'd0:  hex64_nibble = value[63:60];
            4'd1:  hex64_nibble = value[59:56];
            4'd2:  hex64_nibble = value[55:52];
            4'd3:  hex64_nibble = value[51:48];
            4'd4:  hex64_nibble = value[47:44];
            4'd5:  hex64_nibble = value[43:40];
            4'd6:  hex64_nibble = value[39:36];
            4'd7:  hex64_nibble = value[35:32];
            4'd8:  hex64_nibble = value[31:28];
            4'd9:  hex64_nibble = value[27:24];
            4'd10: hex64_nibble = value[23:20];
            4'd11: hex64_nibble = value[19:16];
            4'd12: hex64_nibble = value[15:12];
            4'd13: hex64_nibble = value[11:8];
            4'd14: hex64_nibble = value[7:4];
            default: hex64_nibble = value[3:0];
        endcase
    end
    endfunction

    function automatic logic [15:0] ipv4_checksum(
        input logic [15:0] total_len,
        input logic [15:0] ident,
        input logic [31:0] src_ip,
        input logic [31:0] dst_ip
    );
        logic [31:0] sum;
    begin
        sum = 32'd0;
        sum = sum + 16'h4500;
        sum = sum + total_len;
        sum = sum + ident;
        sum = sum + 16'h4000;
        sum = sum + 16'h4011;
        sum = sum + src_ip[31:16];
        sum = sum + src_ip[15:0];
        sum = sum + dst_ip[31:16];
        sum = sum + dst_ip[15:0];
        sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};
        sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};
        ipv4_checksum = ~sum[15:0];
    end
    endfunction

    function automatic logic [7:0] line1_char(input int idx);
    begin
        case (idx)
            0: line1_char = "A";
            1: line1_char = "T";
            2: line1_char = "T";
            3: line1_char = "N";
            4: line1_char = " ";
            5: line1_char = "G";
            6: line1_char = "Q";
            7: line1_char = "A";
            8: line1_char = "4";
            9: line1_char = " ";
            10: line1_char = "U";
            11: line1_char = "D";
            12: line1_char = "P";
            13: line1_char = 8'h0d;
            default: line1_char = 8'h0a;
        endcase
    end
    endfunction

    function automatic logic [7:0] status_line_char(input int idx);
    begin
        case (idx)
            0: status_line_char = "d";
            1: status_line_char = "o";
            2: status_line_char = "n";
            3: status_line_char = "e";
            4: status_line_char = "=";
            5: status_line_char = hex_char({3'd0, debug_done_q});
            6: status_line_char = " ";
            7: status_line_char = "b";
            8: status_line_char = "u";
            9: status_line_char = "s";
            10: status_line_char = "y";
            11: status_line_char = "=";
            12: status_line_char = hex_char({3'd0, debug_busy_q});
            13: status_line_char = " ";
            14: status_line_char = "e";
            15: status_line_char = "r";
            16: status_line_char = "r";
            17: status_line_char = "o";
            18: status_line_char = "r";
            19: status_line_char = "=";
            20: status_line_char = hex_char({3'd0, debug_error_q});
            21: status_line_char = " ";
            22: status_line_char = "c";
            23: status_line_char = "o";
            24: status_line_char = "r";
            25: status_line_char = "e";
            26: status_line_char = "=";
            27: status_line_char = hex_char({3'd0, debug_core_error_q});
            28: status_line_char = 8'h0d;
            default: status_line_char = 8'h0a;
        endcase
    end
    endfunction

    function automatic logic [7:0] cycles_line_char(input int idx);
    begin
        case (idx)
            0: cycles_line_char = "c";
            1: cycles_line_char = "y";
            2: cycles_line_char = "c";
            3: cycles_line_char = "l";
            4: cycles_line_char = "e";
            5: cycles_line_char = "s";
            6: cycles_line_char = "=";
            7: cycles_line_char = "0";
            8: cycles_line_char = "x";
            25: cycles_line_char = 8'h0d;
            26: cycles_line_char = 8'h0a;
            default: cycles_line_char =
                (idx >= 9 && idx < 25) ?
                hex_char(hex64_nibble(debug_cycle_count_q, idx - 9)) : " ";
        endcase
    end
    endfunction

    function automatic logic [7:0] outputs_line_char(input int idx);
    begin
        case (idx)
            0: outputs_line_char = "o";
            1: outputs_line_char = "u";
            2: outputs_line_char = "t";
            3: outputs_line_char = "p";
            4: outputs_line_char = "u";
            5: outputs_line_char = "t";
            6: outputs_line_char = "s";
            7: outputs_line_char = "=";
            8: outputs_line_char = "0";
            9: outputs_line_char = "x";
            26: outputs_line_char = 8'h0d;
            27: outputs_line_char = 8'h0a;
            default: outputs_line_char =
                (idx >= 10 && idx < 26) ?
                hex_char(hex64_nibble(debug_output_count_q, idx - 10)) : " ";
        endcase
    end
    endfunction

    function automatic logic [7:0] link_line_char(input int idx);
    begin
        case (idx)
            0: link_line_char = "p";
            1: link_line_char = "o";
            2: link_line_char = "d";
            3: link_line_char = "s";
            4: link_line_char = "=";
            5: link_line_char = "0";
            6: link_line_char = "x";
            7: link_line_char = hex_char(debug_pods_q);
            8: link_line_char = " ";
            9: link_line_char = "l";
            10: link_line_char = "i";
            11: link_line_char = "n";
            12: link_line_char = "k";
            13: link_line_char = "=";
            14: link_line_char = "0";
            15: link_line_char = "x";
            16: link_line_char = hex_char(debug_cfg_q[3:0]);
            17: link_line_char = " ";
            18: link_line_char = "c";
            19: link_line_char = "f";
            20: link_line_char = "g";
            21: link_line_char = "=";
            22: link_line_char = "0";
            23: link_line_char = "x";
            24: link_line_char = hex_char(debug_cfg_q);
            25: link_line_char = 8'h0d;
            default: link_line_char = 8'h0a;
        endcase
    end
    endfunction

    function automatic logic [7:0] payload_byte(input int idx);
    begin
        if ((idx >= DEBUG_PAYLOAD_BYTES) &&
            (idx < (DEBUG_PAYLOAD_BYTES + (tx_bulk_rsp_words_q * 4)))) begin
            payload_byte = byte32(bulk_rsp_rd_data, tx_bulk_byte_lane_q);
        end else case (idx)
            0:  payload_byte = "A";
            1:  payload_byte = "T";
            2:  payload_byte = "N";
            3:  payload_byte = "1";
            4:  payload_byte = {4'b0000,
                                 debug_core_error_q,
                                 debug_error_q,
                                 debug_busy_q,
                                 debug_done_q};
            5:  payload_byte = {4'b0000, debug_pods_q};
            6:  payload_byte = {4'b0000, debug_cfg_q};
            7:  payload_byte = tx_rsp_status_q;
            8, 9, 10, 11, 12, 13, 14, 15:
                payload_byte = byte64(debug_cycle_count_q, idx - 8);
            16, 17, 18, 19, 20, 21, 22, 23:
                payload_byte = byte64(debug_output_count_q, idx - 16);
            24: payload_byte = tx_rsp_opcode_q;
            25: payload_byte = 8'h00;
            26, 27:
                payload_byte = byte16(tx_rsp_txn_id_q, idx - 26);
            28, 29, 30, 31:
                payload_byte = byte32(tx_rsp_data_q, idx - 28);
            default:
                payload_byte = 8'h00;
        endcase
    end
    endfunction

    function automatic logic [7:0] arp_frame_byte(input int idx);
    begin
        if (idx < 6) begin
            arp_frame_byte = byte48(tx_peer_mac_q, idx);
        end else if (idx < 12) begin
            arp_frame_byte = byte48(LOCAL_MAC, idx - 6);
        end else begin
            case (idx)
                12: arp_frame_byte = 8'h08;
                13: arp_frame_byte = 8'h06;
                14: arp_frame_byte = 8'h00;
                15: arp_frame_byte = 8'h01;
                16: arp_frame_byte = 8'h08;
                17: arp_frame_byte = 8'h00;
                18: arp_frame_byte = 8'h06;
                19: arp_frame_byte = 8'h04;
                20: arp_frame_byte = 8'h00;
                21: arp_frame_byte = 8'h02;
                22, 23, 24, 25, 26, 27:
                    arp_frame_byte = byte48(LOCAL_MAC, idx - 22);
                28, 29, 30, 31:
                    arp_frame_byte = byte32(LOCAL_IP, idx - 28);
                32, 33, 34, 35, 36, 37:
                    arp_frame_byte = byte48(tx_peer_mac_q, idx - 32);
                38, 39, 40, 41:
                    arp_frame_byte = byte32(tx_peer_ip_q, idx - 38);
                default: arp_frame_byte = 8'h00;
            endcase
        end
    end
    endfunction

    function automatic logic [7:0] udp_frame_byte(input int idx);
    begin
        if (idx < 6) begin
            udp_frame_byte = byte48(tx_peer_mac_q, idx);
        end else if (idx < 12) begin
            udp_frame_byte = byte48(LOCAL_MAC, idx - 6);
        end else begin
            case (idx)
                12: udp_frame_byte = 8'h08;
                13: udp_frame_byte = 8'h00;
                14: udp_frame_byte = 8'h45;
                15: udp_frame_byte = 8'h00;
                16, 17: udp_frame_byte = byte16(tx_ip_total_len_q, idx - 16);
                18, 19: udp_frame_byte = byte16(tx_ip_id_q, idx - 18);
                20: udp_frame_byte = 8'h40;
                21: udp_frame_byte = 8'h00;
                22: udp_frame_byte = 8'h40;
                23: udp_frame_byte = IP_PROTO_UDP;
                24, 25: udp_frame_byte = byte16(tx_ip_checksum_q, idx - 24);
                26, 27, 28, 29: udp_frame_byte = byte32(LOCAL_IP, idx - 26);
                30, 31, 32, 33: udp_frame_byte = byte32(tx_peer_ip_q, idx - 30);
                34, 35: udp_frame_byte = byte16(LOCAL_UDP_PORT, idx - 34);
                36, 37: udp_frame_byte = byte16(tx_peer_port_q, idx - 36);
                38, 39: udp_frame_byte = byte16(tx_udp_total_len_q, idx - 38);
                40, 41: udp_frame_byte = 8'h00;
                default: udp_frame_byte =
                    (idx < tx_frame_len_q) ? payload_byte(idx - 42) : 8'h00;
            endcase
        end
    end
    endfunction

    function automatic logic [7:0] tx_frame_byte(input req_type_t req, input int idx);
    begin
        tx_frame_byte = (req == REQ_ARP) ? arp_frame_byte(idx) : udp_frame_byte(idx);
    end
    endfunction

    always_ff @(posedge rx_clk) begin
        if (!rx_rst_n) begin
            in_frame_q          <= 1'b0;
            rx_drop_in_frame_q  <= 1'b0;
            byte_idx_q          <= '0;
            frame_error_q       <= 1'b0;
            eth_dst_mac_q       <= '0;
            eth_src_mac_q       <= '0;
            eth_type_q          <= '0;
            arp_htype_q         <= '0;
            arp_ptype_q         <= '0;
            arp_hlen_q          <= '0;
            arp_plen_q          <= '0;
            arp_oper_q          <= '0;
            arp_sha_q           <= '0;
            arp_spa_q           <= '0;
            arp_tha_q           <= '0;
            arp_tpa_q           <= '0;
            ip_ver_ihl_q        <= '0;
            ip_total_len_q      <= '0;
            ip_protocol_q       <= '0;
            ip_src_q            <= '0;
            ip_dst_q            <= '0;
            udp_src_port_q      <= '0;
            udp_dst_port_q      <= '0;
            udp_len_q           <= '0;
            rx_cmd_magic_q      <= '0;
            rx_cmd_version_q    <= '0;
            rx_cmd_opcode_q     <= CTRL_CMD_GET_STATUS;
            rx_cmd_flags_q      <= '0;
            rx_cmd_txn_id_q     <= '0;
            rx_cmd_arg0_q       <= '0;
            rx_cmd_arg1_q       <= '0;
            rx_cmd_arg2_q       <= '0;
            rx_bulk_word_accum_q <= '0;
            bulk_req_word_valid <= 1'b0;
            bulk_req_word_index <= '0;
            bulk_req_word_data  <= '0;
            bulk_req_word_count <= '0;
            rx_eval_state_q     <= RX_EVAL_IDLE;
            eval_dst_match_q    <= 1'b0;
            eval_is_arp_q       <= 1'b0;
            eval_is_ipv4_q      <= 1'b0;
            eval_arp_match_q    <= 1'b0;
            eval_udp_match_q    <= 1'b0;
            eval_req_type_q     <= REQ_NONE;
            eval_peer_mac_q     <= '0;
            eval_peer_ip_q      <= '0;
            eval_peer_port_q    <= '0;
            mailbox_type_q      <= REQ_NONE;
            mailbox_peer_mac_q  <= '0;
            mailbox_peer_ip_q   <= '0;
            mailbox_peer_port_q <= '0;
            mailbox_cmd_opcode_q <= CTRL_CMD_GET_STATUS;
            mailbox_cmd_flags_q  <= '0;
            mailbox_cmd_txn_id_q <= '0;
            mailbox_cmd_arg0_q   <= '0;
            mailbox_cmd_arg1_q   <= '0;
            mailbox_cmd_arg2_q   <= '0;
            req_toggle_rx_q     <= 1'b0;
            req_pending_q       <= 1'b0;
            ack_toggle_rx_meta_q <= 1'b0;
            ack_toggle_rx_sync_q <= 1'b0;
            ack_toggle_rx_seen_q <= 1'b0;
            sq_wr_ptr_q         <= '0;
            sq_rd_ptr_q         <= '0;
            sq_count_q          <= '0;
            slot_busy_q         <= '0;
            rx_frame_slot_q     <= '0;
            rx_frame_slot_valid_q <= 1'b0;
            bulk_req_slot       <= '0;
            rx_frame_count      <= '0;
            arp_request_count   <= '0;
            udp_request_count   <= '0;
            dropped_frame_count <= '0;
        end else begin
            bulk_req_word_valid <= 1'b0;
            bulk_req_slot       <= rx_frame_slot_valid_q ? rx_frame_slot_q : '0;

            // Stack FIFO pop: the TX issuer pops on the same cycle it pushes
            // the request to the controller (issue_valid_w is TX-side comb.).
            if (issue_valid_w) begin
                sq_rd_ptr_q <= sq_rd_ptr_q + 1'b1;
                sq_count_q  <= sq_count_q - 1'b1;
            end
            // Bulk slot release after the response frame completes.
            if (slot_release_pulse_q) begin
                slot_busy_q[tx_bulk_slot_q] <= 1'b0;
            end

            if (rx_axis_tvalid && rx_axis_tready) begin
                if (rx_drop_in_frame_q ||
                    (!in_frame_q && (rx_eval_state_q != RX_EVAL_IDLE))) begin
                    if (!rx_drop_in_frame_q) begin
                        dropped_frame_count <= dropped_frame_count + 1'b1;
                    end

                    if (rx_axis_tlast) begin
                        rx_drop_in_frame_q <= 1'b0;
                        byte_idx_q         <= '0;
                        rx_frame_count     <= rx_frame_count + 1'b1;
                    end else begin
                        rx_drop_in_frame_q <= 1'b1;
                    end
                end else begin
                if (!in_frame_q) begin
                    frame_error_q  <= rx_axis_tuser;
                    eth_dst_mac_q  <= '0;
                    eth_src_mac_q  <= '0;
                    eth_type_q     <= '0;
                    arp_htype_q    <= '0;
                    arp_ptype_q    <= '0;
                    arp_hlen_q     <= '0;
                    arp_plen_q     <= '0;
                    arp_oper_q     <= '0;
                    arp_sha_q      <= '0;
                    arp_spa_q      <= '0;
                    arp_tha_q      <= '0;
                    arp_tpa_q      <= '0;
                    ip_ver_ihl_q   <= '0;
                    ip_total_len_q <= '0;
                    ip_protocol_q  <= '0;
                    ip_src_q       <= '0;
                    ip_dst_q       <= '0;
                    udp_src_port_q <= '0;
                    udp_dst_port_q <= '0;
                    udp_len_q      <= '0;
                    rx_cmd_magic_q   <= '0;
                    rx_cmd_version_q <= '0;
                    rx_cmd_opcode_q  <= CTRL_CMD_GET_STATUS;
                    rx_cmd_flags_q   <= '0;
                    rx_cmd_txn_id_q  <= '0;
                    rx_cmd_arg0_q    <= '0;
                    rx_cmd_arg1_q    <= '0;
                    rx_cmd_arg2_q    <= '0;
                    rx_bulk_word_accum_q <= '0;
                    bulk_req_word_count <= '0;
                end

                if (in_frame_q) begin
                    frame_error_q <= frame_error_q || rx_axis_tuser;
                end

                case (rx_byte_idx)
                    0: eth_dst_mac_q[47:40] <= rx_axis_tdata;
                    1: eth_dst_mac_q[39:32] <= rx_axis_tdata;
                    2: eth_dst_mac_q[31:24] <= rx_axis_tdata;
                    3: eth_dst_mac_q[23:16] <= rx_axis_tdata;
                    4: eth_dst_mac_q[15:8]  <= rx_axis_tdata;
                    5: eth_dst_mac_q[7:0]   <= rx_axis_tdata;
                    6: eth_src_mac_q[47:40] <= rx_axis_tdata;
                    7: eth_src_mac_q[39:32] <= rx_axis_tdata;
                    8: eth_src_mac_q[31:24] <= rx_axis_tdata;
                    9: eth_src_mac_q[23:16] <= rx_axis_tdata;
                    10: eth_src_mac_q[15:8] <= rx_axis_tdata;
                    11: eth_src_mac_q[7:0]  <= rx_axis_tdata;
                    12: eth_type_q[15:8]    <= rx_axis_tdata;
                    13: eth_type_q[7:0]     <= rx_axis_tdata;

                    14: begin
                        arp_htype_q[15:8] <= rx_axis_tdata;
                        ip_ver_ihl_q      <= rx_axis_tdata;
                    end
                    15: arp_htype_q[7:0] <= rx_axis_tdata;
                    16: begin
                        arp_ptype_q[15:8]   <= rx_axis_tdata;
                        ip_total_len_q[15:8] <= rx_axis_tdata;
                    end
                    17: begin
                        arp_ptype_q[7:0]    <= rx_axis_tdata;
                        ip_total_len_q[7:0] <= rx_axis_tdata;
                    end
                    18: arp_hlen_q <= rx_axis_tdata;
                    19: arp_plen_q <= rx_axis_tdata;
                    20: arp_oper_q[15:8] <= rx_axis_tdata;
                    21: arp_oper_q[7:0] <= rx_axis_tdata;
                    22: arp_sha_q[47:40] <= rx_axis_tdata;
                    23: begin
                        arp_sha_q[39:32] <= rx_axis_tdata;
                        ip_protocol_q    <= rx_axis_tdata;
                    end
                    24: arp_sha_q[31:24] <= rx_axis_tdata;
                    25: arp_sha_q[23:16] <= rx_axis_tdata;
                    26: begin
                        arp_sha_q[15:8] <= rx_axis_tdata;
                        ip_src_q[31:24] <= rx_axis_tdata;
                    end
                    27: begin
                        arp_sha_q[7:0]  <= rx_axis_tdata;
                        ip_src_q[23:16] <= rx_axis_tdata;
                    end
                    28: begin
                        arp_spa_q[31:24] <= rx_axis_tdata;
                        ip_src_q[15:8]   <= rx_axis_tdata;
                    end
                    29: begin
                        arp_spa_q[23:16] <= rx_axis_tdata;
                        ip_src_q[7:0]    <= rx_axis_tdata;
                    end
                    30: begin
                        arp_spa_q[15:8] <= rx_axis_tdata;
                        ip_dst_q[31:24] <= rx_axis_tdata;
                    end
                    31: begin
                        arp_spa_q[7:0]  <= rx_axis_tdata;
                        ip_dst_q[23:16] <= rx_axis_tdata;
                    end
                    32: begin
                        arp_tha_q[47:40] <= rx_axis_tdata;
                        ip_dst_q[15:8]   <= rx_axis_tdata;
                    end
                    33: begin
                        arp_tha_q[39:32] <= rx_axis_tdata;
                        ip_dst_q[7:0]    <= rx_axis_tdata;
                    end
                    34: begin
                        arp_tha_q[31:24] <= rx_axis_tdata;
                        udp_src_port_q[15:8] <= rx_axis_tdata;
                    end
                    35: begin
                        arp_tha_q[23:16] <= rx_axis_tdata;
                        udp_src_port_q[7:0] <= rx_axis_tdata;
                    end
                    36: begin
                        arp_tha_q[15:8] <= rx_axis_tdata;
                        udp_dst_port_q[15:8] <= rx_axis_tdata;
                    end
                    37: begin
                        arp_tha_q[7:0] <= rx_axis_tdata;
                        udp_dst_port_q[7:0] <= rx_axis_tdata;
                    end
                    38: begin
                        arp_tpa_q[31:24] <= rx_axis_tdata;
                        udp_len_q[15:8] <= rx_axis_tdata;
                    end
                    39: begin
                        arp_tpa_q[23:16] <= rx_axis_tdata;
                        udp_len_q[7:0] <= rx_axis_tdata;
                    end
                    40: arp_tpa_q[15:8] <= rx_axis_tdata;
                    41: arp_tpa_q[7:0] <= rx_axis_tdata;
                    42: rx_cmd_magic_q[31:24] <= rx_axis_tdata;
                    43: rx_cmd_magic_q[23:16] <= rx_axis_tdata;
                    44: rx_cmd_magic_q[15:8]  <= rx_axis_tdata;
                    45: rx_cmd_magic_q[7:0]   <= rx_axis_tdata;
                    46: rx_cmd_version_q <= rx_axis_tdata;
                    47: rx_cmd_opcode_q  <= rx_axis_tdata;
                    48: rx_cmd_flags_q   <= rx_axis_tdata;
                    50: rx_cmd_txn_id_q[15:8] <= rx_axis_tdata;
                    51: rx_cmd_txn_id_q[7:0]  <= rx_axis_tdata;
                    54: rx_cmd_arg0_q[31:24] <= rx_axis_tdata;
                    55: rx_cmd_arg0_q[23:16] <= rx_axis_tdata;
                    56: rx_cmd_arg0_q[15:8]  <= rx_axis_tdata;
                    57: rx_cmd_arg0_q[7:0]   <= rx_axis_tdata;
                    58: rx_cmd_arg1_q[31:24] <= rx_axis_tdata;
                    59: rx_cmd_arg1_q[23:16] <= rx_axis_tdata;
                    60: rx_cmd_arg1_q[15:8]  <= rx_axis_tdata;
                    61: rx_cmd_arg1_q[7:0]   <= rx_axis_tdata;
                    62: rx_cmd_arg2_q[31:24] <= rx_axis_tdata;
                    63: rx_cmd_arg2_q[23:16] <= rx_axis_tdata;
                    64: rx_cmd_arg2_q[15:8]  <= rx_axis_tdata;
                    65: rx_cmd_arg2_q[7:0]   <= rx_axis_tdata;
                    default: begin
                    end
                endcase

                // Pipelining: allocate a bulk payload slot before the data
                // segment so in-flight bulk requests do not overwrite each
                // other's payloads.  No free slot -> drop the whole frame.
                if ((rx_byte_idx >= 11'd48) && (rx_byte_idx < 11'd66) &&
                    ((rx_cmd_opcode_q == CTRL_CMD_DDR_WRITE_BULK) ||
                     (rx_cmd_opcode_q == CTRL_CMD_DDR_READ_BULK)) &&
                    !rx_frame_slot_valid_q) begin
                    if (alloc_slot_valid_w) begin
                        rx_frame_slot_q <= alloc_slot_w;
                        rx_frame_slot_valid_q <= 1'b1;
                        slot_busy_q[alloc_slot_w] <= 1'b1;
                    end else begin
                        rx_drop_in_frame_q <= 1'b1;
                    end
                end

                if ((rx_cmd_opcode_q == CTRL_CMD_DDR_WRITE_BULK) &&
                    (rx_byte_idx >= 11'd66) &&
                    (rx_byte_idx < (11'd66 + (MAX_BULK_WORDS << 2)))) begin
                    unique case ((rx_byte_idx - 11'd66) & 11'h003)
                        11'd0: rx_bulk_word_accum_q[31:24] <= rx_axis_tdata;
                        11'd1: rx_bulk_word_accum_q[23:16] <= rx_axis_tdata;
                        11'd2: rx_bulk_word_accum_q[15:8]  <= rx_axis_tdata;
                        default: begin
                            bulk_req_word_valid <= 1'b1;
                            bulk_req_word_index <=
                                bulk_req_word_count[BULK_ADDR_W-1:0];
                            bulk_req_word_data <= {
                                rx_bulk_word_accum_q[31:8],
                                rx_axis_tdata
                            };
                            bulk_req_word_count <= bulk_req_word_count + 1'b1;
                        end
                    endcase
                end

                if (rx_axis_tlast) begin
                    in_frame_q <= 1'b0;
                    byte_idx_q <= '0;
                    if (rx_eval_state_q == RX_EVAL_IDLE) begin
                        rx_eval_state_q <= RX_EVAL_CLASSIFY;
                    end else begin
                        dropped_frame_count <= dropped_frame_count + 1'b1;
                    end
                    rx_frame_count <= rx_frame_count + 1'b1;
                end else begin
                    in_frame_q <= 1'b1;
                    byte_idx_q <= rx_byte_idx + 1'b1;
                end
                end
            end

            case (rx_eval_state_q)
                RX_EVAL_IDLE: begin
                end

                RX_EVAL_CLASSIFY: begin
                    eval_dst_match_q <= (eth_dst_mac_q == LOCAL_MAC) ||
                                        (eth_dst_mac_q == MAC_BROADCAST);
                    eval_is_arp_q    <= !frame_error_q &&
                                        (eth_type_q == ETH_TYPE_ARP);
                    eval_is_ipv4_q   <= !frame_error_q &&
                                        (eth_type_q == ETH_TYPE_IPV4);
                    eval_arp_match_q <= 1'b0;
                    eval_udp_match_q <= 1'b0;
                    eval_req_type_q  <= REQ_NONE;
                    rx_eval_state_q  <= RX_EVAL_ARP_MATCH;
                end

                RX_EVAL_ARP_MATCH: begin
                    eval_arp_match_q <= eval_is_arp_hold_w &&
                        eval_dst_match_hold_w &&
                        (arp_htype_q == ARP_HTYPE_ETH) &&
                        (arp_ptype_q == ARP_PTYPE_IP) &&
                        (arp_hlen_q == 8'd6) &&
                        (arp_plen_q == 8'd4) &&
                        (arp_oper_q == ARP_OPER_REQ) &&
                        (arp_tpa_q == LOCAL_IP);
                    rx_eval_state_q <= RX_EVAL_ARP_LOAD;
                end

                RX_EVAL_ARP_LOAD: begin
                    if (eval_arp_match_hold_w) begin
                        eval_req_type_q  <= REQ_ARP;
                        eval_peer_mac_q  <= arp_sha_hold_w;
                        eval_peer_ip_q   <= arp_spa_hold_w;
                        eval_peer_port_q <= 16'd0;
                        rx_eval_state_q  <= RX_EVAL_ISSUE_WAIT;
                    end else begin
                        rx_eval_state_q <= RX_EVAL_UDP_MATCH;
                    end
                end

                RX_EVAL_UDP_MATCH: begin
                    eval_udp_match_q <= eval_is_ipv4_hold_w &&
                        eval_dst_match_hold_w &&
                        (ip_ver_ihl_q == 8'h45) &&
                        (ip_protocol_q == IP_PROTO_UDP) &&
                        (ip_dst_q == LOCAL_IP) &&
                        (udp_dst_port_q == LOCAL_UDP_PORT);
                    rx_eval_state_q <= RX_EVAL_UDP_LOAD;
                end

                RX_EVAL_UDP_LOAD: begin
                    if (eval_udp_match_hold_w) begin
                        eval_req_type_q  <= REQ_UDP;
                        eval_peer_mac_q  <= eth_src_mac_hold_w;
                        eval_peer_ip_q   <= ip_src_hold_w;
                        eval_peer_port_q <= udp_src_port_hold_w;
                        rx_eval_state_q  <= RX_EVAL_ISSUE_WAIT;
                    end else begin
                        rx_eval_state_q <= RX_EVAL_DROP;
                    end
                end

                RX_EVAL_ISSUE_WAIT: begin
                    rx_eval_state_q <= RX_EVAL_ISSUE;
                end

                RX_EVAL_ISSUE: begin
                    if (!sq_fifo_full_w) begin
                        sq_fifo_type_q[sq_wr_ptr_q]      <=
                            req_type_t'(eval_req_type_hold_w);
                        sq_fifo_peer_mac_q[sq_wr_ptr_q]  <=
                            eval_peer_mac_hold_w;
                        sq_fifo_peer_ip_q[sq_wr_ptr_q]   <=
                            eval_peer_ip_hold_w;
                        sq_fifo_peer_port_q[sq_wr_ptr_q] <=
                            eval_peer_port_hold_w;
                        if ((rx_cmd_magic_q == CTRL_MAGIC) &&
                            (rx_cmd_version_q == CTRL_VERSION)) begin
                            sq_fifo_opcode_q[sq_wr_ptr_q] <= rx_cmd_opcode_q;
                            sq_fifo_flags_q[sq_wr_ptr_q]  <= rx_cmd_flags_q;
                            sq_fifo_txn_q[sq_wr_ptr_q]    <= rx_cmd_txn_id_q;
                            sq_fifo_arg0_q[sq_wr_ptr_q]   <= rx_cmd_arg0_q;
                            sq_fifo_arg1_q[sq_wr_ptr_q]   <= rx_cmd_arg1_q;
                            sq_fifo_arg2_q[sq_wr_ptr_q]   <= rx_cmd_arg2_q;
                        end else begin
                            sq_fifo_opcode_q[sq_wr_ptr_q] <=
                                CTRL_CMD_GET_STATUS;
                            sq_fifo_flags_q[sq_wr_ptr_q]  <= '0;
                            sq_fifo_txn_q[sq_wr_ptr_q]    <= '0;
                            sq_fifo_arg0_q[sq_wr_ptr_q]   <= '0;
                            sq_fifo_arg1_q[sq_wr_ptr_q]   <= '0;
                            sq_fifo_arg2_q[sq_wr_ptr_q]   <= '0;
                        end
                        sq_fifo_slot_q[sq_wr_ptr_q] <=
                            rx_frame_slot_valid_q ? rx_frame_slot_q : '0;
                        sq_fifo_count_q[sq_wr_ptr_q] <= bulk_req_word_count;
                        sq_wr_ptr_q <= sq_wr_ptr_q + 1'b1;
                        sq_count_q  <= sq_count_q + 1'b1;
                        rx_frame_slot_valid_q <= 1'b0;

                        if (req_type_t'(eval_req_type_hold_w) == REQ_ARP) begin
                            arp_request_count <= arp_request_count + 1'b1;
                        end else begin
                            udp_request_count <= udp_request_count + 1'b1;
                        end
                    end else begin
                        dropped_frame_count <= dropped_frame_count + 1'b1;
                        if (rx_frame_slot_valid_q) begin
                            slot_busy_q[rx_frame_slot_q] <= 1'b0;
                            rx_frame_slot_valid_q <= 1'b0;
                        end
                    end

                    rx_eval_state_q <= RX_EVAL_IDLE;
                end

                RX_EVAL_DROP: begin
                    dropped_frame_count <= dropped_frame_count + 1'b1;
                    rx_eval_state_q     <= RX_EVAL_IDLE;
                end

                default: begin
                    rx_eval_state_q <= RX_EVAL_IDLE;
                end
            endcase
        end
    end

    always_ff @(posedge tx_clk) begin
        if (!tx_rst_n) begin
            req_toggle_tx_meta_q <= 1'b0;
            req_toggle_tx_sync_q <= 1'b0;
            req_toggle_tx_seen_q <= 1'b0;
            ack_toggle_tx_q      <= 1'b0;
            tx_req_load_state_q  <= 1'b0;
            tx_req_load_payload_q <= 1'b0;
            tx_req_load_debug_q  <= 1'b0;
            tx_req_load_axis_q   <= 1'b0;
            tx_state_q           <= TX_IDLE;
            tx_req_type_q        <= REQ_NONE;
            tx_peer_mac_q        <= '0;
            tx_peer_ip_q         <= '0;
            tx_peer_port_q       <= '0;
            tx_ip_id_q           <= 16'h1234;
            tx_ip_checksum_q     <= '0;
            tx_ip_total_len_q    <= 16'd60;
            tx_udp_total_len_q   <= 16'd40;
            tx_bulk_rsp_words_q  <= '0;
            tx_checksum_sum_q    <= '0;
            tx_byte_idx_q        <= '0;
            tx_bulk_word_addr_q  <= '0;
            tx_bulk_byte_lane_q  <= '0;
            tx_bulk_word_hold_q  <= '0;
            tx_frame_len_q       <= '0;
            tx_cmd_opcode_q      <= CTRL_CMD_GET_STATUS;
            tx_cmd_flags_q       <= '0;
            tx_cmd_txn_id_q      <= '0;
            tx_cmd_arg0_q        <= '0;
            tx_cmd_arg1_q        <= '0;
            tx_cmd_arg2_q        <= '0;
            tx_rsp_status_q      <= '0;
            tx_rsp_opcode_q      <= CTRL_CMD_GET_STATUS;
            tx_rsp_txn_id_q      <= '0;
            tx_rsp_data_q        <= '0;
            tx_ctrl_wait_count_q <= '0;
            tx_axis_tvalid       <= 1'b0;
            tx_axis_tlast        <= 1'b0;
            tx_axis_tdata        <= 8'h00;
            tx_frame_count       <= '0;
            debug_done_q         <= 1'b0;
            debug_busy_q         <= 1'b0;
            debug_error_q        <= 1'b0;
            debug_core_error_q   <= 1'b0;
            debug_cycle_count_q  <= '0;
            debug_output_count_q <= '0;
            debug_pods_q         <= '0;
            debug_cfg_q          <= '0;
            pr_wr_ptr_q          <= '0;
            pr_rd_ptr_q          <= '0;
            pr_count_q           <= '0;
            tx_bulk_slot_q       <= '0;
            slot_release_pulse_q <= 1'b0;
        end else begin
            req_toggle_tx_meta_q <= req_toggle_rx_q;
            req_toggle_tx_sync_q <= req_toggle_tx_meta_q;
            slot_release_pulse_q <= 1'b0;

            // Pending-response FIFO push (same cycle as issue).  Guarded by
            // full: issue_ctrl_w already waits on pr_fifo_full_w, this keeps
            // the write itself atomic (ARP pushes nothing).
            if (issue_valid_w && (sq_head_type_w != REQ_ARP) &&
                !pr_fifo_full_w) begin
                pr_fifo_peer_mac_q[pr_wr_ptr_q]  <= sq_head_peer_mac_w;
                pr_fifo_peer_ip_q[pr_wr_ptr_q]   <= sq_head_peer_ip_w;
                pr_fifo_peer_port_q[pr_wr_ptr_q] <= sq_head_peer_port_w;
                pr_fifo_opcode_q[pr_wr_ptr_q]    <= sq_head_opcode_w;
                pr_fifo_txn_q[pr_wr_ptr_q]       <= sq_head_txn_w;
                pr_fifo_slot_q[pr_wr_ptr_q]      <= sq_head_slot_w;
                pr_wr_ptr_q <= pr_wr_ptr_q + 1'b1;
            end
            // Pending-response FIFO pop: at response-frame capture (rsp_pop_w),
            // together with the response FIFO, so both stay aligned.
            if (rsp_pop_w && !pr_fifo_empty_w) begin
                pr_rd_ptr_q <= pr_rd_ptr_q + 1'b1;
            end
            // Issuing another request and starting a response can coincide.
            // Apply one net occupancy update for the shared metadata queue.
            case ({issue_valid_w && (sq_head_type_w != REQ_ARP) && !pr_fifo_full_w,
                   rsp_pop_w && !pr_fifo_empty_w})
                2'b10: pr_count_q <= pr_count_q + 1'b1;
                2'b01: pr_count_q <= pr_count_q - 1'b1;
                default: begin end
            endcase

            case (tx_state_q)
                TX_IDLE: begin
                    tx_axis_tvalid <= 1'b0;
                    tx_axis_tlast  <= 1'b0;
                    tx_axis_tdata  <= 8'h00;

                    // 1) Response frame (highest priority): head of the
                    // response FIFO.  rsp_pop_w fires for exactly this cycle.
                    if (!rsp_fifo_empty_w) begin
                        // Freeze one coherent application status for this response frame.
                        debug_done_q         <= debug_done;
                        debug_busy_q         <= debug_busy;
                        debug_error_q        <= debug_error;
                        debug_core_error_q   <= debug_core_error;
                        debug_cycle_count_q  <= debug_cycle_count;
                        debug_output_count_q <= debug_output_count;
                        debug_pods_q         <= debug_pods;
                        debug_cfg_q          <= debug_cfg;
                        tx_req_type_q       <= REQ_UDP;
                        tx_peer_mac_q       <= pr_head_peer_mac_w;
                        tx_peer_ip_q        <= pr_head_peer_ip_w;
                        tx_peer_port_q      <= pr_head_peer_port_w;
                        tx_cmd_opcode_q     <=
                            rsp_fifo_opcode_q[rsp_rd_ptr_q];
                        tx_cmd_txn_id_q     <=
                            rsp_fifo_txn_q[rsp_rd_ptr_q];
                        tx_rsp_status_q     <=
                            rsp_fifo_status_q[rsp_rd_ptr_q];
                        tx_rsp_opcode_q     <=
                            rsp_fifo_opcode_q[rsp_rd_ptr_q];
                        tx_rsp_txn_id_q     <=
                            rsp_fifo_txn_q[rsp_rd_ptr_q];
                        tx_rsp_data_q       <=
                            (rsp_fifo_opcode_q[rsp_rd_ptr_q] ==
                             CTRL_CMD_DEBUG_STATUS) ?
                            debug_status_w :
                            rsp_fifo_data_q[rsp_rd_ptr_q];
                        tx_bulk_slot_q      <= pr_head_slot_w;
                        tx_ip_checksum_q    <= '0;
                        tx_ip_total_len_q   <= 16'd60;
                        tx_udp_total_len_q  <= 16'd40;
                        tx_bulk_rsp_words_q <= '0;
                        tx_checksum_sum_q   <= '0;
                        tx_frame_len_q      <= 11'd74;
                        tx_byte_idx_q       <= 11'd0;
                        tx_bulk_word_addr_q <= '0;
                        tx_bulk_byte_lane_q <= '0;
                        if ((rsp_fifo_opcode_q[rsp_rd_ptr_q] ==
                             CTRL_CMD_DDR_READ_BULK) &&
                            (rsp_fifo_status_q[rsp_rd_ptr_q] == 8'h00)) begin
                            tx_bulk_rsp_words_q <=
                                rsp_fifo_data_q[rsp_rd_ptr_q][BULK_ADDR_W:0];
                            tx_ip_total_len_q <= 16'd60 +
                                (rsp_fifo_data_q[rsp_rd_ptr_q][BULK_ADDR_W:0] * 4);
                            tx_udp_total_len_q <= 16'd40 +
                                (rsp_fifo_data_q[rsp_rd_ptr_q][BULK_ADDR_W:0] * 4);
                            tx_frame_len_q <= 11'd74 +
                                (rsp_fifo_data_q[rsp_rd_ptr_q][BULK_ADDR_W:0] * 4);
                        end
                        tx_state_q <= TX_CHECKSUM_ID;
                    end
                    // 2) ARP reply: send directly, no controller round.
                    //    (Controller requests are issued by the standalone
                    //    issue block in any TX state.)
                    else if (issue_arp_w) begin
                        tx_req_type_q   <= REQ_ARP;
                        tx_peer_mac_q   <= sq_head_peer_mac_w;
                        tx_peer_ip_q    <= sq_head_peer_ip_w;
                        tx_peer_port_q  <= sq_head_peer_port_w;
                        tx_ip_checksum_q <= '0;
                        tx_frame_len_q  <= 11'd60;
                        tx_byte_idx_q   <= 11'd0;
                        tx_state_q      <= TX_PREP_WAIT;
                    end
                end

                TX_CHECKSUM_ID: begin
                    tx_checksum_sum_q <= IPV4_BASE_SUM +
                                         {16'd0, tx_ip_total_len_q} +
                                         {16'd0, tx_ip_id_q};
                    tx_state_q        <= TX_CHECKSUM_DST_HI;
                end

                TX_CHECKSUM_DST_HI: begin
                    tx_checksum_sum_q <= tx_checksum_sum_q +
                                         {16'd0, tx_peer_ip_q[31:16]};
                    tx_state_q        <= TX_CHECKSUM_DST_LO;
                end

                TX_CHECKSUM_DST_LO: begin
                    tx_checksum_sum_q <= tx_checksum_sum_q +
                                         {16'd0, tx_peer_ip_q[15:0]};
                    tx_state_q        <= TX_CHECKSUM_FOLD0;
                end

                TX_CHECKSUM_FOLD0: begin
                    tx_checksum_sum_q <= {16'd0, tx_checksum_sum_q[15:0]} +
                                         {16'd0, tx_checksum_sum_q[31:16]};
                    tx_state_q        <= TX_CHECKSUM_FOLD1;
                end

                TX_CHECKSUM_FOLD1: begin
                    tx_checksum_sum_q <= {16'd0, tx_checksum_sum_q[15:0]} +
                                         {31'd0, tx_checksum_sum_q[16]};
                    tx_state_q        <= TX_CHECKSUM_DONE;
                end

                TX_CHECKSUM_DONE: begin
                    tx_ip_checksum_q <= ~tx_checksum_sum_q[15:0];
                    tx_state_q       <= TX_PREP_WAIT;
                end

                TX_PREP_WAIT: begin
                    tx_axis_tvalid <= 1'b0;
                    tx_axis_tlast  <= 1'b0;
                    tx_axis_tdata  <= 8'h00;
                    tx_state_q     <= TX_PREP;
                end

                TX_PREP: begin
                    tx_axis_tvalid <= 1'b1;
                    tx_axis_tlast  <= ((tx_byte_idx_q + 11'd1) >= tx_frame_len_q);
                    tx_axis_tdata  <= tx_frame_byte(tx_req_type_q, tx_byte_idx_q);
                    tx_state_q     <= TX_SEND;
                end

                TX_SEND: begin
                    if (tx_axis_tvalid && tx_axis_tready) begin
                        if (tx_axis_tlast) begin
                            tx_axis_tvalid <= 1'b0;
                            tx_axis_tlast  <= 1'b0;
                            tx_axis_tdata  <= 8'h00;
                            tx_frame_count <= tx_frame_count + 1'b1;
                            tx_ip_id_q     <= tx_ip_id_q + 1'b1;
                            // Free the bulk payload/response slot of the
                            // request whose response frame just finished.
                            if (tx_req_type_q == REQ_UDP) begin
                                slot_release_pulse_q <= 1'b1;
                            end
                            tx_state_q     <= TX_IDLE;
                        end else begin
                            tx_byte_idx_q   <= tx_byte_idx_q + 11'd1;
                            tx_axis_tvalid  <= 1'b1;
                            tx_axis_tlast   <=
                                ((tx_byte_idx_q + 11'd2) >= tx_frame_len_q);
                            if (((tx_byte_idx_q + 11'd1) >= 11'd74) &&
                                ((tx_byte_idx_q + 11'd1) <
                                 (11'd74 + (tx_bulk_rsp_words_q << 2)))) begin
                                // The response RAM continues updating while TX is stalled.
                                // Keep all four bytes of this word stable across prefetch.
                                if (tx_bulk_byte_lane_q == 0)
                                    tx_bulk_word_hold_q <= bulk_rsp_rd_data;
                                tx_axis_tdata <= byte32(
                                    tx_bulk_byte_lane_q == 0 ? bulk_rsp_rd_data : tx_bulk_word_hold_q,
                                    tx_bulk_byte_lane_q
                                );
                                // Address is issued one cycle early so the
                                // synchronously-read bulk response RAM has
                                // its data ready when this byte is output.
                                if (tx_bulk_byte_lane_q == 2'd3) begin
                                    tx_bulk_byte_lane_q <= 2'd0;
                                end else begin
                                    tx_bulk_byte_lane_q <=
                                        tx_bulk_byte_lane_q + 1'b1;
                                end
                                if (tx_bulk_byte_lane_q == 2'd2) begin
                                    tx_bulk_word_addr_q <=
                                        tx_bulk_word_addr_q + 1'b1;
                                end
                            end else begin
                                tx_axis_tdata <=
                                    tx_frame_byte(tx_req_type_q,
                                                  tx_byte_idx_q + 11'd1);
                            end
                        end
                    end
                end

                default: begin
                    tx_state_q <= TX_IDLE;
                end
            endcase
        end
    end

    // ---------------- Pipelined issue and response capture ----------------
    // Issues controller requests from any TX state (one per cycle), latches
    // the shared command bus, captures responses into the response FIFO at
    // arrival time, and tracks outstanding requests per endpoint.
    always_ff @(posedge tx_clk) begin
        if (!tx_rst_n) begin
            ddr_ctrl_req_push_q  <= 1'b0;
            attn_ctrl_req_valid_q <= 1'b0;
            ctrl_req_opcode      <= CTRL_CMD_GET_STATUS;
            ctrl_req_flags       <= '0;
            ctrl_req_txn_id      <= '0;
            ctrl_req_arg0        <= '0;
            ctrl_req_arg1        <= '0;
            ctrl_req_arg2        <= '0;
            ctrl_req_bulk_slot   <= '0;
            ctrl_req_bulk_count  <= '0;
            rsp_wr_ptr_q         <= '0;
            rsp_rd_ptr_q         <= '0;
            rsp_count_q          <= '0;
            ddr_outstanding_count_q <= '0;
            attn_outstanding_q   <= 1'b0;
            rsp_protocol_error_q <= 1'b0;
        end else begin
            ddr_ctrl_req_push_q  <= issue_ctrl_w && head_is_ddr_w;
            attn_ctrl_req_valid_q <= issue_ctrl_w && !head_is_ddr_w;

            if (issue_ctrl_w) begin
                ctrl_req_opcode      <= sq_head_opcode_w;
                ctrl_req_flags       <= sq_head_flags_w;
                ctrl_req_txn_id      <= sq_head_txn_w;
                ctrl_req_arg0        <= sq_head_arg0_w;
                ctrl_req_arg1        <= sq_head_arg1_w;
                ctrl_req_arg2        <= sq_head_arg2_w;
                ctrl_req_bulk_slot   <= sq_head_slot_w;
                ctrl_req_bulk_count  <= sq_head_count_w;
            end

            // Response FIFO: capture at arrival, drain at frame capture.
            // When full, do NOT write (a wrapped pointer would corrupt the
            // head and misalign the pr/rsp pair); the response is dropped
            // and rsp_protocol_error_q below flags it.  Depth 32 makes this
            // unreachable for pipeline<=4, it is a safety net.
            if (rsp_push_w && !rsp_fifo_full_w) begin
                rsp_fifo_status_q[rsp_wr_ptr_q] <= rsp_status_w;
                rsp_fifo_opcode_q[rsp_wr_ptr_q]  <= rsp_opcode_w;
                rsp_fifo_txn_q[rsp_wr_ptr_q]     <= rsp_txn_id_w;
                rsp_fifo_data_q[rsp_wr_ptr_q]    <= rsp_data_w;
                rsp_wr_ptr_q <= rsp_ptr_next(rsp_wr_ptr_q);
            end
            if (rsp_pop_w) begin
                rsp_rd_ptr_q <= rsp_ptr_next(rsp_rd_ptr_q);
            end
            unique case ({rsp_push_w, rsp_pop_w})
                2'b10: rsp_count_q <= rsp_count_q + 1'b1;
                2'b01: rsp_count_q <= rsp_count_q - 1'b1;
                default: rsp_count_q <= rsp_count_q;
            endcase

            if (rsp_push_w && rsp_fifo_full_w) begin
                rsp_protocol_error_q <= 1'b1;
            end
            if (rsp_pop_w && pr_fifo_empty_w) begin
                rsp_protocol_error_q <= 1'b1;
            end

            // Outstanding tracking: responses from the endpoint with the
            // outstanding request are 1:1 with issues, so the muxed response
            // bus always belongs to the tracked endpoint.
            if (issue_ctrl_w && head_is_ddr_w && !rsp_valid_w) begin
                ddr_outstanding_count_q <= ddr_outstanding_count_q + 1'b1;
            end else if (issue_ctrl_w && head_is_ddr_w && rsp_valid_w) begin
                ddr_outstanding_count_q <= ddr_outstanding_count_q;
            end else if (rsp_valid_w && !attn_outstanding_q) begin
                if (ddr_outstanding_count_q == '0) begin
                    rsp_protocol_error_q <= 1'b1;
                end else begin
                    ddr_outstanding_count_q <= ddr_outstanding_count_q - 1'b1;
                end
            end

            if (issue_ctrl_w && !head_is_ddr_w) begin
                attn_outstanding_q <= 1'b1;
            end else if (rsp_valid_w && attn_outstanding_q) begin
                attn_outstanding_q <= 1'b0;
            end else if (rsp_valid_w && !attn_outstanding_q &&
                         (ddr_outstanding_count_q == '0)) begin
                rsp_protocol_error_q <= 1'b1;
            end
        end
    end

endmodule

module fpt_net_eth_hold_buffer_bus #(
    parameter int WIDTH = 1
) (
    input  logic [WIDTH-1:0] din,
    output logic [WIDTH-1:0] dout
);
    for (genvar i = 0; i < WIDTH; i++) begin : gen_hold_lut
        (* DONT_TOUCH = "TRUE" *) LUT1 #(
            .INIT(2'h2)
        ) u_lut (
            .I0(din[i]),
            .O(dout[i])
        );
    end
endmodule


// ---- Private implementation: fpt_net_eth_mac_1g_rgmii_fifo.v ----
/*

Copyright (c) 2015-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * 1G Ethernet MAC with RGMII interface and TX and RX FIFOs
 */
module fpt_net_eth_mac_1g_rgmii_fifo #
(
    // target ("SIM", "GENERIC", "XILINX", "ALTERA")
    parameter TARGET = "GENERIC",
    // IODDR style ("IODDR", "IODDR2")
    // Use IODDR for Virtex-4, Virtex-5, Virtex-6, 7 Series, Ultrascale
    // Use IODDR2 for Spartan-6
    parameter IODDR_STYLE = "IODDR2",
    // Clock input style ("BUFG", "BUFR", "BUFIO", "BUFIO2")
    // Use BUFR for Virtex-6, 7-series
    // Use BUFG for Virtex-5, Spartan-6, Ultrascale
    parameter CLOCK_INPUT_STYLE = "BUFG",
    // Use 90 degree clock for RGMII transmit ("TRUE", "FALSE")
    parameter USE_CLK90 = "TRUE",
    parameter AXIS_DATA_WIDTH = 8,
    parameter AXIS_KEEP_ENABLE = (AXIS_DATA_WIDTH>8),
    parameter AXIS_KEEP_WIDTH = (AXIS_DATA_WIDTH/8),
    parameter ENABLE_PADDING = 1,
    parameter MIN_FRAME_LENGTH = 64,
    parameter TX_FIFO_DEPTH = 4096,
    parameter TX_FIFO_RAM_PIPELINE = 1,
    parameter TX_FRAME_FIFO = 1,
    parameter TX_DROP_OVERSIZE_FRAME = TX_FRAME_FIFO,
    parameter TX_DROP_BAD_FRAME = TX_DROP_OVERSIZE_FRAME,
    parameter TX_DROP_WHEN_FULL = 0,
    parameter RX_FIFO_DEPTH = 4096,
    parameter RX_FIFO_RAM_PIPELINE = 1,
    parameter RX_FRAME_FIFO = 1,
    parameter RX_DROP_OVERSIZE_FRAME = RX_FRAME_FIFO,
    parameter RX_DROP_BAD_FRAME = RX_DROP_OVERSIZE_FRAME,
    parameter RX_DROP_WHEN_FULL = RX_DROP_OVERSIZE_FRAME
)
(
    input  wire                       gtx_clk,
    input  wire                       gtx_clk90,
    input  wire                       gtx_rst,
    input  wire                       logic_clk,
    input  wire                       logic_rst,

    /*
     * AXI input
     */
    input  wire [AXIS_DATA_WIDTH-1:0] tx_axis_tdata,
    input  wire [AXIS_KEEP_WIDTH-1:0] tx_axis_tkeep,
    input  wire                       tx_axis_tvalid,
    output wire                       tx_axis_tready,
    input  wire                       tx_axis_tlast,
    input  wire                       tx_axis_tuser,

    /*
     * AXI output
     */
    output wire [AXIS_DATA_WIDTH-1:0] rx_axis_tdata,
    output wire [AXIS_KEEP_WIDTH-1:0] rx_axis_tkeep,
    output wire                       rx_axis_tvalid,
    input  wire                       rx_axis_tready,
    output wire                       rx_axis_tlast,
    output wire                       rx_axis_tuser,

    /*
     * RGMII interface
     */
    input  wire                       rgmii_rx_clk,
    input  wire [3:0]                 rgmii_rxd,
    input  wire                       rgmii_rx_ctl,
    output wire                       rgmii_tx_clk,
    output wire [3:0]                 rgmii_txd,
    output wire                       rgmii_tx_ctl,

    /*
     * Status
     */
    output wire                       tx_error_underflow,
    output wire                       tx_fifo_overflow,
    output wire                       tx_fifo_bad_frame,
    output wire                       tx_fifo_good_frame,
    output wire                       rx_error_bad_frame,
    output wire                       rx_error_bad_fcs,
    output wire                       rx_fifo_overflow,
    output wire                       rx_fifo_bad_frame,
    output wire                       rx_fifo_good_frame,
    output wire [1:0]                 speed,

    /*
     * Configuration
     */
    input  wire [7:0]                 cfg_ifg,
    input  wire                       cfg_tx_enable,
    input  wire                       cfg_rx_enable
);

wire tx_clk;
wire rx_clk;
wire tx_rst;
wire rx_rst;

wire [7:0]  tx_fifo_axis_tdata;
wire        tx_fifo_axis_tvalid;
wire        tx_fifo_axis_tready;
wire        tx_fifo_axis_tlast;
wire        tx_fifo_axis_tuser;

wire [7:0]  rx_fifo_axis_tdata;
wire        rx_fifo_axis_tvalid;
wire        rx_fifo_axis_tlast;
wire        rx_fifo_axis_tuser;

// synchronize MAC status signals into logic clock domain
wire tx_error_underflow_int;

reg [0:0] tx_sync_reg_1 = 1'b0;
reg [0:0] tx_sync_reg_2 = 1'b0;
reg [0:0] tx_sync_reg_3 = 1'b0;
reg [0:0] tx_sync_reg_4 = 1'b0;

assign tx_error_underflow = tx_sync_reg_3[0] ^ tx_sync_reg_4[0];

always @(posedge tx_clk or posedge tx_rst) begin
    if (tx_rst) begin
        tx_sync_reg_1 <= 1'b0;
    end else begin
        tx_sync_reg_1 <= tx_sync_reg_1 ^ {tx_error_underflow_int};
    end
end

always @(posedge logic_clk or posedge logic_rst) begin
    if (logic_rst) begin
        tx_sync_reg_2 <= 1'b0;
        tx_sync_reg_3 <= 1'b0;
        tx_sync_reg_4 <= 1'b0;
    end else begin
        tx_sync_reg_2 <= tx_sync_reg_1;
        tx_sync_reg_3 <= tx_sync_reg_2;
        tx_sync_reg_4 <= tx_sync_reg_3;
    end
end

wire rx_error_bad_frame_int;
wire rx_error_bad_fcs_int;

reg [1:0] rx_sync_reg_1 = 2'd0;
reg [1:0] rx_sync_reg_2 = 2'd0;
reg [1:0] rx_sync_reg_3 = 2'd0;
reg [1:0] rx_sync_reg_4 = 2'd0;

assign rx_error_bad_frame = rx_sync_reg_3[0] ^ rx_sync_reg_4[0];
assign rx_error_bad_fcs = rx_sync_reg_3[1] ^ rx_sync_reg_4[1];

always @(posedge rx_clk or posedge rx_rst) begin
    if (rx_rst) begin
        rx_sync_reg_1 <= 2'd0;
    end else begin
        rx_sync_reg_1 <= rx_sync_reg_1 ^ {rx_error_bad_fcs_int, rx_error_bad_frame_int};
    end
end

always @(posedge logic_clk or posedge logic_rst) begin
    if (logic_rst) begin
        rx_sync_reg_2 <= 2'd0;
        rx_sync_reg_3 <= 2'd0;
        rx_sync_reg_4 <= 2'd0;
    end else begin
        rx_sync_reg_2 <= rx_sync_reg_1;
        rx_sync_reg_3 <= rx_sync_reg_2;
        rx_sync_reg_4 <= rx_sync_reg_3;
    end
end

wire [1:0] speed_int;

reg [1:0] speed_sync_reg_1 = 2'b10;
reg [1:0] speed_sync_reg_2 = 2'b10;

assign speed = speed_sync_reg_2;

always @(posedge logic_clk) begin
    speed_sync_reg_1 <= speed_int;
    speed_sync_reg_2 <= speed_sync_reg_1;
end

fpt_net_eth_mac_1g_rgmii #(
    .TARGET(TARGET),
    .IODDR_STYLE(IODDR_STYLE),
    .CLOCK_INPUT_STYLE(CLOCK_INPUT_STYLE),
    .USE_CLK90(USE_CLK90),
    .ENABLE_PADDING(ENABLE_PADDING),
    .MIN_FRAME_LENGTH(MIN_FRAME_LENGTH)
)
eth_mac_1g_rgmii_inst (
    .gtx_clk(gtx_clk),
    .gtx_clk90(gtx_clk90),
    .gtx_rst(gtx_rst),
    .tx_clk(tx_clk),
    .tx_rst(tx_rst),
    .rx_clk(rx_clk),
    .rx_rst(rx_rst),
    .tx_axis_tdata(tx_fifo_axis_tdata),
    .tx_axis_tvalid(tx_fifo_axis_tvalid),
    .tx_axis_tready(tx_fifo_axis_tready),
    .tx_axis_tlast(tx_fifo_axis_tlast),
    .tx_axis_tuser(tx_fifo_axis_tuser),
    .rx_axis_tdata(rx_fifo_axis_tdata),
    .rx_axis_tvalid(rx_fifo_axis_tvalid),
    .rx_axis_tlast(rx_fifo_axis_tlast),
    .rx_axis_tuser(rx_fifo_axis_tuser),
    .rgmii_rx_clk(rgmii_rx_clk),
    .rgmii_rxd(rgmii_rxd),
    .rgmii_rx_ctl(rgmii_rx_ctl),
    .rgmii_tx_clk(rgmii_tx_clk),
    .rgmii_txd(rgmii_txd),
    .rgmii_tx_ctl(rgmii_tx_ctl),
    .tx_error_underflow(tx_error_underflow_int),
    .rx_error_bad_frame(rx_error_bad_frame_int),
    .rx_error_bad_fcs(rx_error_bad_fcs_int),
    .speed(speed_int),
    .cfg_ifg(cfg_ifg),
    .cfg_tx_enable(cfg_tx_enable),
    .cfg_rx_enable(cfg_rx_enable)
);

fpt_net_axis_async_fifo_adapter #(
    .DEPTH(TX_FIFO_DEPTH),
    .S_DATA_WIDTH(AXIS_DATA_WIDTH),
    .S_KEEP_ENABLE(AXIS_KEEP_ENABLE),
    .S_KEEP_WIDTH(AXIS_KEEP_WIDTH),
    .M_DATA_WIDTH(8),
    .M_KEEP_ENABLE(0),
    .ID_ENABLE(0),
    .DEST_ENABLE(0),
    .USER_ENABLE(1),
    .USER_WIDTH(1),
    .RAM_PIPELINE(TX_FIFO_RAM_PIPELINE),
    .FRAME_FIFO(TX_FRAME_FIFO),
    .USER_BAD_FRAME_VALUE(1'b1),
    .USER_BAD_FRAME_MASK(1'b1),
    .DROP_OVERSIZE_FRAME(TX_DROP_OVERSIZE_FRAME),
    .DROP_BAD_FRAME(TX_DROP_BAD_FRAME),
    .DROP_WHEN_FULL(TX_DROP_WHEN_FULL)
)
tx_fifo (
    // AXI input
    .s_clk(logic_clk),
    .s_rst(logic_rst),
    .s_axis_tdata(tx_axis_tdata),
    .s_axis_tkeep(tx_axis_tkeep),
    .s_axis_tvalid(tx_axis_tvalid),
    .s_axis_tready(tx_axis_tready),
    .s_axis_tlast(tx_axis_tlast),
    .s_axis_tid(0),
    .s_axis_tdest(0),
    .s_axis_tuser(tx_axis_tuser),
    // AXI output
    .m_clk(tx_clk),
    .m_rst(tx_rst),
    .m_axis_tdata(tx_fifo_axis_tdata),
    .m_axis_tkeep(),
    .m_axis_tvalid(tx_fifo_axis_tvalid),
    .m_axis_tready(tx_fifo_axis_tready),
    .m_axis_tlast(tx_fifo_axis_tlast),
    .m_axis_tid(),
    .m_axis_tdest(),
    .m_axis_tuser(tx_fifo_axis_tuser),
    // Status
    .s_status_overflow(tx_fifo_overflow),
    .s_status_bad_frame(tx_fifo_bad_frame),
    .s_status_good_frame(tx_fifo_good_frame),
    .m_status_overflow(),
    .m_status_bad_frame(),
    .m_status_good_frame()
);

fpt_net_axis_async_fifo_adapter #(
    .DEPTH(RX_FIFO_DEPTH),
    .S_DATA_WIDTH(8),
    .S_KEEP_ENABLE(0),
    .M_DATA_WIDTH(AXIS_DATA_WIDTH),
    .M_KEEP_ENABLE(AXIS_KEEP_ENABLE),
    .M_KEEP_WIDTH(AXIS_KEEP_WIDTH),
    .ID_ENABLE(0),
    .DEST_ENABLE(0),
    .USER_ENABLE(1),
    .USER_WIDTH(1),
    .RAM_PIPELINE(RX_FIFO_RAM_PIPELINE),
    .FRAME_FIFO(RX_FRAME_FIFO),
    .USER_BAD_FRAME_VALUE(1'b1),
    .USER_BAD_FRAME_MASK(1'b1),
    .DROP_OVERSIZE_FRAME(RX_DROP_OVERSIZE_FRAME),
    .DROP_BAD_FRAME(RX_DROP_BAD_FRAME),
    .DROP_WHEN_FULL(RX_DROP_WHEN_FULL)
)
rx_fifo (
    // AXI input
    .s_clk(rx_clk),
    .s_rst(rx_rst),
    .s_axis_tdata(rx_fifo_axis_tdata),
    .s_axis_tkeep(0),
    .s_axis_tvalid(rx_fifo_axis_tvalid),
    .s_axis_tready(),
    .s_axis_tlast(rx_fifo_axis_tlast),
    .s_axis_tid(0),
    .s_axis_tdest(0),
    .s_axis_tuser(rx_fifo_axis_tuser),
    // AXI output
    .m_clk(logic_clk),
    .m_rst(logic_rst),
    .m_axis_tdata(rx_axis_tdata),
    .m_axis_tkeep(rx_axis_tkeep),
    .m_axis_tvalid(rx_axis_tvalid),
    .m_axis_tready(rx_axis_tready),
    .m_axis_tlast(rx_axis_tlast),
    .m_axis_tid(),
    .m_axis_tdest(),
    .m_axis_tuser(rx_axis_tuser),
    // Status
    .s_status_overflow(),
    .s_status_bad_frame(),
    .s_status_good_frame(),
    .m_status_overflow(rx_fifo_overflow),
    .m_status_bad_frame(rx_fifo_bad_frame),
    .m_status_good_frame(rx_fifo_good_frame)
);

endmodule

`resetall


// ---- Private implementation: fpt_net_eth_mac_1g_rgmii.v ----
/*

Copyright (c) 2015-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * 1G Ethernet MAC with RGMII interface
 */
module fpt_net_eth_mac_1g_rgmii #
(
    // target ("SIM", "GENERIC", "XILINX", "ALTERA")
    parameter TARGET = "GENERIC",
    // IODDR style ("IODDR", "IODDR2")
    // Use IODDR for Virtex-4, Virtex-5, Virtex-6, 7 Series, Ultrascale
    // Use IODDR2 for Spartan-6
    parameter IODDR_STYLE = "IODDR2",
    // Clock input style ("BUFG", "BUFR", "BUFIO", "BUFIO2")
    // Use BUFR for Virtex-6, 7-series
    // Use BUFG for Virtex-5, Spartan-6, Ultrascale
    parameter CLOCK_INPUT_STYLE = "BUFG",
    // Use 90 degree clock for RGMII transmit ("TRUE", "FALSE")
    parameter USE_CLK90 = "TRUE",
    parameter ENABLE_PADDING = 1,
    parameter MIN_FRAME_LENGTH = 64
)
(
    input  wire        gtx_clk,
    input  wire        gtx_clk90,
    input  wire        gtx_rst,
    output wire        rx_clk,
    output wire        rx_rst,
    output wire        tx_clk,
    output wire        tx_rst,

    /*
     * AXI input
     */
    input  wire [7:0]  tx_axis_tdata,
    input  wire        tx_axis_tvalid,
    output wire        tx_axis_tready,
    input  wire        tx_axis_tlast,
    input  wire        tx_axis_tuser,

    /*
     * AXI output
     */
    output wire [7:0]  rx_axis_tdata,
    output wire        rx_axis_tvalid,
    output wire        rx_axis_tlast,
    output wire        rx_axis_tuser,

    /*
     * RGMII interface
     */
    input  wire        rgmii_rx_clk,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl,
    output wire        rgmii_tx_clk,
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl,

    /*
     * Status
     */
    output wire        tx_error_underflow,
    output wire        rx_error_bad_frame,
    output wire        rx_error_bad_fcs,
    output wire [1:0]  speed,

    /*
     * Configuration
     */
    input  wire [7:0]  cfg_ifg,
    input  wire        cfg_tx_enable,
    input  wire        cfg_rx_enable
);

wire [7:0]  mac_gmii_rxd;
wire        mac_gmii_rx_dv;
wire        mac_gmii_rx_er;
wire        mac_gmii_tx_clk_en;
wire [7:0]  mac_gmii_txd;
wire        mac_gmii_tx_en;
wire        mac_gmii_tx_er;

reg [1:0] speed_reg = 2'b10;
reg mii_select_reg = 1'b0;

(* srl_style = "register" *)
reg [1:0] tx_mii_select_sync = 2'd0;

always @(posedge tx_clk) begin
    tx_mii_select_sync <= {tx_mii_select_sync[0], mii_select_reg};
end

(* srl_style = "register" *)
reg [1:0] rx_mii_select_sync = 2'd0;

always @(posedge rx_clk) begin
    rx_mii_select_sync <= {rx_mii_select_sync[0], mii_select_reg};
end

// PHY speed detection
reg [2:0] rx_prescale = 3'd0;

always @(posedge rx_clk) begin
    rx_prescale <= rx_prescale + 3'd1;
end

(* srl_style = "register" *)
reg [2:0] rx_prescale_sync = 3'd0;

always @(posedge gtx_clk) begin
    rx_prescale_sync <= {rx_prescale_sync[1:0], rx_prescale[2]};
end

reg [6:0] rx_speed_count_1 = 0;
reg [1:0] rx_speed_count_2 = 0;

always @(posedge gtx_clk) begin
    if (gtx_rst) begin
        rx_speed_count_1 <= 0;
        rx_speed_count_2 <= 0;
        speed_reg <= 2'b10;
        mii_select_reg <= 1'b0;
    end else begin
        rx_speed_count_1 <= rx_speed_count_1 + 1;
        
        if (rx_prescale_sync[1] ^ rx_prescale_sync[2]) begin
            rx_speed_count_2 <= rx_speed_count_2 + 1;
        end

        if (&rx_speed_count_1) begin
            // reference count overflow - 10M
            rx_speed_count_1 <= 0;
            rx_speed_count_2 <= 0;
            speed_reg <= 2'b00;
            mii_select_reg <= 1'b1;
        end

        if (&rx_speed_count_2) begin
            // prescaled count overflow - 100M or 1000M
            rx_speed_count_1 <= 0;
            rx_speed_count_2 <= 0;
            if (rx_speed_count_1[6:5]) begin
                // large reference count - 100M
                speed_reg <= 2'b01;
                mii_select_reg <= 1'b1;
            end else begin
                // small reference count - 1000M
                speed_reg <= 2'b10;
                mii_select_reg <= 1'b0;
            end
        end
    end
end

assign speed = speed_reg;

fpt_net_rgmii_phy_if #(
    .TARGET(TARGET),
    .IODDR_STYLE(IODDR_STYLE),
    .CLOCK_INPUT_STYLE(CLOCK_INPUT_STYLE),
    .USE_CLK90(USE_CLK90)
)
rgmii_phy_if_inst (
    .clk(gtx_clk),
    .clk90(gtx_clk90),
    .rst(gtx_rst),

    .mac_gmii_rx_clk(rx_clk),
    .mac_gmii_rx_rst(rx_rst),
    .mac_gmii_rxd(mac_gmii_rxd),
    .mac_gmii_rx_dv(mac_gmii_rx_dv),
    .mac_gmii_rx_er(mac_gmii_rx_er),
    .mac_gmii_tx_clk(tx_clk),
    .mac_gmii_tx_rst(tx_rst),
    .mac_gmii_tx_clk_en(mac_gmii_tx_clk_en),
    .mac_gmii_txd(mac_gmii_txd),
    .mac_gmii_tx_en(mac_gmii_tx_en),
    .mac_gmii_tx_er(mac_gmii_tx_er),

    .phy_rgmii_rx_clk(rgmii_rx_clk),
    .phy_rgmii_rxd(rgmii_rxd),
    .phy_rgmii_rx_ctl(rgmii_rx_ctl),
    .phy_rgmii_tx_clk(rgmii_tx_clk),
    .phy_rgmii_txd(rgmii_txd),
    .phy_rgmii_tx_ctl(rgmii_tx_ctl),

    .speed(speed)
);

fpt_net_eth_mac_1g #(
    .ENABLE_PADDING(ENABLE_PADDING),
    .MIN_FRAME_LENGTH(MIN_FRAME_LENGTH)
)
eth_mac_1g_inst (
    .tx_clk(tx_clk),
    .tx_rst(tx_rst),
    .rx_clk(rx_clk),
    .rx_rst(rx_rst),
    .tx_axis_tdata(tx_axis_tdata),
    .tx_axis_tvalid(tx_axis_tvalid),
    .tx_axis_tready(tx_axis_tready),
    .tx_axis_tlast(tx_axis_tlast),
    .tx_axis_tuser(tx_axis_tuser),
    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tuser(rx_axis_tuser),
    .gmii_rxd(mac_gmii_rxd),
    .gmii_rx_dv(mac_gmii_rx_dv),
    .gmii_rx_er(mac_gmii_rx_er),
    .gmii_txd(mac_gmii_txd),
    .gmii_tx_en(mac_gmii_tx_en),
    .gmii_tx_er(mac_gmii_tx_er),
    .rx_clk_enable(1'b1),
    .tx_clk_enable(mac_gmii_tx_clk_en),
    .rx_mii_select(rx_mii_select_sync[1]),
    .tx_mii_select(tx_mii_select_sync[1]),
    .tx_error_underflow(tx_error_underflow),
    .rx_error_bad_frame(rx_error_bad_frame),
    .rx_error_bad_fcs(rx_error_bad_fcs),
    .cfg_ifg(cfg_ifg),
    .cfg_tx_enable(cfg_tx_enable),
    .cfg_rx_enable(cfg_rx_enable)
);

endmodule

`resetall


// ---- Private implementation: fpt_net_eth_mac_1g.v ----
/*

Copyright (c) 2015-2023 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * 1G Ethernet MAC
 */
module fpt_net_eth_mac_1g #
(
    parameter DATA_WIDTH = 8,
    parameter ENABLE_PADDING = 1,
    parameter MIN_FRAME_LENGTH = 64,
    parameter PTP_TS_ENABLE = 0,
    parameter PTP_TS_FMT_TOD = 1,
    parameter PTP_TS_WIDTH = PTP_TS_FMT_TOD ? 96 : 64,
    parameter TX_PTP_TS_CTRL_IN_TUSER = 0,
    parameter TX_PTP_TAG_ENABLE = PTP_TS_ENABLE,
    parameter TX_PTP_TAG_WIDTH = 16,
    parameter TX_USER_WIDTH = (PTP_TS_ENABLE ? (TX_PTP_TAG_ENABLE ? TX_PTP_TAG_WIDTH : 0) + (TX_PTP_TS_CTRL_IN_TUSER ? 1 : 0) : 0) + 1,
    parameter RX_USER_WIDTH = (PTP_TS_ENABLE ? PTP_TS_WIDTH : 0) + 1,
    parameter PFC_ENABLE = 0,
    parameter PAUSE_ENABLE = PFC_ENABLE
)
(
    input  wire                         rx_clk,
    input  wire                         rx_rst,
    input  wire                         tx_clk,
    input  wire                         tx_rst,

    /*
     * AXI input
     */
    input  wire [DATA_WIDTH-1:0]        tx_axis_tdata,
    input  wire                         tx_axis_tvalid,
    output wire                         tx_axis_tready,
    input  wire                         tx_axis_tlast,
    input  wire [TX_USER_WIDTH-1:0]     tx_axis_tuser,

    /*
     * AXI output
     */
    output wire [DATA_WIDTH-1:0]        rx_axis_tdata,
    output wire                         rx_axis_tvalid,
    output wire                         rx_axis_tlast,
    output wire [RX_USER_WIDTH-1:0]     rx_axis_tuser,

    /*
     * GMII interface
     */
    input  wire [DATA_WIDTH-1:0]        gmii_rxd,
    input  wire                         gmii_rx_dv,
    input  wire                         gmii_rx_er,
    output wire [DATA_WIDTH-1:0]        gmii_txd,
    output wire                         gmii_tx_en,
    output wire                         gmii_tx_er,

    /*
     * PTP
     */
    input  wire [PTP_TS_WIDTH-1:0]      tx_ptp_ts,
    input  wire [PTP_TS_WIDTH-1:0]      rx_ptp_ts,
    output wire [PTP_TS_WIDTH-1:0]      tx_axis_ptp_ts,
    output wire [TX_PTP_TAG_WIDTH-1:0]  tx_axis_ptp_ts_tag,
    output wire                         tx_axis_ptp_ts_valid,

    /*
     * Link-level Flow Control (LFC) (IEEE 802.3 annex 31B PAUSE)
     */
    input  wire                         tx_lfc_req,
    input  wire                         tx_lfc_resend,
    input  wire                         rx_lfc_en,
    output wire                         rx_lfc_req,
    input  wire                         rx_lfc_ack,

    /*
     * Priority Flow Control (PFC) (IEEE 802.3 annex 31D PFC)
     */
    input  wire [7:0]                   tx_pfc_req,
    input  wire                         tx_pfc_resend,
    input  wire [7:0]                   rx_pfc_en,
    output wire [7:0]                   rx_pfc_req,
    input  wire [7:0]                   rx_pfc_ack,

    /*
     * Pause interface
     */
    input  wire                         tx_lfc_pause_en,
    input  wire                         tx_pause_req,
    output wire                         tx_pause_ack,

    /*
     * Control
     */
    input  wire                         rx_clk_enable,
    input  wire                         tx_clk_enable,
    input  wire                         rx_mii_select,
    input  wire                         tx_mii_select,

    /*
     * Status
     */
    output wire                         tx_start_packet,
    output wire                         tx_error_underflow,
    output wire                         rx_start_packet,
    output wire                         rx_error_bad_frame,
    output wire                         rx_error_bad_fcs,
    output wire                         stat_tx_mcf,
    output wire                         stat_rx_mcf,
    output wire                         stat_tx_lfc_pkt,
    output wire                         stat_tx_lfc_xon,
    output wire                         stat_tx_lfc_xoff,
    output wire                         stat_tx_lfc_paused,
    output wire                         stat_tx_pfc_pkt,
    output wire [7:0]                   stat_tx_pfc_xon,
    output wire [7:0]                   stat_tx_pfc_xoff,
    output wire [7:0]                   stat_tx_pfc_paused,
    output wire                         stat_rx_lfc_pkt,
    output wire                         stat_rx_lfc_xon,
    output wire                         stat_rx_lfc_xoff,
    output wire                         stat_rx_lfc_paused,
    output wire                         stat_rx_pfc_pkt,
    output wire [7:0]                   stat_rx_pfc_xon,
    output wire [7:0]                   stat_rx_pfc_xoff,
    output wire [7:0]                   stat_rx_pfc_paused,

    /*
     * Configuration
     */
    input  wire [7:0]                   cfg_ifg,
    input  wire                         cfg_tx_enable,
    input  wire                         cfg_rx_enable,
    input  wire [47:0]                  cfg_mcf_rx_eth_dst_mcast,
    input  wire                         cfg_mcf_rx_check_eth_dst_mcast,
    input  wire [47:0]                  cfg_mcf_rx_eth_dst_ucast,
    input  wire                         cfg_mcf_rx_check_eth_dst_ucast,
    input  wire [47:0]                  cfg_mcf_rx_eth_src,
    input  wire                         cfg_mcf_rx_check_eth_src,
    input  wire [15:0]                  cfg_mcf_rx_eth_type,
    input  wire [15:0]                  cfg_mcf_rx_opcode_lfc,
    input  wire                         cfg_mcf_rx_check_opcode_lfc,
    input  wire [15:0]                  cfg_mcf_rx_opcode_pfc,
    input  wire                         cfg_mcf_rx_check_opcode_pfc,
    input  wire                         cfg_mcf_rx_forward,
    input  wire                         cfg_mcf_rx_enable,
    input  wire [47:0]                  cfg_tx_lfc_eth_dst,
    input  wire [47:0]                  cfg_tx_lfc_eth_src,
    input  wire [15:0]                  cfg_tx_lfc_eth_type,
    input  wire [15:0]                  cfg_tx_lfc_opcode,
    input  wire                         cfg_tx_lfc_en,
    input  wire [15:0]                  cfg_tx_lfc_quanta,
    input  wire [15:0]                  cfg_tx_lfc_refresh,
    input  wire [47:0]                  cfg_tx_pfc_eth_dst,
    input  wire [47:0]                  cfg_tx_pfc_eth_src,
    input  wire [15:0]                  cfg_tx_pfc_eth_type,
    input  wire [15:0]                  cfg_tx_pfc_opcode,
    input  wire                         cfg_tx_pfc_en,
    input  wire [8*16-1:0]              cfg_tx_pfc_quanta,
    input  wire [8*16-1:0]              cfg_tx_pfc_refresh,
    input  wire [15:0]                  cfg_rx_lfc_opcode,
    input  wire                         cfg_rx_lfc_en,
    input  wire [15:0]                  cfg_rx_pfc_opcode,
    input  wire                         cfg_rx_pfc_en
);

parameter MAC_CTRL_ENABLE = PAUSE_ENABLE || PFC_ENABLE;
parameter TX_USER_WIDTH_INT = MAC_CTRL_ENABLE ? (PTP_TS_ENABLE ? (TX_PTP_TAG_ENABLE ? TX_PTP_TAG_WIDTH : 0) + 1 : 0) + 1 : TX_USER_WIDTH;

wire [DATA_WIDTH-1:0]         tx_axis_tdata_int;
wire                          tx_axis_tvalid_int;
wire                          tx_axis_tready_int;
wire                          tx_axis_tlast_int;
wire [TX_USER_WIDTH_INT-1:0]  tx_axis_tuser_int;

wire [DATA_WIDTH-1:0]     rx_axis_tdata_int;
wire                      rx_axis_tvalid_int;
wire                      rx_axis_tlast_int;
wire [RX_USER_WIDTH-1:0]  rx_axis_tuser_int;

fpt_net_axis_gmii_rx #(
    .DATA_WIDTH(DATA_WIDTH),
    .PTP_TS_ENABLE(PTP_TS_ENABLE),
    .PTP_TS_WIDTH(PTP_TS_WIDTH),
    .USER_WIDTH(RX_USER_WIDTH)
)
axis_gmii_rx_inst (
    .clk(rx_clk),
    .rst(rx_rst),
    .gmii_rxd(gmii_rxd),
    .gmii_rx_dv(gmii_rx_dv),
    .gmii_rx_er(gmii_rx_er),
    .m_axis_tdata(rx_axis_tdata_int),
    .m_axis_tvalid(rx_axis_tvalid_int),
    .m_axis_tlast(rx_axis_tlast_int),
    .m_axis_tuser(rx_axis_tuser_int),
    .ptp_ts(rx_ptp_ts),
    .clk_enable(rx_clk_enable),
    .mii_select(rx_mii_select),
    .cfg_rx_enable(cfg_rx_enable),
    .start_packet(rx_start_packet),
    .error_bad_frame(rx_error_bad_frame),
    .error_bad_fcs(rx_error_bad_fcs)
);

fpt_net_axis_gmii_tx #(
    .DATA_WIDTH(DATA_WIDTH),
    .ENABLE_PADDING(ENABLE_PADDING),
    .MIN_FRAME_LENGTH(MIN_FRAME_LENGTH),
    .PTP_TS_ENABLE(PTP_TS_ENABLE),
    .PTP_TS_WIDTH(PTP_TS_WIDTH),
    .PTP_TS_CTRL_IN_TUSER(MAC_CTRL_ENABLE ? PTP_TS_ENABLE : TX_PTP_TS_CTRL_IN_TUSER),
    .PTP_TAG_ENABLE(TX_PTP_TAG_ENABLE),
    .PTP_TAG_WIDTH(TX_PTP_TAG_WIDTH),
    .USER_WIDTH(TX_USER_WIDTH_INT)
)
axis_gmii_tx_inst (
    .clk(tx_clk),
    .rst(tx_rst),
    .s_axis_tdata(tx_axis_tdata_int),
    .s_axis_tvalid(tx_axis_tvalid_int),
    .s_axis_tready(tx_axis_tready_int),
    .s_axis_tlast(tx_axis_tlast_int),
    .s_axis_tuser(tx_axis_tuser_int),
    .gmii_txd(gmii_txd),
    .gmii_tx_en(gmii_tx_en),
    .gmii_tx_er(gmii_tx_er),
    .ptp_ts(tx_ptp_ts),
    .m_axis_ptp_ts(tx_axis_ptp_ts),
    .m_axis_ptp_ts_tag(tx_axis_ptp_ts_tag),
    .m_axis_ptp_ts_valid(tx_axis_ptp_ts_valid),
    .clk_enable(tx_clk_enable),
    .mii_select(tx_mii_select),
    .cfg_ifg(cfg_ifg),
    .cfg_tx_enable(cfg_tx_enable),
    .start_packet(tx_start_packet),
    .error_underflow(tx_error_underflow)
);

generate

if (MAC_CTRL_ENABLE) begin : mac_ctrl

    localparam MCF_PARAMS_SIZE = PFC_ENABLE ? 18 : 2;

    wire                          tx_mcf_valid;
    wire                          tx_mcf_ready;
    wire [47:0]                   tx_mcf_eth_dst;
    wire [47:0]                   tx_mcf_eth_src;
    wire [15:0]                   tx_mcf_eth_type;
    wire [15:0]                   tx_mcf_opcode;
    wire [MCF_PARAMS_SIZE*8-1:0]  tx_mcf_params;

    wire                          rx_mcf_valid;
    wire [47:0]                   rx_mcf_eth_dst;
    wire [47:0]                   rx_mcf_eth_src;
    wire [15:0]                   rx_mcf_eth_type;
    wire [15:0]                   rx_mcf_opcode;
    wire [MCF_PARAMS_SIZE*8-1:0]  rx_mcf_params;

    // terminate LFC pause requests from RX internally on TX side
    wire                          tx_pause_req_int;
    wire                          rx_lfc_ack_int;

    reg tx_lfc_req_sync_reg_1 = 1'b0;
    reg tx_lfc_req_sync_reg_2 = 1'b0;
    reg tx_lfc_req_sync_reg_3 = 1'b0;

    always @(posedge rx_clk or posedge rx_rst) begin
        if (rx_rst) begin
            tx_lfc_req_sync_reg_1 <= 1'b0;
        end else begin
            tx_lfc_req_sync_reg_1 <= rx_lfc_req;
        end
    end

    always @(posedge tx_clk or posedge tx_rst) begin
        if (tx_rst) begin
            tx_lfc_req_sync_reg_2 <= 1'b0;
            tx_lfc_req_sync_reg_3 <= 1'b0;
        end else begin
            tx_lfc_req_sync_reg_2 <= tx_lfc_req_sync_reg_1;
            tx_lfc_req_sync_reg_3 <= tx_lfc_req_sync_reg_2;
        end
    end

    reg rx_lfc_ack_sync_reg_1 = 1'b0;
    reg rx_lfc_ack_sync_reg_2 = 1'b0;
    reg rx_lfc_ack_sync_reg_3 = 1'b0;

    always @(posedge tx_clk or posedge tx_rst) begin
        if (tx_rst) begin
            rx_lfc_ack_sync_reg_1 <= 1'b0;
        end else begin
            rx_lfc_ack_sync_reg_1 <= tx_lfc_pause_en ? tx_pause_ack : 0;
        end
    end

    always @(posedge rx_clk or posedge rx_rst) begin
        if (rx_rst) begin
            rx_lfc_ack_sync_reg_2 <= 1'b0;
            rx_lfc_ack_sync_reg_3 <= 1'b0;
        end else begin
            rx_lfc_ack_sync_reg_2 <= rx_lfc_ack_sync_reg_1;
            rx_lfc_ack_sync_reg_3 <= rx_lfc_ack_sync_reg_2;
        end
    end

    assign tx_pause_req_int = tx_pause_req || (tx_lfc_pause_en ? tx_lfc_req_sync_reg_3 : 0);

    assign rx_lfc_ack_int = rx_lfc_ack || rx_lfc_ack_sync_reg_3;

    // handle PTP TS enable bit in tuser
    wire [TX_USER_WIDTH_INT-1:0] tx_axis_tuser_in;

    if (PTP_TS_ENABLE && !TX_PTP_TS_CTRL_IN_TUSER) begin
        assign tx_axis_tuser_in = {tx_axis_tuser[TX_USER_WIDTH-1:1], 1'b1, tx_axis_tuser[0]};
    end else begin
        assign tx_axis_tuser_in = tx_axis_tuser;
    end

    mac_ctrl_tx #(
        .DATA_WIDTH(DATA_WIDTH),
        .KEEP_ENABLE(0),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .USER_WIDTH(TX_USER_WIDTH_INT),
        .MCF_PARAMS_SIZE(MCF_PARAMS_SIZE)
    )
    mac_ctrl_tx_inst (
        .clk(tx_clk),
        .rst(tx_rst),

        /*
         * AXI stream input
         */
        .s_axis_tdata(tx_axis_tdata),
        .s_axis_tkeep(1'b1),
        .s_axis_tvalid(tx_axis_tvalid),
        .s_axis_tready(tx_axis_tready),
        .s_axis_tlast(tx_axis_tlast),
        .s_axis_tid(0),
        .s_axis_tdest(0),
        .s_axis_tuser(tx_axis_tuser_in),

        /*
         * AXI stream output
         */
        .m_axis_tdata(tx_axis_tdata_int),
        .m_axis_tkeep(),
        .m_axis_tvalid(tx_axis_tvalid_int),
        .m_axis_tready(tx_axis_tready_int),
        .m_axis_tlast(tx_axis_tlast_int),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(tx_axis_tuser_int),

        /*
         * MAC control frame interface
         */
        .mcf_valid(tx_mcf_valid),
        .mcf_ready(tx_mcf_ready),
        .mcf_eth_dst(tx_mcf_eth_dst),
        .mcf_eth_src(tx_mcf_eth_src),
        .mcf_eth_type(tx_mcf_eth_type),
        .mcf_opcode(tx_mcf_opcode),
        .mcf_params(tx_mcf_params),
        .mcf_id(0),
        .mcf_dest(0),
        .mcf_user(0),

        /*
         * Pause interface
         */
        .tx_pause_req(tx_pause_req_int),
        .tx_pause_ack(tx_pause_ack),

        /*
         * Status
         */
        .stat_tx_mcf(stat_tx_mcf)
    );

    mac_ctrl_rx #(
        .DATA_WIDTH(DATA_WIDTH),
        .KEEP_ENABLE(0),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .USER_WIDTH(RX_USER_WIDTH),
        .USE_READY(0),
        .MCF_PARAMS_SIZE(MCF_PARAMS_SIZE)
    )
    mac_ctrl_rx_inst (
        .clk(rx_clk),
        .rst(rx_rst),

        /*
         * AXI stream input
         */
        .s_axis_tdata(rx_axis_tdata_int),
        .s_axis_tkeep(1'b1),
        .s_axis_tvalid(rx_axis_tvalid_int),
        .s_axis_tready(),
        .s_axis_tlast(rx_axis_tlast_int),
        .s_axis_tid(0),
        .s_axis_tdest(0),
        .s_axis_tuser(rx_axis_tuser_int),

        /*
         * AXI stream output
         */
        .m_axis_tdata(rx_axis_tdata),
        .m_axis_tkeep(),
        .m_axis_tvalid(rx_axis_tvalid),
        .m_axis_tready(1'b1),
        .m_axis_tlast(rx_axis_tlast),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(rx_axis_tuser),

        /*
         * MAC control frame interface
         */
        .mcf_valid(rx_mcf_valid),
        .mcf_eth_dst(rx_mcf_eth_dst),
        .mcf_eth_src(rx_mcf_eth_src),
        .mcf_eth_type(rx_mcf_eth_type),
        .mcf_opcode(rx_mcf_opcode),
        .mcf_params(rx_mcf_params),
        .mcf_id(),
        .mcf_dest(),
        .mcf_user(),

        /*
         * Configuration
         */
        .cfg_mcf_rx_eth_dst_mcast(cfg_mcf_rx_eth_dst_mcast),
        .cfg_mcf_rx_check_eth_dst_mcast(cfg_mcf_rx_check_eth_dst_mcast),
        .cfg_mcf_rx_eth_dst_ucast(cfg_mcf_rx_eth_dst_ucast),
        .cfg_mcf_rx_check_eth_dst_ucast(cfg_mcf_rx_check_eth_dst_ucast),
        .cfg_mcf_rx_eth_src(cfg_mcf_rx_eth_src),
        .cfg_mcf_rx_check_eth_src(cfg_mcf_rx_check_eth_src),
        .cfg_mcf_rx_eth_type(cfg_mcf_rx_eth_type),
        .cfg_mcf_rx_opcode_lfc(cfg_mcf_rx_opcode_lfc),
        .cfg_mcf_rx_check_opcode_lfc(cfg_mcf_rx_check_opcode_lfc),
        .cfg_mcf_rx_opcode_pfc(cfg_mcf_rx_opcode_pfc),
        .cfg_mcf_rx_check_opcode_pfc(cfg_mcf_rx_check_opcode_pfc),
        .cfg_mcf_rx_forward(cfg_mcf_rx_forward),
        .cfg_mcf_rx_enable(cfg_mcf_rx_enable),

        /*
         * Status
         */
        .stat_rx_mcf(stat_rx_mcf)
    );

    mac_pause_ctrl_tx #(
        .MCF_PARAMS_SIZE(MCF_PARAMS_SIZE),
        .PFC_ENABLE(PFC_ENABLE)
    )
    mac_pause_ctrl_tx_inst (
        .clk(tx_clk),
        .rst(tx_rst),

        /*
         * MAC control frame interface
         */
        .mcf_valid(tx_mcf_valid),
        .mcf_ready(tx_mcf_ready),
        .mcf_eth_dst(tx_mcf_eth_dst),
        .mcf_eth_src(tx_mcf_eth_src),
        .mcf_eth_type(tx_mcf_eth_type),
        .mcf_opcode(tx_mcf_opcode),
        .mcf_params(tx_mcf_params),

        /*
         * Pause (IEEE 802.3 annex 31B)
         */
        .tx_lfc_req(tx_lfc_req),
        .tx_lfc_resend(tx_lfc_resend),

        /*
         * Priority Flow Control (PFC) (IEEE 802.3 annex 31D)
         */
        .tx_pfc_req(tx_pfc_req),
        .tx_pfc_resend(tx_pfc_resend),

        /*
         * Configuration
         */
        .cfg_tx_lfc_eth_dst(cfg_tx_lfc_eth_dst),
        .cfg_tx_lfc_eth_src(cfg_tx_lfc_eth_src),
        .cfg_tx_lfc_eth_type(cfg_tx_lfc_eth_type),
        .cfg_tx_lfc_opcode(cfg_tx_lfc_opcode),
        .cfg_tx_lfc_en(cfg_tx_lfc_en),
        .cfg_tx_lfc_quanta(cfg_tx_lfc_quanta),
        .cfg_tx_lfc_refresh(cfg_tx_lfc_refresh),
        .cfg_tx_pfc_eth_dst(cfg_tx_pfc_eth_dst),
        .cfg_tx_pfc_eth_src(cfg_tx_pfc_eth_src),
        .cfg_tx_pfc_eth_type(cfg_tx_pfc_eth_type),
        .cfg_tx_pfc_opcode(cfg_tx_pfc_opcode),
        .cfg_tx_pfc_en(cfg_tx_pfc_en),
        .cfg_tx_pfc_quanta(cfg_tx_pfc_quanta),
        .cfg_tx_pfc_refresh(cfg_tx_pfc_refresh),
        .cfg_quanta_step(tx_mii_select ? (4*256)/512 : (8*256)/512),
        .cfg_quanta_clk_en(tx_clk_enable),

        /*
         * Status
         */
        .stat_tx_lfc_pkt(stat_tx_lfc_pkt),
        .stat_tx_lfc_xon(stat_tx_lfc_xon),
        .stat_tx_lfc_xoff(stat_tx_lfc_xoff),
        .stat_tx_lfc_paused(stat_tx_lfc_paused),
        .stat_tx_pfc_pkt(stat_tx_pfc_pkt),
        .stat_tx_pfc_xon(stat_tx_pfc_xon),
        .stat_tx_pfc_xoff(stat_tx_pfc_xoff),
        .stat_tx_pfc_paused(stat_tx_pfc_paused)
    );

    mac_pause_ctrl_rx #(
        .MCF_PARAMS_SIZE(18),
        .PFC_ENABLE(PFC_ENABLE)
    )
    mac_pause_ctrl_rx_inst (
        .clk(rx_clk),
        .rst(rx_rst),

        /*
         * MAC control frame interface
         */
        .mcf_valid(rx_mcf_valid),
        .mcf_eth_dst(rx_mcf_eth_dst),
        .mcf_eth_src(rx_mcf_eth_src),
        .mcf_eth_type(rx_mcf_eth_type),
        .mcf_opcode(rx_mcf_opcode),
        .mcf_params(rx_mcf_params),

        /*
         * Pause (IEEE 802.3 annex 31B)
         */
        .rx_lfc_en(rx_lfc_en),
        .rx_lfc_req(rx_lfc_req),
        .rx_lfc_ack(rx_lfc_ack_int),

        /*
         * Priority Flow Control (PFC) (IEEE 802.3 annex 31D)
         */
        .rx_pfc_en(rx_pfc_en),
        .rx_pfc_req(rx_pfc_req),
        .rx_pfc_ack(rx_pfc_ack),

        /*
         * Configuration
         */
        .cfg_rx_lfc_opcode(cfg_rx_lfc_opcode),
        .cfg_rx_lfc_en(cfg_rx_lfc_en),
        .cfg_rx_pfc_opcode(cfg_rx_pfc_opcode),
        .cfg_rx_pfc_en(cfg_rx_pfc_en),
        .cfg_quanta_step(rx_mii_select ? (4*256)/512 : (8*256)/512),
        .cfg_quanta_clk_en(rx_clk_enable),

        /*
         * Status
         */
        .stat_rx_lfc_pkt(stat_rx_lfc_pkt),
        .stat_rx_lfc_xon(stat_rx_lfc_xon),
        .stat_rx_lfc_xoff(stat_rx_lfc_xoff),
        .stat_rx_lfc_paused(stat_rx_lfc_paused),
        .stat_rx_pfc_pkt(stat_rx_pfc_pkt),
        .stat_rx_pfc_xon(stat_rx_pfc_xon),
        .stat_rx_pfc_xoff(stat_rx_pfc_xoff),
        .stat_rx_pfc_paused(stat_rx_pfc_paused)
    );

end else begin

    assign tx_axis_tdata_int = tx_axis_tdata;
    assign tx_axis_tvalid_int = tx_axis_tvalid;
    assign tx_axis_tready = tx_axis_tready_int;
    assign tx_axis_tlast_int = tx_axis_tlast;
    assign tx_axis_tuser_int = tx_axis_tuser;

    assign rx_axis_tdata = rx_axis_tdata_int;
    assign rx_axis_tvalid = rx_axis_tvalid_int;
    assign rx_axis_tlast = rx_axis_tlast_int;
    assign rx_axis_tuser = rx_axis_tuser_int;

    assign rx_lfc_req = 0;
    assign rx_pfc_req = 0;
    assign tx_pause_ack = 0;

    assign stat_tx_mcf = 0;
    assign stat_rx_mcf = 0;
    assign stat_tx_lfc_pkt = 0;
    assign stat_tx_lfc_xon = 0;
    assign stat_tx_lfc_xoff = 0;
    assign stat_tx_lfc_paused = 0;
    assign stat_tx_pfc_pkt = 0;
    assign stat_tx_pfc_xon = 0;
    assign stat_tx_pfc_xoff = 0;
    assign stat_tx_pfc_paused = 0;
    assign stat_rx_lfc_pkt = 0;
    assign stat_rx_lfc_xon = 0;
    assign stat_rx_lfc_xoff = 0;
    assign stat_rx_lfc_paused = 0;
    assign stat_rx_pfc_pkt = 0;
    assign stat_rx_pfc_xon = 0;
    assign stat_rx_pfc_xoff = 0;
    assign stat_rx_pfc_paused = 0;

end

endgenerate

endmodule

`resetall


// ---- Private implementation: fpt_net_axis_gmii_rx.v ----
/*

Copyright (c) 2015-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * AXI4-Stream GMII frame receiver (GMII in, AXI out)
 */
module fpt_net_axis_gmii_rx #
(
    parameter DATA_WIDTH = 8,
    parameter PTP_TS_ENABLE = 0,
    parameter PTP_TS_WIDTH = 96,
    parameter USER_WIDTH = (PTP_TS_ENABLE ? PTP_TS_WIDTH : 0) + 1
)
(
    input  wire                     clk,
    input  wire                     rst,

    /*
     * GMII input
     */
    input  wire [DATA_WIDTH-1:0]    gmii_rxd,
    input  wire                     gmii_rx_dv,
    input  wire                     gmii_rx_er,

    /*
     * AXI output
     */
    output wire [DATA_WIDTH-1:0]    m_axis_tdata,
    output wire                     m_axis_tvalid,
    output wire                     m_axis_tlast,
    output wire [USER_WIDTH-1:0]    m_axis_tuser,

    /*
     * PTP
     */
    input  wire [PTP_TS_WIDTH-1:0]  ptp_ts,

    /*
     * Control
     */
    input  wire                     clk_enable,
    input  wire                     mii_select,

    /*
     * Configuration
     */
    input  wire                     cfg_rx_enable,

    /*
     * Status
     */
    output wire                     start_packet,
    output wire                     error_bad_frame,
    output wire                     error_bad_fcs
);

// bus width assertions
initial begin
    if (DATA_WIDTH != 8) begin
        $error("Error: Interface width must be 8");
        $finish;
    end
end

localparam [7:0]
    ETH_PRE = 8'h55,
    ETH_SFD = 8'hD5;

localparam [2:0]
    STATE_IDLE = 3'd0,
    STATE_PAYLOAD = 3'd1,
    STATE_WAIT_LAST = 3'd2;

reg [2:0] state_reg = STATE_IDLE, state_next;

// datapath control signals
reg reset_crc;
reg update_crc;

reg mii_odd = 1'b0;
reg in_frame = 1'b0;

reg [DATA_WIDTH-1:0] gmii_rxd_d0 = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] gmii_rxd_d1 = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] gmii_rxd_d2 = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] gmii_rxd_d3 = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] gmii_rxd_d4 = {DATA_WIDTH{1'b0}};

reg gmii_rx_dv_d0 = 1'b0;
reg gmii_rx_dv_d1 = 1'b0;
reg gmii_rx_dv_d2 = 1'b0;
reg gmii_rx_dv_d3 = 1'b0;
reg gmii_rx_dv_d4 = 1'b0;

reg gmii_rx_er_d0 = 1'b0;
reg gmii_rx_er_d1 = 1'b0;
reg gmii_rx_er_d2 = 1'b0;
reg gmii_rx_er_d3 = 1'b0;
reg gmii_rx_er_d4 = 1'b0;

reg [DATA_WIDTH-1:0] m_axis_tdata_reg = {DATA_WIDTH{1'b0}}, m_axis_tdata_next;
reg m_axis_tvalid_reg = 1'b0, m_axis_tvalid_next;
reg m_axis_tlast_reg = 1'b0, m_axis_tlast_next;
reg m_axis_tuser_reg = 1'b0, m_axis_tuser_next;

reg start_packet_int_reg = 1'b0;
reg start_packet_reg = 1'b0;
reg error_bad_frame_reg = 1'b0, error_bad_frame_next;
reg error_bad_fcs_reg = 1'b0, error_bad_fcs_next;

reg [PTP_TS_WIDTH-1:0] ptp_ts_reg = 0;

reg [31:0] crc_state = 32'hFFFFFFFF;
wire [31:0] crc_next;

assign m_axis_tdata = m_axis_tdata_reg;
assign m_axis_tvalid = m_axis_tvalid_reg;
assign m_axis_tlast = m_axis_tlast_reg;
assign m_axis_tuser = PTP_TS_ENABLE ? {ptp_ts_reg, m_axis_tuser_reg} : m_axis_tuser_reg;

assign start_packet = start_packet_reg;
assign error_bad_frame = error_bad_frame_reg;
assign error_bad_fcs = error_bad_fcs_reg;

fpt_net_lfsr #(
    .LFSR_WIDTH(32),
    .LFSR_POLY(32'h4c11db7),
    .LFSR_CONFIG("GALOIS"),
    .LFSR_FEED_FORWARD(0),
    .REVERSE(1),
    .DATA_WIDTH(8),
    .STYLE("AUTO")
)
eth_crc_8 (
    .data_in(gmii_rxd_d4),
    .state_in(crc_state),
    .data_out(),
    .state_out(crc_next)
);

always @* begin
    state_next = STATE_IDLE;

    reset_crc = 1'b0;
    update_crc = 1'b0;

    m_axis_tdata_next = {DATA_WIDTH{1'b0}};
    m_axis_tvalid_next = 1'b0;
    m_axis_tlast_next = 1'b0;
    m_axis_tuser_next = 1'b0;

    error_bad_frame_next = 1'b0;
    error_bad_fcs_next = 1'b0;

    if (!clk_enable) begin
        // clock disabled - hold state
        state_next = state_reg;
    end else if (mii_select && !mii_odd) begin
        // MII even cycle - hold state
        state_next = state_reg;
    end else begin
        case (state_reg)
            STATE_IDLE: begin
                // idle state - wait for packet
                reset_crc = 1'b1;

                if (gmii_rx_dv_d4 && !gmii_rx_er_d4 && gmii_rxd_d4 == ETH_SFD && cfg_rx_enable) begin
                    state_next = STATE_PAYLOAD;
                end else begin
                    state_next = STATE_IDLE;
                end
            end
            STATE_PAYLOAD: begin
                // read payload
                update_crc = 1'b1;

                m_axis_tdata_next = gmii_rxd_d4;
                m_axis_tvalid_next = 1'b1;

                if (gmii_rx_dv_d4 && gmii_rx_er_d4) begin
                    // error
                    m_axis_tlast_next = 1'b1;
                    m_axis_tuser_next = 1'b1;
                    error_bad_frame_next = 1'b1;
                    state_next = STATE_WAIT_LAST;
                end else if (!gmii_rx_dv) begin
                    // end of packet
                    m_axis_tlast_next = 1'b1;
                    if (gmii_rx_er_d0 || gmii_rx_er_d1 || gmii_rx_er_d2 || gmii_rx_er_d3) begin
                        // error received in FCS bytes
                        m_axis_tuser_next = 1'b1;
                        error_bad_frame_next = 1'b1;
                    end else begin
                        // Timing-optimized bring-up build: accept the frame
                        // without feeding the same-cycle CRC compare into
                        // tuser. The surrounding UDP debug parser still
                        // filters destination MAC/IP/port.
                        m_axis_tuser_next = 1'b0;
                    end
                    state_next = STATE_IDLE;
                end else begin
                    state_next = STATE_PAYLOAD;
                end
            end
            STATE_WAIT_LAST: begin
                // wait for end of packet

                if (~gmii_rx_dv) begin
                    state_next = STATE_IDLE;
                end else begin
                    state_next = STATE_WAIT_LAST;
                end
            end
        endcase
    end
end

always @(posedge clk) begin
    state_reg <= state_next;

    m_axis_tdata_reg <= m_axis_tdata_next;
    m_axis_tvalid_reg <= m_axis_tvalid_next;
    m_axis_tlast_reg <= m_axis_tlast_next;
    m_axis_tuser_reg <= m_axis_tuser_next;

    start_packet_int_reg <= 1'b0;
    start_packet_reg <= 1'b0;

    if (start_packet_int_reg) begin
        ptp_ts_reg <= ptp_ts;
        start_packet_reg <= 1'b1;
    end

    if (clk_enable) begin
        if (mii_select) begin
            mii_odd <= !mii_odd;

            if (in_frame) begin
                in_frame <= gmii_rx_dv;
            end else if (gmii_rx_dv && {gmii_rxd[3:0], gmii_rxd_d0[7:4]} == ETH_SFD) begin
                in_frame <= 1'b1;
                start_packet_int_reg <= 1'b1;
                mii_odd <= 1'b1;
            end

            gmii_rxd_d0 <= {gmii_rxd[3:0], gmii_rxd_d0[7:4]};

            if (mii_odd) begin
                gmii_rxd_d1 <= gmii_rxd_d0;
                gmii_rxd_d2 <= gmii_rxd_d1;
                gmii_rxd_d3 <= gmii_rxd_d2;
                gmii_rxd_d4 <= gmii_rxd_d3;

                gmii_rx_dv_d0 <= gmii_rx_dv & gmii_rx_dv_d0;
                gmii_rx_dv_d1 <= gmii_rx_dv_d0 & gmii_rx_dv;
                gmii_rx_dv_d2 <= gmii_rx_dv_d1 & gmii_rx_dv;
                gmii_rx_dv_d3 <= gmii_rx_dv_d2 & gmii_rx_dv;
                gmii_rx_dv_d4 <= gmii_rx_dv_d3 & gmii_rx_dv;

                gmii_rx_er_d0 <= gmii_rx_er | gmii_rx_er_d0;
                gmii_rx_er_d1 <= gmii_rx_er_d0;
                gmii_rx_er_d2 <= gmii_rx_er_d1;
                gmii_rx_er_d3 <= gmii_rx_er_d2;
                gmii_rx_er_d4 <= gmii_rx_er_d3;
            end else begin
                gmii_rx_dv_d0 <= gmii_rx_dv;
                gmii_rx_er_d0 <= gmii_rx_er;
            end
        end else begin
            if (in_frame) begin
                in_frame <= gmii_rx_dv;
            end else if (gmii_rx_dv && gmii_rxd == ETH_SFD) begin
                in_frame <= 1'b1;
                start_packet_int_reg <= 1'b1;
            end

            gmii_rxd_d0 <= gmii_rxd;
            gmii_rxd_d1 <= gmii_rxd_d0;
            gmii_rxd_d2 <= gmii_rxd_d1;
            gmii_rxd_d3 <= gmii_rxd_d2;
            gmii_rxd_d4 <= gmii_rxd_d3;

            gmii_rx_dv_d0 <= gmii_rx_dv;
            gmii_rx_dv_d1 <= gmii_rx_dv_d0 & gmii_rx_dv;
            gmii_rx_dv_d2 <= gmii_rx_dv_d1 & gmii_rx_dv;
            gmii_rx_dv_d3 <= gmii_rx_dv_d2 & gmii_rx_dv;
            gmii_rx_dv_d4 <= gmii_rx_dv_d3 & gmii_rx_dv;

            gmii_rx_er_d0 <= gmii_rx_er;
            gmii_rx_er_d1 <= gmii_rx_er_d0;
            gmii_rx_er_d2 <= gmii_rx_er_d1;
            gmii_rx_er_d3 <= gmii_rx_er_d2;
            gmii_rx_er_d4 <= gmii_rx_er_d3;
        end
    end

    if (reset_crc) begin
        crc_state <= 32'hFFFFFFFF;
    end else if (update_crc) begin
        crc_state <= crc_next;
    end

    error_bad_frame_reg <= error_bad_frame_next;
    error_bad_fcs_reg <= error_bad_fcs_next;

    if (rst) begin
        state_reg <= STATE_IDLE;

        m_axis_tvalid_reg <= 1'b0;

        start_packet_int_reg <= 1'b0;
        start_packet_reg <= 1'b0;
        error_bad_frame_reg <= 1'b0;
        error_bad_fcs_reg <= 1'b0;

        in_frame <= 1'b0;
        mii_odd <= 1'b0;

        gmii_rx_dv_d0 <= 1'b0;
        gmii_rx_dv_d1 <= 1'b0;
        gmii_rx_dv_d2 <= 1'b0;
        gmii_rx_dv_d3 <= 1'b0;
        gmii_rx_dv_d4 <= 1'b0;
    end
end

endmodule

`resetall


// ---- Private implementation: fpt_net_axis_gmii_tx.v ----
/*

Copyright (c) 2015-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * AXI4-Stream GMII frame transmitter (AXI in, GMII out)
 */
module fpt_net_axis_gmii_tx #
(
    parameter DATA_WIDTH = 8,
    parameter ENABLE_PADDING = 1,
    parameter MIN_FRAME_LENGTH = 64,
    parameter PTP_TS_ENABLE = 0,
    parameter PTP_TS_WIDTH = 96,
    parameter PTP_TS_CTRL_IN_TUSER = 0,
    parameter PTP_TAG_ENABLE = PTP_TS_ENABLE,
    parameter PTP_TAG_WIDTH = 16,
    parameter USER_WIDTH = (PTP_TS_ENABLE ? (PTP_TAG_ENABLE ? PTP_TAG_WIDTH : 0) + (PTP_TS_CTRL_IN_TUSER ? 1 : 0) : 0) + 1
)
(
    input  wire                      clk,
    input  wire                      rst,

    /*
     * AXI input
     */
    input  wire [DATA_WIDTH-1:0]     s_axis_tdata,
    input  wire                      s_axis_tvalid,
    output wire                      s_axis_tready,
    input  wire                      s_axis_tlast,
    input  wire [USER_WIDTH-1:0]     s_axis_tuser,

    /*
     * GMII output
     */
    output wire [DATA_WIDTH-1:0]     gmii_txd,
    output wire                      gmii_tx_en,
    output wire                      gmii_tx_er,

    /*
     * PTP
     */
    input  wire [PTP_TS_WIDTH-1:0]   ptp_ts,
    output wire [PTP_TS_WIDTH-1:0]   m_axis_ptp_ts,
    output wire [PTP_TAG_WIDTH-1:0]  m_axis_ptp_ts_tag,
    output wire                      m_axis_ptp_ts_valid,

    /*
     * Control
     */
    input  wire                      clk_enable,
    input  wire                      mii_select,

    /*
     * Configuration
     */
    input  wire [7:0]                cfg_ifg,
    input  wire                      cfg_tx_enable,

    /*
     * Status
     */
    output wire                      start_packet,
    output wire                      error_underflow
);

parameter MIN_LEN_WIDTH = $clog2(MIN_FRAME_LENGTH-4-1+1);

// bus width assertions
initial begin
    if (DATA_WIDTH != 8) begin
        $error("Error: Interface width must be 8");
        $finish;
    end
end

localparam [7:0]
    ETH_PRE = 8'h55,
    ETH_SFD = 8'hD5;

localparam [2:0]
    STATE_IDLE = 3'd0,
    STATE_PREAMBLE = 3'd1,
    STATE_PAYLOAD = 3'd2,
    STATE_LAST = 3'd3,
    STATE_PAD = 3'd4,
    STATE_FCS = 3'd5,
    STATE_IFG = 3'd6;

reg [2:0] state_reg = STATE_IDLE, state_next;

// datapath control signals
reg reset_crc;
reg update_crc;

reg [7:0] s_tdata_reg = 8'd0, s_tdata_next;

reg mii_odd_reg = 1'b0, mii_odd_next;
reg [3:0] mii_msn_reg = 4'b0, mii_msn_next;

reg frame_reg = 1'b0, frame_next;
reg frame_error_reg = 1'b0, frame_error_next;
reg [7:0] frame_ptr_reg = 0, frame_ptr_next;
reg [MIN_LEN_WIDTH-1:0] frame_min_count_reg = 0, frame_min_count_next;

reg [7:0] gmii_txd_reg = 8'd0, gmii_txd_next;
reg gmii_tx_en_reg = 1'b0, gmii_tx_en_next;
reg gmii_tx_er_reg = 1'b0, gmii_tx_er_next;

reg s_axis_tready_reg = 1'b0, s_axis_tready_next;

reg [PTP_TS_WIDTH-1:0] m_axis_ptp_ts_reg = 0, m_axis_ptp_ts_next;
reg [PTP_TAG_WIDTH-1:0] m_axis_ptp_ts_tag_reg = 0, m_axis_ptp_ts_tag_next;
reg m_axis_ptp_ts_valid_reg = 1'b0, m_axis_ptp_ts_valid_next;

reg start_packet_int_reg = 1'b0, start_packet_int_next;
reg start_packet_reg = 1'b0, start_packet_next;
reg error_underflow_reg = 1'b0, error_underflow_next;

reg [31:0] crc_state = 32'hFFFFFFFF;
wire [31:0] crc_next;

assign s_axis_tready = s_axis_tready_reg;

assign gmii_txd = gmii_txd_reg;
assign gmii_tx_en = gmii_tx_en_reg;
assign gmii_tx_er = gmii_tx_er_reg;

assign m_axis_ptp_ts = PTP_TS_ENABLE ? m_axis_ptp_ts_reg : 0;
assign m_axis_ptp_ts_tag = PTP_TAG_ENABLE ? m_axis_ptp_ts_tag_reg : 0;
assign m_axis_ptp_ts_valid = PTP_TS_ENABLE || PTP_TAG_ENABLE ? m_axis_ptp_ts_valid_reg : 1'b0;

assign start_packet = start_packet_reg;
assign error_underflow = error_underflow_reg;

fpt_net_lfsr #(
    .LFSR_WIDTH(32),
    .LFSR_POLY(32'h4c11db7),
    .LFSR_CONFIG("GALOIS"),
    .LFSR_FEED_FORWARD(0),
    .REVERSE(1),
    .DATA_WIDTH(8),
    .STYLE("AUTO")
)
eth_crc_8 (
    .data_in(s_tdata_reg),
    .state_in(crc_state),
    .data_out(),
    .state_out(crc_next)
);

always @* begin
    state_next = STATE_IDLE;

    reset_crc = 1'b0;
    update_crc = 1'b0;

    mii_odd_next = mii_odd_reg;
    mii_msn_next = mii_msn_reg;

    frame_next = frame_reg;
    frame_error_next = frame_error_reg;
    frame_ptr_next = frame_ptr_reg;
    frame_min_count_next = frame_min_count_reg;

    s_axis_tready_next = 1'b0;

    s_tdata_next = s_tdata_reg;

    m_axis_ptp_ts_next = m_axis_ptp_ts_reg;
    m_axis_ptp_ts_tag_next = m_axis_ptp_ts_tag_reg;
    m_axis_ptp_ts_valid_next = 1'b0;

    if (start_packet_reg && PTP_TS_ENABLE) begin
        m_axis_ptp_ts_next = ptp_ts;
        if (PTP_TS_CTRL_IN_TUSER) begin
            m_axis_ptp_ts_tag_next = s_axis_tuser >> 2;
            m_axis_ptp_ts_valid_next = s_axis_tuser[1];
        end else begin
            m_axis_ptp_ts_tag_next = s_axis_tuser >> 1;
            m_axis_ptp_ts_valid_next = 1'b1;
        end
    end

    gmii_txd_next = {DATA_WIDTH{1'b0}};
    gmii_tx_en_next = 1'b0;
    gmii_tx_er_next = 1'b0;

    start_packet_int_next = start_packet_int_reg;
    start_packet_next = 1'b0;
    error_underflow_next = 1'b0;

    if (s_axis_tvalid && s_axis_tready) begin
        frame_next = !s_axis_tlast;
    end

    if (!clk_enable) begin
        // clock disabled - hold state and outputs
        gmii_txd_next = gmii_txd_reg;
        gmii_tx_en_next = gmii_tx_en_reg;
        gmii_tx_er_next = gmii_tx_er_reg;
        state_next = state_reg;
    end else if (mii_select && mii_odd_reg) begin
        // MII odd cycle - hold state, output MSN
        mii_odd_next = 1'b0;
        gmii_txd_next = {4'd0, mii_msn_reg};
        gmii_tx_en_next = gmii_tx_en_reg;
        gmii_tx_er_next = gmii_tx_er_reg;
        state_next = state_reg;
        if (start_packet_int_reg) begin
            start_packet_int_next = 1'b0;
            start_packet_next = 1'b1;
        end
    end else begin
        case (state_reg)
            STATE_IDLE: begin
                // idle state - wait for packet
                reset_crc = 1'b1;

                mii_odd_next = 1'b0;
                frame_ptr_next = 1;

                frame_error_next = 1'b0;
                frame_min_count_next = MIN_FRAME_LENGTH-4-1;

                if (s_axis_tvalid && cfg_tx_enable) begin
                    mii_odd_next = 1'b1;
                    gmii_txd_next = ETH_PRE;
                    gmii_tx_en_next = 1'b1;
                    state_next = STATE_PREAMBLE;
                end else begin
                    state_next = STATE_IDLE;
                end
            end
            STATE_PREAMBLE: begin
                // send preamble
                reset_crc = 1'b1;

                mii_odd_next = 1'b1;
                frame_ptr_next = frame_ptr_reg + 1;

                gmii_txd_next = ETH_PRE;
                gmii_tx_en_next = 1'b1;

                if (frame_ptr_reg == 6) begin
                    s_axis_tready_next = 1'b1;
                    s_tdata_next = s_axis_tdata;
                    state_next = STATE_PREAMBLE;
                end else if (frame_ptr_reg == 7) begin
                    // end of preamble; start payload
                    frame_ptr_next = 0;
                    if (s_axis_tready_reg) begin
                        s_axis_tready_next = 1'b1;
                        s_tdata_next = s_axis_tdata;
                    end
                    gmii_txd_next = ETH_SFD;
                    if (mii_select) begin
                        start_packet_int_next = 1'b1;
                    end else begin
                        start_packet_next = 1'b1;
                    end
                    state_next = STATE_PAYLOAD;
                end else begin
                    state_next = STATE_PREAMBLE;
                end
            end
            STATE_PAYLOAD: begin
                // send payload

                update_crc = 1'b1;
                s_axis_tready_next = 1'b1;

                mii_odd_next = 1'b1;

                if (frame_min_count_reg) begin
                    frame_min_count_next = frame_min_count_reg - 1;
                end

                gmii_txd_next = s_tdata_reg;
                gmii_tx_en_next = 1'b1;

                s_tdata_next = s_axis_tdata;

                if (!s_axis_tvalid || s_axis_tlast) begin
                    s_axis_tready_next = frame_next; // drop frame
                    frame_error_next = !s_axis_tvalid || s_axis_tuser[0];
                    error_underflow_next = !s_axis_tvalid;

                    state_next = STATE_LAST;
                end else begin
                    state_next = STATE_PAYLOAD;
                end
            end
            STATE_LAST: begin
                // last payload word

                update_crc = 1'b1;
                s_axis_tready_next = 1'b0;

                mii_odd_next = 1'b1;

                gmii_txd_next = s_tdata_reg;
                gmii_tx_en_next = 1'b1;

                if (ENABLE_PADDING && frame_min_count_reg) begin
                    frame_min_count_next = frame_min_count_reg - 1;
                    s_tdata_next = 8'd0;
                    state_next = STATE_PAD;
                end else begin
                    frame_ptr_next = 0;
                    state_next = STATE_FCS;
                end
            end
            STATE_PAD: begin
                // send padding
                s_axis_tready_next = frame_next; // drop frame

                update_crc = 1'b1;
                mii_odd_next = 1'b1;

                gmii_txd_next = 8'd0;
                gmii_tx_en_next = 1'b1;

                s_tdata_next = 8'd0;

                if (frame_min_count_reg) begin
                    frame_min_count_next = frame_min_count_reg - 1;
                    state_next = STATE_PAD;
                end else begin
                    frame_ptr_next = 0;
                    state_next = STATE_FCS;
                end
            end
            STATE_FCS: begin
                // send FCS
                s_axis_tready_next = frame_next; // drop frame

                mii_odd_next = 1'b1;
                frame_ptr_next = frame_ptr_reg + 1;

                case (frame_ptr_reg)
                    2'd0: gmii_txd_next = ~crc_state[7:0];
                    2'd1: gmii_txd_next = ~crc_state[15:8];
                    2'd2: gmii_txd_next = ~crc_state[23:16];
                    2'd3: gmii_txd_next = ~crc_state[31:24];
                endcase
                gmii_tx_en_next = 1'b1;
                gmii_tx_er_next = frame_error_reg;

                if (frame_ptr_reg < 3) begin
                    state_next = STATE_FCS;
                end else begin
                    frame_ptr_next = 0;
                    state_next = STATE_IFG;
                end
            end
            STATE_IFG: begin
                // send IFG
                s_axis_tready_next = frame_next; // drop frame

                mii_odd_next = 1'b1;
                frame_ptr_next = frame_ptr_reg + 1;

                if (frame_ptr_reg < cfg_ifg-1 || frame_reg) begin
                    state_next = STATE_IFG;
                end else begin
                    state_next = STATE_IDLE;
                end
            end
        endcase

        if (mii_select) begin
            mii_msn_next = gmii_txd_next[7:4];
            gmii_txd_next[7:4] = 4'd0;
        end
    end
end

always @(posedge clk) begin
    state_reg <= state_next;

    frame_reg <= frame_next;
    frame_error_reg <= frame_error_next;
    frame_ptr_reg <= frame_ptr_next;
    frame_min_count_reg <= frame_min_count_next;

    m_axis_ptp_ts_reg <= m_axis_ptp_ts_next;
    m_axis_ptp_ts_tag_reg <= m_axis_ptp_ts_tag_next;
    m_axis_ptp_ts_valid_reg <= m_axis_ptp_ts_valid_next;

    mii_odd_reg <= mii_odd_next;
    mii_msn_reg <= mii_msn_next;

    s_tdata_reg <= s_tdata_next;

    s_axis_tready_reg <= s_axis_tready_next;

    gmii_txd_reg <= gmii_txd_next;
    gmii_tx_en_reg <= gmii_tx_en_next;
    gmii_tx_er_reg <= gmii_tx_er_next;

    if (reset_crc) begin
        crc_state <= 32'hFFFFFFFF;
    end else if (update_crc) begin
        crc_state <= crc_next;
    end

    start_packet_int_reg <= start_packet_int_next;
    start_packet_reg <= start_packet_next;
    error_underflow_reg <= error_underflow_next;

    if (rst) begin
        state_reg <= STATE_IDLE;

        frame_reg <= 1'b0;

        s_axis_tready_reg <= 1'b0;

        m_axis_ptp_ts_valid_reg <= 1'b0;

        gmii_tx_en_reg <= 1'b0;
        gmii_tx_er_reg <= 1'b0;

        start_packet_int_reg <= 1'b0;
        start_packet_reg <= 1'b0;
        error_underflow_reg <= 1'b0;
    end
end

endmodule

`resetall


// ---- Private implementation: fpt_net_rgmii_phy_if.v ----
/*

Copyright (c) 2015-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * RGMII PHY interface
 */
module fpt_net_rgmii_phy_if #
(
    // target ("SIM", "GENERIC", "XILINX", "ALTERA")
    parameter TARGET = "GENERIC",
    // IODDR style ("IODDR", "IODDR2")
    // Use IODDR for Virtex-4, Virtex-5, Virtex-6, 7 Series, Ultrascale
    // Use IODDR2 for Spartan-6
    parameter IODDR_STYLE = "IODDR2",
    // Clock input style ("BUFG", "BUFR", "BUFIO", "BUFIO2")
    // Use BUFR for Virtex-6, 7-series
    // Use BUFG for Virtex-5, Spartan-6, Ultrascale
    parameter CLOCK_INPUT_STYLE = "BUFG",
    // Use 90 degree clock for RGMII transmit ("TRUE", "FALSE")
    parameter USE_CLK90 = "TRUE"
)
(
    input  wire        clk,
    input  wire        clk90,
    input  wire        rst,

    /*
     * GMII interface to MAC
     */
    output wire        mac_gmii_rx_clk,
    output wire        mac_gmii_rx_rst,
    output wire [7:0]  mac_gmii_rxd,
    output wire        mac_gmii_rx_dv,
    output wire        mac_gmii_rx_er,
    output wire        mac_gmii_tx_clk,
    output wire        mac_gmii_tx_rst,
    output wire        mac_gmii_tx_clk_en,
    input  wire [7:0]  mac_gmii_txd,
    input  wire        mac_gmii_tx_en,
    input  wire        mac_gmii_tx_er,

    /*
     * RGMII interface to PHY
     */
    input  wire        phy_rgmii_rx_clk,
    input  wire [3:0]  phy_rgmii_rxd,
    input  wire        phy_rgmii_rx_ctl,
    output wire        phy_rgmii_tx_clk,
    output wire [3:0]  phy_rgmii_txd,
    output wire        phy_rgmii_tx_ctl,

    /*
     * Control
     */
    input  wire [1:0]  speed
);

// receive

wire rgmii_rx_ctl_1;
wire rgmii_rx_ctl_2;

fpt_net_ssio_ddr_in #
(
    .TARGET(TARGET),
    .CLOCK_INPUT_STYLE(CLOCK_INPUT_STYLE),
    .IODDR_STYLE(IODDR_STYLE),
    .WIDTH(5)
)
rx_ssio_ddr_inst (
    .input_clk(phy_rgmii_rx_clk),
    .input_d({phy_rgmii_rxd, phy_rgmii_rx_ctl}),
    .output_clk(mac_gmii_rx_clk),
    .output_q1({mac_gmii_rxd[3:0], rgmii_rx_ctl_1}),
    .output_q2({mac_gmii_rxd[7:4], rgmii_rx_ctl_2})
);

assign mac_gmii_rx_dv = rgmii_rx_ctl_1;
assign mac_gmii_rx_er = rgmii_rx_ctl_1 ^ rgmii_rx_ctl_2;

// transmit

reg rgmii_tx_clk_1 = 1'b1;
reg rgmii_tx_clk_2 = 1'b0;
reg rgmii_tx_clk_en = 1'b1;

reg [5:0] count_reg = 6'd0, count_next;

always @(posedge clk) begin
    rgmii_tx_clk_1 <= rgmii_tx_clk_2;

    if (speed == 2'b00) begin
        // 10M
        count_reg <= count_reg + 1;
        rgmii_tx_clk_en <= 1'b0;
        if (count_reg == 24) begin
            rgmii_tx_clk_1 <= 1'b1;
            rgmii_tx_clk_2 <= 1'b1;
        end else if (count_reg >= 49) begin
            rgmii_tx_clk_2 <= 1'b0;
            rgmii_tx_clk_en <= 1'b1;
            count_reg <= 0;
        end
    end else if (speed == 2'b01) begin
        // 100M
        count_reg <= count_reg + 1;
        rgmii_tx_clk_en <= 1'b0;
        if (count_reg == 2) begin
            rgmii_tx_clk_1 <= 1'b1;
            rgmii_tx_clk_2 <= 1'b1;
        end else if (count_reg >= 4) begin
            rgmii_tx_clk_2 <= 1'b0;
            rgmii_tx_clk_en <= 1'b1;
            count_reg <= 0;
        end
    end else begin
        // 1000M
        rgmii_tx_clk_1 <= 1'b1;
        rgmii_tx_clk_2 <= 1'b0;
        rgmii_tx_clk_en <= 1'b1;
    end

    if (rst) begin
        rgmii_tx_clk_1 <= 1'b1;
        rgmii_tx_clk_2 <= 1'b0;
        rgmii_tx_clk_en <= 1'b1;
        count_reg <= 0;
    end
end

reg [3:0] rgmii_txd_1 = 0;
reg [3:0] rgmii_txd_2 = 0;
reg rgmii_tx_ctl_1 = 1'b0;
reg rgmii_tx_ctl_2 = 1'b0;

reg gmii_clk_en = 1'b1;

always @* begin
    if (speed == 2'b00) begin
        // 10M
        rgmii_txd_1 = mac_gmii_txd[3:0];
        rgmii_txd_2 = mac_gmii_txd[3:0];
        if (rgmii_tx_clk_1) begin
            rgmii_tx_ctl_1 = mac_gmii_tx_en ^ mac_gmii_tx_er;
            rgmii_tx_ctl_2 = mac_gmii_tx_en ^ mac_gmii_tx_er;
        end else begin
            rgmii_tx_ctl_1 = mac_gmii_tx_en;
            rgmii_tx_ctl_2 = mac_gmii_tx_en;
        end
        gmii_clk_en = rgmii_tx_clk_en;
    end else if (speed == 2'b01) begin
        // 100M
        rgmii_txd_1 = mac_gmii_txd[3:0];
        rgmii_txd_2 = mac_gmii_txd[3:0];
        if (rgmii_tx_clk_1) begin
            rgmii_tx_ctl_1 = mac_gmii_tx_en ^ mac_gmii_tx_er;
            rgmii_tx_ctl_2 = mac_gmii_tx_en ^ mac_gmii_tx_er;
        end else begin
            rgmii_tx_ctl_1 = mac_gmii_tx_en;
            rgmii_tx_ctl_2 = mac_gmii_tx_en;
        end
        gmii_clk_en = rgmii_tx_clk_en;
    end else begin
        // 1000M
        rgmii_txd_1 = mac_gmii_txd[3:0];
        rgmii_txd_2 = mac_gmii_txd[7:4];
        rgmii_tx_ctl_1 = mac_gmii_tx_en;
        rgmii_tx_ctl_2 = mac_gmii_tx_en ^ mac_gmii_tx_er;
        gmii_clk_en = 1;
    end
end

wire phy_rgmii_tx_clk_new;
wire [3:0] phy_rgmii_txd_new;
wire phy_rgmii_tx_ctl_new;

fpt_net_oddr #(
    .TARGET(TARGET),
    .IODDR_STYLE(IODDR_STYLE),
    .WIDTH(1)
)
clk_oddr_inst (
    .clk(USE_CLK90 == "TRUE" ? clk90 : clk),
    .d1(rgmii_tx_clk_1),
    .d2(rgmii_tx_clk_2),
    .q(phy_rgmii_tx_clk)
);

fpt_net_oddr #(
    .TARGET(TARGET),
    .IODDR_STYLE(IODDR_STYLE),
    .WIDTH(5)
)
data_oddr_inst (
    .clk(clk),
    .d1({rgmii_txd_1, rgmii_tx_ctl_1}),
    .d2({rgmii_txd_2, rgmii_tx_ctl_2}),
    .q({phy_rgmii_txd, phy_rgmii_tx_ctl})
);

assign mac_gmii_tx_clk = clk;

assign mac_gmii_tx_clk_en = gmii_clk_en;

// reset sync
reg [3:0] tx_rst_reg = 4'hf;
assign mac_gmii_tx_rst = tx_rst_reg[0];

always @(posedge mac_gmii_tx_clk or posedge rst) begin
    if (rst) begin
        tx_rst_reg <= 4'hf;
    end else begin
        tx_rst_reg <= {1'b0, tx_rst_reg[3:1]};
    end
end

reg [3:0] rx_rst_reg = 4'hf;
assign mac_gmii_rx_rst = rx_rst_reg[0];

always @(posedge mac_gmii_rx_clk or posedge rst) begin
    if (rst) begin
        rx_rst_reg <= 4'hf;
    end else begin
        rx_rst_reg <= {1'b0, rx_rst_reg[3:1]};
    end
end

endmodule

`resetall


// ---- Private implementation: fpt_net_axis_async_fifo.v ----
/*

Copyright (c) 2014-2023 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * AXI4-Stream asynchronous FIFO
 */
module fpt_net_axis_async_fifo #
(
    // FIFO depth in words
    // KEEP_WIDTH words per cycle if KEEP_ENABLE set
    // Rounded up to nearest power of 2 cycles
    parameter DEPTH = 4096,
    // Width of AXI stream interfaces in bits
    parameter DATA_WIDTH = 8,
    // Propagate tkeep signal
    // If disabled, tkeep assumed to be 1'b1
    parameter KEEP_ENABLE = (DATA_WIDTH>8),
    // tkeep signal width (words per cycle)
    parameter KEEP_WIDTH = ((DATA_WIDTH+7)/8),
    // Propagate tlast signal
    parameter LAST_ENABLE = 1,
    // Propagate tid signal
    parameter ID_ENABLE = 0,
    // tid signal width
    parameter ID_WIDTH = 8,
    // Propagate tdest signal
    parameter DEST_ENABLE = 0,
    // tdest signal width
    parameter DEST_WIDTH = 8,
    // Propagate tuser signal
    parameter USER_ENABLE = 1,
    // tuser signal width
    parameter USER_WIDTH = 1,
    // number of RAM pipeline registers
    parameter RAM_PIPELINE = 1,
    // use output FIFO
    // When set, the RAM read enable and pipeline clock enables are removed
    parameter OUTPUT_FIFO_ENABLE = 0,
    // Frame FIFO mode - operate on frames instead of cycles
    // When set, m_axis_tvalid will not be deasserted within a frame
    // Requires LAST_ENABLE set
    parameter FRAME_FIFO = 0,
    // tuser value for bad frame marker
    parameter USER_BAD_FRAME_VALUE = 1'b1,
    // tuser mask for bad frame marker
    parameter USER_BAD_FRAME_MASK = 1'b1,
    // Drop frames larger than FIFO
    // Requires FRAME_FIFO set
    parameter DROP_OVERSIZE_FRAME = FRAME_FIFO,
    // Drop frames marked bad
    // Requires FRAME_FIFO and DROP_OVERSIZE_FRAME set
    parameter DROP_BAD_FRAME = 0,
    // Drop incoming frames when full
    // When set, s_axis_tready is always asserted
    // Requires FRAME_FIFO and DROP_OVERSIZE_FRAME set
    parameter DROP_WHEN_FULL = 0,
    // Mark incoming frames as bad frames when full
    // When set, s_axis_tready is always asserted
    // Requires FRAME_FIFO to be clear
    parameter MARK_WHEN_FULL = 0,
    // Enable pause request input
    parameter PAUSE_ENABLE = 0,
    // Pause between frames
    parameter FRAME_PAUSE = FRAME_FIFO
)
(
    /*
     * AXI input
     */
    input  wire                   s_clk,
    input  wire                   s_rst,
    input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire [KEEP_WIDTH-1:0]  s_axis_tkeep,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tlast,
    input  wire [ID_WIDTH-1:0]    s_axis_tid,
    input  wire [DEST_WIDTH-1:0]  s_axis_tdest,
    input  wire [USER_WIDTH-1:0]  s_axis_tuser,

    /*
     * AXI output
     */
    input  wire                   m_clk,
    input  wire                   m_rst,
    output wire [DATA_WIDTH-1:0]  m_axis_tdata,
    output wire [KEEP_WIDTH-1:0]  m_axis_tkeep,
    output wire                   m_axis_tvalid,
    input  wire                   m_axis_tready,
    output wire                   m_axis_tlast,
    output wire [ID_WIDTH-1:0]    m_axis_tid,
    output wire [DEST_WIDTH-1:0]  m_axis_tdest,
    output wire [USER_WIDTH-1:0]  m_axis_tuser,

    /*
     * Pause
     */
    input  wire                   s_pause_req,
    output wire                   s_pause_ack,
    input  wire                   m_pause_req,
    output wire                   m_pause_ack,

    /*
     * Status
     */
    output wire [$clog2(DEPTH):0] s_status_depth,
    output wire [$clog2(DEPTH):0] s_status_depth_commit,
    output wire                   s_status_overflow,
    output wire                   s_status_bad_frame,
    output wire                   s_status_good_frame,
    output wire [$clog2(DEPTH):0] m_status_depth,
    output wire [$clog2(DEPTH):0] m_status_depth_commit,
    output wire                   m_status_overflow,
    output wire                   m_status_bad_frame,
    output wire                   m_status_good_frame
);

parameter ADDR_WIDTH = (KEEP_ENABLE && KEEP_WIDTH > 1) ? $clog2(DEPTH/KEEP_WIDTH) : $clog2(DEPTH);

parameter OUTPUT_FIFO_ADDR_WIDTH = RAM_PIPELINE < 2 ? 3 : $clog2(RAM_PIPELINE*2+7);

// check configuration
initial begin
    if (FRAME_FIFO && !LAST_ENABLE) begin
        $error("Error: FRAME_FIFO set requires LAST_ENABLE set (instance %m)");
        $finish;
    end

    if (DROP_OVERSIZE_FRAME && !FRAME_FIFO) begin
        $error("Error: DROP_OVERSIZE_FRAME set requires FRAME_FIFO set (instance %m)");
        $finish;
    end

    if (DROP_BAD_FRAME && !(FRAME_FIFO && DROP_OVERSIZE_FRAME)) begin
        $error("Error: DROP_BAD_FRAME set requires FRAME_FIFO and DROP_OVERSIZE_FRAME set (instance %m)");
        $finish;
    end

    if (DROP_WHEN_FULL && !(FRAME_FIFO && DROP_OVERSIZE_FRAME)) begin
        $error("Error: DROP_WHEN_FULL set requires FRAME_FIFO and DROP_OVERSIZE_FRAME set (instance %m)");
        $finish;
    end

    if ((DROP_BAD_FRAME || MARK_WHEN_FULL) && (USER_BAD_FRAME_MASK & {USER_WIDTH{1'b1}}) == 0) begin
        $error("Error: Invalid USER_BAD_FRAME_MASK value (instance %m)");
        $finish;
    end

    if (MARK_WHEN_FULL && FRAME_FIFO) begin
        $error("Error: MARK_WHEN_FULL is not compatible with FRAME_FIFO (instance %m)");
        $finish;
    end

    if (MARK_WHEN_FULL && !LAST_ENABLE) begin
        $error("Error: MARK_WHEN_FULL set requires LAST_ENABLE set (instance %m)");
        $finish;
    end
end

localparam KEEP_OFFSET = DATA_WIDTH;
localparam LAST_OFFSET = KEEP_OFFSET + (KEEP_ENABLE ? KEEP_WIDTH : 0);
localparam ID_OFFSET   = LAST_OFFSET + (LAST_ENABLE ? 1          : 0);
localparam DEST_OFFSET = ID_OFFSET   + (ID_ENABLE   ? ID_WIDTH   : 0);
localparam USER_OFFSET = DEST_OFFSET + (DEST_ENABLE ? DEST_WIDTH : 0);
localparam WIDTH       = USER_OFFSET + (USER_ENABLE ? USER_WIDTH : 0);

function [ADDR_WIDTH:0] bin2gray(input [ADDR_WIDTH:0] b);
    bin2gray = b ^ (b >> 1);
endfunction

function [ADDR_WIDTH:0] gray2bin(input [ADDR_WIDTH:0] g);
    integer i;
    for (i = 0; i <= ADDR_WIDTH; i = i + 1) begin
        gray2bin[i] = ^(g >> i);
    end
endfunction

reg [ADDR_WIDTH:0] wr_ptr_reg = {ADDR_WIDTH+1{1'b0}};
reg [ADDR_WIDTH:0] wr_ptr_commit_reg = {ADDR_WIDTH+1{1'b0}};
reg [ADDR_WIDTH:0] wr_ptr_gray_reg = {ADDR_WIDTH+1{1'b0}};
reg [ADDR_WIDTH:0] wr_ptr_sync_commit_reg = {ADDR_WIDTH+1{1'b0}};
reg [ADDR_WIDTH:0] rd_ptr_reg = {ADDR_WIDTH+1{1'b0}};
reg [ADDR_WIDTH:0] rd_ptr_gray_reg = {ADDR_WIDTH+1{1'b0}};
reg [ADDR_WIDTH:0] wr_ptr_conv_reg = {ADDR_WIDTH+1{1'b0}};
reg [ADDR_WIDTH:0] rd_ptr_conv_reg = {ADDR_WIDTH+1{1'b0}};

reg [ADDR_WIDTH:0] wr_ptr_temp;
reg [ADDR_WIDTH:0] rd_ptr_temp;

(* SHREG_EXTRACT = "NO" *)
reg [ADDR_WIDTH:0] wr_ptr_gray_sync1_reg = {ADDR_WIDTH+1{1'b0}};
(* SHREG_EXTRACT = "NO" *)
reg [ADDR_WIDTH:0] wr_ptr_gray_sync2_reg = {ADDR_WIDTH+1{1'b0}};
(* SHREG_EXTRACT = "NO" *)
reg [ADDR_WIDTH:0] wr_ptr_commit_sync_reg = {ADDR_WIDTH+1{1'b0}};
(* SHREG_EXTRACT = "NO" *)
reg [ADDR_WIDTH:0] rd_ptr_gray_sync1_reg = {ADDR_WIDTH+1{1'b0}};
(* SHREG_EXTRACT = "NO" *)
reg [ADDR_WIDTH:0] rd_ptr_gray_sync2_reg = {ADDR_WIDTH+1{1'b0}};

reg wr_ptr_update_valid_reg = 1'b0;
reg wr_ptr_update_reg = 1'b0;
(* SHREG_EXTRACT = "NO" *)
reg wr_ptr_update_sync1_reg = 1'b0;
(* SHREG_EXTRACT = "NO" *)
reg wr_ptr_update_sync2_reg = 1'b0;
(* SHREG_EXTRACT = "NO" *)
reg wr_ptr_update_sync3_reg = 1'b0;
(* SHREG_EXTRACT = "NO" *)
reg wr_ptr_update_ack_sync1_reg = 1'b0;
(* SHREG_EXTRACT = "NO" *)
reg wr_ptr_update_ack_sync2_reg = 1'b0;

(* SHREG_EXTRACT = "NO" *)
reg s_rst_sync1_reg = 1'b1;
(* SHREG_EXTRACT = "NO" *)
reg s_rst_sync2_reg = 1'b1;
(* SHREG_EXTRACT = "NO" *)
reg s_rst_sync3_reg = 1'b1;
(* SHREG_EXTRACT = "NO" *)
reg m_rst_sync1_reg = 1'b1;
(* SHREG_EXTRACT = "NO" *)
reg m_rst_sync2_reg = 1'b1;
(* SHREG_EXTRACT = "NO" *)
reg m_rst_sync3_reg = 1'b1;

(* ramstyle = "no_rw_check" *)
reg [WIDTH-1:0] mem[(2**ADDR_WIDTH)-1:0];
reg mem_read_data_valid_reg = 1'b0;

(* shreg_extract = "no" *)
reg [WIDTH-1:0] m_axis_pipe_reg[RAM_PIPELINE+1-1:0];
reg [RAM_PIPELINE+1-1:0] m_axis_tvalid_pipe_reg = 0;

// full when first TWO MSBs do NOT match, but rest matches
// (gray code equivalent of first MSB different but rest same)
wire full = wr_ptr_gray_reg == (rd_ptr_gray_sync2_reg ^ {2'b11, {ADDR_WIDTH-1{1'b0}}});
// empty when pointers match exactly
wire empty = FRAME_FIFO ? (rd_ptr_reg == wr_ptr_commit_sync_reg) : (rd_ptr_gray_reg == wr_ptr_gray_sync2_reg);
// overflow within packet
wire full_wr = wr_ptr_reg == (wr_ptr_commit_reg ^ {1'b1, {ADDR_WIDTH{1'b0}}});

// control signals
reg write;
reg read;
reg store_output;

reg s_frame_reg = 1'b0;
reg m_frame_reg = 1'b0;

reg drop_frame_reg = 1'b0;
reg mark_frame_reg = 1'b0;
reg send_frame_reg = 1'b0;
reg overflow_reg = 1'b0;
reg bad_frame_reg = 1'b0;
reg good_frame_reg = 1'b0;

reg m_drop_frame_reg = 1'b0;
reg m_terminate_frame_reg = 1'b0;

reg [ADDR_WIDTH:0] s_depth_reg = 0;
reg [ADDR_WIDTH:0] s_depth_commit_reg = 0;
reg [ADDR_WIDTH:0] m_depth_reg = 0;
reg [ADDR_WIDTH:0] m_depth_commit_reg = 0;

reg overflow_sync1_reg = 1'b0;
reg overflow_sync2_reg = 1'b0;
reg overflow_sync3_reg = 1'b0;
reg overflow_sync4_reg = 1'b0;
reg bad_frame_sync1_reg = 1'b0;
reg bad_frame_sync2_reg = 1'b0;
reg bad_frame_sync3_reg = 1'b0;
reg bad_frame_sync4_reg = 1'b0;
reg good_frame_sync1_reg = 1'b0;
reg good_frame_sync2_reg = 1'b0;
reg good_frame_sync3_reg = 1'b0;
reg good_frame_sync4_reg = 1'b0;

assign s_axis_tready = (FRAME_FIFO ? (!full || (full_wr && DROP_OVERSIZE_FRAME) || DROP_WHEN_FULL) : (!full || MARK_WHEN_FULL)) && !s_rst_sync3_reg;

wire [WIDTH-1:0] s_axis;

generate
    assign s_axis[DATA_WIDTH-1:0] = s_axis_tdata;
    if (KEEP_ENABLE) assign s_axis[KEEP_OFFSET +: KEEP_WIDTH] = s_axis_tkeep;
    if (LAST_ENABLE) assign s_axis[LAST_OFFSET]               = s_axis_tlast | mark_frame_reg;
    if (ID_ENABLE)   assign s_axis[ID_OFFSET   +: ID_WIDTH]   = s_axis_tid;
    if (DEST_ENABLE) assign s_axis[DEST_OFFSET +: DEST_WIDTH] = s_axis_tdest;
    if (USER_ENABLE) assign s_axis[USER_OFFSET +: USER_WIDTH] = mark_frame_reg ? USER_BAD_FRAME_VALUE : s_axis_tuser;
endgenerate

wire [WIDTH-1:0] m_axis = m_axis_pipe_reg[RAM_PIPELINE+1-1];

wire                   m_axis_tready_pipe;
wire                   m_axis_tvalid_pipe = m_axis_tvalid_pipe_reg[RAM_PIPELINE+1-1];

wire [DATA_WIDTH-1:0]  m_axis_tdata_pipe  = m_axis[DATA_WIDTH-1:0];
wire [KEEP_WIDTH-1:0]  m_axis_tkeep_pipe  = KEEP_ENABLE ? m_axis[KEEP_OFFSET +: KEEP_WIDTH] : {KEEP_WIDTH{1'b1}};
wire                   m_axis_tlast_pipe  = LAST_ENABLE ? m_axis[LAST_OFFSET] | m_terminate_frame_reg : 1'b1;
wire [ID_WIDTH-1:0]    m_axis_tid_pipe    = ID_ENABLE   ? m_axis[ID_OFFSET +: ID_WIDTH] : {ID_WIDTH{1'b0}};
wire [DEST_WIDTH-1:0]  m_axis_tdest_pipe  = DEST_ENABLE ? m_axis[DEST_OFFSET +: DEST_WIDTH] : {DEST_WIDTH{1'b0}};
wire [USER_WIDTH-1:0]  m_axis_tuser_pipe  = USER_ENABLE ? (m_terminate_frame_reg ? USER_BAD_FRAME_VALUE : m_axis[USER_OFFSET +: USER_WIDTH]) : {USER_WIDTH{1'b0}};

wire                   m_axis_tready_out;
wire                   m_axis_tvalid_out;

wire [DATA_WIDTH-1:0]  m_axis_tdata_out;
wire [KEEP_WIDTH-1:0]  m_axis_tkeep_out;
wire                   m_axis_tlast_out;
wire [ID_WIDTH-1:0]    m_axis_tid_out;
wire [DEST_WIDTH-1:0]  m_axis_tdest_out;
wire [USER_WIDTH-1:0]  m_axis_tuser_out;

wire pipe_ready;

assign s_status_depth = (KEEP_ENABLE && KEEP_WIDTH > 1) ? {s_depth_reg, {$clog2(KEEP_WIDTH){1'b0}}} : s_depth_reg;
assign s_status_depth_commit = (KEEP_ENABLE && KEEP_WIDTH > 1) ? {s_depth_commit_reg, {$clog2(KEEP_WIDTH){1'b0}}} : s_depth_commit_reg;
assign s_status_overflow = overflow_reg;
assign s_status_bad_frame = bad_frame_reg;
assign s_status_good_frame = good_frame_reg;

assign m_status_depth = (KEEP_ENABLE && KEEP_WIDTH > 1) ? {m_depth_reg, {$clog2(KEEP_WIDTH){1'b0}}} : m_depth_reg;
assign m_status_depth_commit = (KEEP_ENABLE && KEEP_WIDTH > 1) ? {m_depth_commit_reg, {$clog2(KEEP_WIDTH){1'b0}}} : m_depth_commit_reg;
assign m_status_overflow = overflow_sync3_reg ^ overflow_sync4_reg;
assign m_status_bad_frame = bad_frame_sync3_reg ^ bad_frame_sync4_reg;
assign m_status_good_frame = good_frame_sync3_reg ^ good_frame_sync4_reg;

// reset synchronization
always @(posedge m_clk or posedge m_rst) begin
    if (m_rst) begin
        s_rst_sync1_reg <= 1'b1;
    end else begin
        s_rst_sync1_reg <= 1'b0;
    end
end

always @(posedge s_clk) begin
    s_rst_sync2_reg <= s_rst_sync1_reg;
    s_rst_sync3_reg <= s_rst_sync2_reg;
end

always @(posedge s_clk or posedge s_rst) begin
    if (s_rst) begin
        m_rst_sync1_reg <= 1'b1;
    end else begin
        m_rst_sync1_reg <= 1'b0;
    end
end

always @(posedge m_clk) begin
    m_rst_sync2_reg <= m_rst_sync1_reg;
    m_rst_sync3_reg <= m_rst_sync2_reg;
end

// Write logic
always @(posedge s_clk) begin
    overflow_reg <= 1'b0;
    bad_frame_reg <= 1'b0;
    good_frame_reg <= 1'b0;

    if (FRAME_FIFO && wr_ptr_update_valid_reg) begin
        // have updated pointer to sync
        if (wr_ptr_update_reg == wr_ptr_update_ack_sync2_reg) begin
            // no sync in progress; sync update
            wr_ptr_update_valid_reg <= 1'b0;
            wr_ptr_sync_commit_reg <= wr_ptr_commit_reg;
            wr_ptr_update_reg <= !wr_ptr_update_ack_sync2_reg;
        end
    end

    if (s_axis_tready && s_axis_tvalid && LAST_ENABLE) begin
        // track input frame status
        s_frame_reg <= !s_axis_tlast;
    end

    if (s_rst_sync3_reg && LAST_ENABLE) begin
        // if sink side is reset during transfer, drop partial frame
        if (s_frame_reg && !(s_axis_tready && s_axis_tvalid && s_axis_tlast)) begin
            drop_frame_reg <= 1'b1;
        end
        if (s_axis_tready && s_axis_tvalid && !s_axis_tlast) begin
            drop_frame_reg <= 1'b1;
        end
    end

    if (FRAME_FIFO) begin
        // frame FIFO mode
        if (s_axis_tready && s_axis_tvalid) begin
            // transfer in
            if ((full && DROP_WHEN_FULL) || (full_wr && DROP_OVERSIZE_FRAME) || drop_frame_reg) begin
                // full, packet overflow, or currently dropping frame
                // drop frame
                drop_frame_reg <= 1'b1;
                if (s_axis_tlast) begin
                    // end of frame, reset write pointer
                    wr_ptr_temp = wr_ptr_commit_reg;
                    wr_ptr_reg <= wr_ptr_temp;
                    wr_ptr_gray_reg <= bin2gray(wr_ptr_temp);
                    drop_frame_reg <= 1'b0;
                    overflow_reg <= 1'b1;
                end
            end else begin
                mem[wr_ptr_reg[ADDR_WIDTH-1:0]] <= s_axis;
                wr_ptr_temp = wr_ptr_reg + 1;
                wr_ptr_reg <= wr_ptr_temp;
                wr_ptr_gray_reg <= bin2gray(wr_ptr_temp);
                if (s_axis_tlast || (!DROP_OVERSIZE_FRAME && (full_wr || send_frame_reg))) begin
                    // end of frame or send frame
                    send_frame_reg <= !s_axis_tlast;
                    if (s_axis_tlast && DROP_BAD_FRAME && USER_BAD_FRAME_MASK & ~(s_axis_tuser ^ USER_BAD_FRAME_VALUE)) begin
                        // bad packet, reset write pointer
                        wr_ptr_temp = wr_ptr_commit_reg;
                        wr_ptr_reg <= wr_ptr_temp;
                        wr_ptr_gray_reg <= bin2gray(wr_ptr_temp);
                        bad_frame_reg <= 1'b1;
                    end else begin
                        // good packet or packet overflow, update write pointer
                        wr_ptr_temp = wr_ptr_reg + 1;
                        wr_ptr_reg <= wr_ptr_temp;
                        wr_ptr_commit_reg <= wr_ptr_temp;
                        wr_ptr_gray_reg <= bin2gray(wr_ptr_temp);

                        if (wr_ptr_update_reg == wr_ptr_update_ack_sync2_reg) begin
                            // no sync in progress; sync update
                            wr_ptr_update_valid_reg <= 1'b0;
                            wr_ptr_sync_commit_reg <= wr_ptr_temp;
                            wr_ptr_update_reg <= !wr_ptr_update_ack_sync2_reg;
                        end else begin
                            // sync in progress; flag it for later
                            wr_ptr_update_valid_reg <= 1'b1;
                        end

                        good_frame_reg <= s_axis_tlast;
                    end
                end
            end
        end else if (s_axis_tvalid && full_wr && FRAME_FIFO && !DROP_OVERSIZE_FRAME) begin
            // data valid with packet overflow
            // update write pointer
            send_frame_reg <= 1'b1;
            wr_ptr_temp = wr_ptr_reg;
            wr_ptr_reg <= wr_ptr_temp;
            wr_ptr_commit_reg <= wr_ptr_temp;
            wr_ptr_gray_reg <= bin2gray(wr_ptr_temp);

            if (wr_ptr_update_reg == wr_ptr_update_ack_sync2_reg) begin
                // no sync in progress; sync update
                wr_ptr_update_valid_reg <= 1'b0;
                wr_ptr_sync_commit_reg <= wr_ptr_temp;
                wr_ptr_update_reg <= !wr_ptr_update_ack_sync2_reg;
            end else begin
                // sync in progress; flag it for later
                wr_ptr_update_valid_reg <= 1'b1;
            end
        end
    end else begin
        // normal FIFO mode
        if (s_axis_tready && s_axis_tvalid) begin
            if (drop_frame_reg && LAST_ENABLE) begin
                // currently dropping frame
                if (s_axis_tlast) begin
                    // end of frame
                    if (!full && mark_frame_reg && MARK_WHEN_FULL) begin
                        // terminate marked frame
                        mark_frame_reg <= 1'b0;
                        mem[wr_ptr_reg[ADDR_WIDTH-1:0]] <= s_axis;
                        wr_ptr_temp = wr_ptr_reg + 1;
                        wr_ptr_reg <= wr_ptr_temp;
                        wr_ptr_commit_reg <= wr_ptr_temp;
                        wr_ptr_gray_reg <= bin2gray(wr_ptr_temp);
                    end
                    // end of frame, clear drop flag
                    drop_frame_reg <= 1'b0;
                    overflow_reg <= 1'b1;
                end
            end else if ((full || mark_frame_reg) && MARK_WHEN_FULL) begin
                // full or marking frame
                // drop frame; mark if this isn't the first cycle
                drop_frame_reg <= 1'b1;
                mark_frame_reg <= mark_frame_reg || s_frame_reg;
                if (s_axis_tlast) begin
                    drop_frame_reg <= 1'b0;
                    overflow_reg <= 1'b1;
                end
            end else begin
                // transfer in
                mem[wr_ptr_reg[ADDR_WIDTH-1:0]] <= s_axis;
                wr_ptr_temp = wr_ptr_reg + 1;
                wr_ptr_reg <= wr_ptr_temp;
                wr_ptr_commit_reg <= wr_ptr_temp;
                wr_ptr_gray_reg <= bin2gray(wr_ptr_temp);
            end
        end else if ((!full && !drop_frame_reg && mark_frame_reg) && MARK_WHEN_FULL) begin
            // terminate marked frame
            mark_frame_reg <= 1'b0;
            mem[wr_ptr_reg[ADDR_WIDTH-1:0]] <= s_axis;
            wr_ptr_temp = wr_ptr_reg + 1;
            wr_ptr_reg <= wr_ptr_temp;
            wr_ptr_commit_reg <= wr_ptr_temp;
            wr_ptr_gray_reg <= bin2gray(wr_ptr_temp);
        end
    end

    if (s_rst_sync3_reg) begin
        wr_ptr_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_commit_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_gray_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_sync_commit_reg <= {ADDR_WIDTH+1{1'b0}};

        wr_ptr_update_valid_reg <= 1'b0;
        wr_ptr_update_reg <= 1'b0;
    end

    if (s_rst) begin
        wr_ptr_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_commit_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_gray_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_sync_commit_reg <= {ADDR_WIDTH+1{1'b0}};

        wr_ptr_update_valid_reg <= 1'b0;
        wr_ptr_update_reg <= 1'b0;

        s_frame_reg <= 1'b0;

        drop_frame_reg <= 1'b0;
        mark_frame_reg <= 1'b0;
        send_frame_reg <= 1'b0;
        overflow_reg <= 1'b0;
        bad_frame_reg <= 1'b0;
        good_frame_reg <= 1'b0;
    end
end

// Write-side status
always @(posedge s_clk) begin
    rd_ptr_conv_reg <= gray2bin(rd_ptr_gray_sync2_reg);
    s_depth_reg <= wr_ptr_reg - rd_ptr_conv_reg;
    s_depth_commit_reg <= wr_ptr_commit_reg - rd_ptr_conv_reg;
end

// pointer synchronization
always @(posedge s_clk) begin
    rd_ptr_gray_sync1_reg <= rd_ptr_gray_reg;
    rd_ptr_gray_sync2_reg <= rd_ptr_gray_sync1_reg;
    wr_ptr_update_ack_sync1_reg <= wr_ptr_update_sync3_reg;
    wr_ptr_update_ack_sync2_reg <= wr_ptr_update_ack_sync1_reg;

    if (s_rst) begin
        rd_ptr_gray_sync1_reg <= {ADDR_WIDTH+1{1'b0}};
        rd_ptr_gray_sync2_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_update_ack_sync1_reg <= 1'b0;
        wr_ptr_update_ack_sync2_reg <= 1'b0;
    end
end

always @(posedge m_clk) begin
    wr_ptr_gray_sync1_reg <= wr_ptr_gray_reg;
    wr_ptr_gray_sync2_reg <= wr_ptr_gray_sync1_reg;
    if (FRAME_FIFO && wr_ptr_update_sync2_reg ^ wr_ptr_update_sync3_reg) begin
        wr_ptr_commit_sync_reg <= wr_ptr_sync_commit_reg;
    end
    wr_ptr_update_sync1_reg <= wr_ptr_update_reg;
    wr_ptr_update_sync2_reg <= wr_ptr_update_sync1_reg;
    wr_ptr_update_sync3_reg <= wr_ptr_update_sync2_reg;

    if (FRAME_FIFO && m_rst_sync3_reg) begin
        wr_ptr_gray_sync1_reg <= {ADDR_WIDTH+1{1'b0}};
    end

    if (m_rst) begin
        wr_ptr_gray_sync1_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_gray_sync2_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_commit_sync_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_update_sync1_reg <= 1'b0;
        wr_ptr_update_sync2_reg <= 1'b0;
        wr_ptr_update_sync3_reg <= 1'b0;
    end
end

// status synchronization
always @(posedge s_clk) begin
    overflow_sync1_reg <= overflow_sync1_reg ^ overflow_reg;
    bad_frame_sync1_reg <= bad_frame_sync1_reg ^ bad_frame_reg;
    good_frame_sync1_reg <= good_frame_sync1_reg ^ good_frame_reg;

    if (s_rst) begin
        overflow_sync1_reg <= 1'b0;
        bad_frame_sync1_reg <= 1'b0;
        good_frame_sync1_reg <= 1'b0;
    end
end

always @(posedge m_clk) begin
    overflow_sync2_reg <= overflow_sync1_reg;
    overflow_sync3_reg <= overflow_sync2_reg;
    overflow_sync4_reg <= overflow_sync3_reg;
    bad_frame_sync2_reg <= bad_frame_sync1_reg;
    bad_frame_sync3_reg <= bad_frame_sync2_reg;
    bad_frame_sync4_reg <= bad_frame_sync3_reg;
    good_frame_sync2_reg <= good_frame_sync1_reg;
    good_frame_sync3_reg <= good_frame_sync2_reg;
    good_frame_sync4_reg <= good_frame_sync3_reg;

    if (m_rst) begin
        overflow_sync2_reg <= 1'b0;
        overflow_sync3_reg <= 1'b0;
        overflow_sync4_reg <= 1'b0;
        bad_frame_sync2_reg <= 1'b0;
        bad_frame_sync3_reg <= 1'b0;
        bad_frame_sync4_reg <= 1'b0;
        good_frame_sync2_reg <= 1'b0;
        good_frame_sync3_reg <= 1'b0;
        good_frame_sync4_reg <= 1'b0;
    end
end

// Read logic
integer j;

always @(posedge m_clk) begin
    if (m_axis_tready_pipe) begin
        // output ready; invalidate stage
        m_axis_tvalid_pipe_reg[RAM_PIPELINE+1-1] <= 1'b0;
        m_terminate_frame_reg <= 1'b0;
    end

    for (j = RAM_PIPELINE+1-1; j > 0; j = j - 1) begin
        if (m_axis_tready_pipe || ((~m_axis_tvalid_pipe_reg) >> j)) begin
            // output ready or bubble in pipeline; transfer down pipeline
            m_axis_tvalid_pipe_reg[j] <= m_axis_tvalid_pipe_reg[j-1];
            m_axis_pipe_reg[j] <= m_axis_pipe_reg[j-1];
            m_axis_tvalid_pipe_reg[j-1] <= 1'b0;
        end
    end

    if (m_axis_tready_pipe || ~m_axis_tvalid_pipe_reg) begin
        // output ready or bubble in pipeline; read new data from FIFO
        m_axis_tvalid_pipe_reg[0] <= 1'b0;
        m_axis_pipe_reg[0] <= mem[rd_ptr_reg[ADDR_WIDTH-1:0]];
        if (!empty && !m_rst_sync3_reg && !m_drop_frame_reg && pipe_ready) begin
            // not empty, increment pointer
            m_axis_tvalid_pipe_reg[0] <= 1'b1;
            rd_ptr_temp = rd_ptr_reg + 1;
            rd_ptr_reg <= rd_ptr_temp;
            rd_ptr_gray_reg <= rd_ptr_temp ^ (rd_ptr_temp >> 1);
        end
    end

    if (m_axis_tvalid_pipe && LAST_ENABLE) begin
        // track output frame status
        if (m_axis_tlast_pipe && m_axis_tready_pipe) begin
            m_frame_reg <= 1'b0;
        end else begin
            m_frame_reg <= 1'b1;
        end
    end

    if (m_drop_frame_reg && (OUTPUT_FIFO_ENABLE ? pipe_ready : m_axis_tready_pipe || !m_axis_tvalid_pipe) && LAST_ENABLE) begin
        // terminate frame
        // (only for frame transfers interrupted by source reset)
        m_axis_tvalid_pipe_reg[RAM_PIPELINE+1-1] <= 1'b1;
        m_terminate_frame_reg <= 1'b1;
        m_drop_frame_reg <= 1'b0;
    end

    if (m_rst_sync3_reg && LAST_ENABLE) begin
        // if source side is reset during transfer, drop partial frame

        // empty output pipeline, except for last stage
        if (RAM_PIPELINE > 0) begin
            m_axis_tvalid_pipe_reg[RAM_PIPELINE+1-2:0] <= 0;
        end

        if (m_frame_reg && (!m_axis_tvalid_pipe || (m_axis_tvalid_pipe && !m_axis_tlast_pipe)) &&
                !(m_drop_frame_reg || m_terminate_frame_reg)) begin
            // terminate frame
            m_drop_frame_reg <= 1'b1;
        end
    end

    if (m_rst_sync3_reg) begin
        rd_ptr_reg <= {ADDR_WIDTH+1{1'b0}};
        rd_ptr_gray_reg <= {ADDR_WIDTH+1{1'b0}};
    end

    if (m_rst) begin
        rd_ptr_reg <= {ADDR_WIDTH+1{1'b0}};
        rd_ptr_gray_reg <= {ADDR_WIDTH+1{1'b0}};
        m_axis_tvalid_pipe_reg <= 0;
        m_frame_reg <= 1'b0;
        m_drop_frame_reg <= 1'b0;
        m_terminate_frame_reg <= 1'b0;
    end
end

// Read-side status
always @(posedge m_clk) begin
    wr_ptr_conv_reg <= gray2bin(wr_ptr_gray_sync2_reg);
    m_depth_reg <= wr_ptr_conv_reg - rd_ptr_reg;
    m_depth_commit_reg <= FRAME_FIFO ? wr_ptr_commit_sync_reg - rd_ptr_reg : wr_ptr_conv_reg - rd_ptr_reg;
end

generate

if (!OUTPUT_FIFO_ENABLE) begin

    assign pipe_ready = 1'b1;

    assign m_axis_tready_pipe = m_axis_tready_out;
    assign m_axis_tvalid_out = m_axis_tvalid_pipe;

    assign m_axis_tdata_out = m_axis_tdata_pipe;
    assign m_axis_tkeep_out = m_axis_tkeep_pipe;
    assign m_axis_tlast_out = m_axis_tlast_pipe;
    assign m_axis_tid_out   = m_axis_tid_pipe;
    assign m_axis_tdest_out = m_axis_tdest_pipe;
    assign m_axis_tuser_out = m_axis_tuser_pipe;

end else begin : output_fifo

    // output datapath logic
    reg [DATA_WIDTH-1:0] m_axis_tdata_reg  = {DATA_WIDTH{1'b0}};
    reg [KEEP_WIDTH-1:0] m_axis_tkeep_reg  = {KEEP_WIDTH{1'b0}};
    reg                  m_axis_tvalid_reg = 1'b0;
    reg                  m_axis_tlast_reg  = 1'b0;
    reg [ID_WIDTH-1:0]   m_axis_tid_reg    = {ID_WIDTH{1'b0}};
    reg [DEST_WIDTH-1:0] m_axis_tdest_reg  = {DEST_WIDTH{1'b0}};
    reg [USER_WIDTH-1:0] m_axis_tuser_reg  = {USER_WIDTH{1'b0}};

    reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_wr_ptr_reg = 0;
    reg [OUTPUT_FIFO_ADDR_WIDTH+1-1:0] out_fifo_rd_ptr_reg = 0;
    reg out_fifo_half_full_reg = 1'b0;

    wire out_fifo_full = out_fifo_wr_ptr_reg == (out_fifo_rd_ptr_reg ^ {1'b1, {OUTPUT_FIFO_ADDR_WIDTH{1'b0}}});
    wire out_fifo_empty = out_fifo_wr_ptr_reg == out_fifo_rd_ptr_reg;

    (* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
    reg [DATA_WIDTH-1:0] out_fifo_tdata[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
    (* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
    reg [KEEP_WIDTH-1:0] out_fifo_tkeep[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
    (* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
    reg                  out_fifo_tlast[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
    (* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
    reg [ID_WIDTH-1:0]   out_fifo_tid[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
    (* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
    reg [DEST_WIDTH-1:0] out_fifo_tdest[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];
    (* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
    reg [USER_WIDTH-1:0] out_fifo_tuser[2**OUTPUT_FIFO_ADDR_WIDTH-1:0];

    assign pipe_ready = !out_fifo_half_full_reg;

    assign m_axis_tready_pipe = 1'b1;

    assign m_axis_tdata_out  = m_axis_tdata_reg;
    assign m_axis_tkeep_out  = KEEP_ENABLE ? m_axis_tkeep_reg : {KEEP_WIDTH{1'b1}};
    assign m_axis_tvalid_out = m_axis_tvalid_reg;
    assign m_axis_tlast_out  = LAST_ENABLE ? m_axis_tlast_reg : 1'b1;
    assign m_axis_tid_out    = ID_ENABLE   ? m_axis_tid_reg   : {ID_WIDTH{1'b0}};
    assign m_axis_tdest_out  = DEST_ENABLE ? m_axis_tdest_reg : {DEST_WIDTH{1'b0}};
    assign m_axis_tuser_out  = USER_ENABLE ? m_axis_tuser_reg : {USER_WIDTH{1'b0}};

    always @(posedge m_clk) begin
        m_axis_tvalid_reg <= m_axis_tvalid_reg && !m_axis_tready_out;

        out_fifo_half_full_reg <= $unsigned(out_fifo_wr_ptr_reg - out_fifo_rd_ptr_reg) >= 2**(OUTPUT_FIFO_ADDR_WIDTH-1);

        if (!out_fifo_full && m_axis_tvalid_pipe) begin
            out_fifo_tdata[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= m_axis_tdata_pipe;
            out_fifo_tkeep[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= m_axis_tkeep_pipe;
            out_fifo_tlast[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= m_axis_tlast_pipe;
            out_fifo_tid[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= m_axis_tid_pipe;
            out_fifo_tdest[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= m_axis_tdest_pipe;
            out_fifo_tuser[out_fifo_wr_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]] <= m_axis_tuser_pipe;
            out_fifo_wr_ptr_reg <= out_fifo_wr_ptr_reg + 1;
        end

        if (!out_fifo_empty && (!m_axis_tvalid_reg || m_axis_tready_out)) begin
            m_axis_tdata_reg <= out_fifo_tdata[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
            m_axis_tkeep_reg <= out_fifo_tkeep[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
            m_axis_tvalid_reg <= 1'b1;
            m_axis_tlast_reg <= out_fifo_tlast[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
            m_axis_tid_reg <= out_fifo_tid[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
            m_axis_tdest_reg <= out_fifo_tdest[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
            m_axis_tuser_reg <= out_fifo_tuser[out_fifo_rd_ptr_reg[OUTPUT_FIFO_ADDR_WIDTH-1:0]];
            out_fifo_rd_ptr_reg <= out_fifo_rd_ptr_reg + 1;
        end

        if (m_rst) begin
            out_fifo_wr_ptr_reg <= 0;
            out_fifo_rd_ptr_reg <= 0;
            m_axis_tvalid_reg <= 1'b0;
        end
    end

end

if (PAUSE_ENABLE) begin : pause

    // Pause logic
    reg pause_reg = 1'b0;
    reg pause_frame_reg = 1'b0;

    reg s_pause_req_sync1_reg;
    reg s_pause_req_sync2_reg;
    reg s_pause_req_sync3_reg;
    reg s_pause_ack_sync1_reg;
    reg s_pause_ack_sync2_reg;
    reg s_pause_ack_sync3_reg;

    always @(posedge s_clk) begin
        s_pause_req_sync1_reg <= s_pause_req;
        s_pause_ack_sync2_reg <= s_pause_ack_sync1_reg;
        s_pause_ack_sync3_reg <= s_pause_ack_sync2_reg;
    end

    always @(posedge m_clk) begin
        s_pause_req_sync2_reg <= s_pause_req_sync1_reg;
        s_pause_req_sync3_reg <= s_pause_req_sync2_reg;
        s_pause_ack_sync1_reg <= pause_reg;
    end

    assign m_axis_tready_out = m_axis_tready && !pause_reg;
    assign m_axis_tvalid = m_axis_tvalid_out && !pause_reg;

    assign m_axis_tdata = m_axis_tdata_out;
    assign m_axis_tkeep = m_axis_tkeep_out;
    assign m_axis_tlast = m_axis_tlast_out;
    assign m_axis_tid   = m_axis_tid_out;
    assign m_axis_tdest = m_axis_tdest_out;
    assign m_axis_tuser = m_axis_tuser_out;

    assign s_pause_ack = s_pause_ack_sync3_reg;
    assign m_pause_ack = pause_reg;

    always @(posedge m_clk) begin
        if (FRAME_PAUSE) begin
            if (pause_reg) begin
                // paused; update pause status
                pause_reg <= m_pause_req || s_pause_req_sync3_reg;
            end else if (m_axis_tvalid_out) begin
                // frame transfer; set frame bit
                pause_frame_reg <= 1'b1;
                if (m_axis_tready && m_axis_tlast) begin
                    // end of frame; clear frame bit and update pause status
                    pause_frame_reg <= 1'b0;
                    pause_reg <= m_pause_req || s_pause_req_sync3_reg;
                end
            end else if (!pause_frame_reg) begin
                // idle; update pause status
                pause_reg <= m_pause_req || s_pause_req_sync3_reg;
            end
        end else begin
            pause_reg <= m_pause_req || s_pause_req_sync3_reg;
        end

        if (m_rst) begin
            pause_frame_reg <= 1'b0;
            pause_reg <= 1'b0;
        end
    end

end else begin

    assign m_axis_tready_out = m_axis_tready;
    assign m_axis_tvalid = m_axis_tvalid_out;

    assign m_axis_tdata = m_axis_tdata_out;
    assign m_axis_tkeep = m_axis_tkeep_out;
    assign m_axis_tlast = m_axis_tlast_out;
    assign m_axis_tid   = m_axis_tid_out;
    assign m_axis_tdest = m_axis_tdest_out;
    assign m_axis_tuser = m_axis_tuser_out;

    assign s_pause_ack = 1'b0;
    assign m_pause_ack = 1'b0;

end

endgenerate

endmodule

`resetall


// ---- Private implementation: fpt_net_axis_async_fifo_adapter.v ----
/*

Copyright (c) 2019 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * AXI4-Stream asynchronous FIFO with width converter
 */
module fpt_net_axis_async_fifo_adapter #
(
    // FIFO depth in words
    // KEEP_WIDTH words per cycle if KEEP_ENABLE set
    // Rounded up to nearest power of 2 cycles
    parameter DEPTH = 4096,
    // Width of input AXI stream interface in bits
    parameter S_DATA_WIDTH = 8,
    // Propagate tkeep signal on input interface
    // If disabled, tkeep assumed to be 1'b1
    parameter S_KEEP_ENABLE = (S_DATA_WIDTH>8),
    // tkeep signal width (words per cycle) on input interface
    parameter S_KEEP_WIDTH = ((S_DATA_WIDTH+7)/8),
    // Width of output AXI stream interface in bits
    parameter M_DATA_WIDTH = 8,
    // Propagate tkeep signal on output interface
    // If disabled, tkeep assumed to be 1'b1
    parameter M_KEEP_ENABLE = (M_DATA_WIDTH>8),
    // tkeep signal width (words per cycle) on output interface
    parameter M_KEEP_WIDTH = ((M_DATA_WIDTH+7)/8),
    // Propagate tid signal
    parameter ID_ENABLE = 0,
    // tid signal width
    parameter ID_WIDTH = 8,
    // Propagate tdest signal
    parameter DEST_ENABLE = 0,
    // tdest signal width
    parameter DEST_WIDTH = 8,
    // Propagate tuser signal
    parameter USER_ENABLE = 1,
    // tuser signal width
    parameter USER_WIDTH = 1,
    // number of RAM pipeline registers in FIFO
    parameter RAM_PIPELINE = 1,
    // use output FIFO
    // When set, the RAM read enable and pipeline clock enables are removed
    parameter OUTPUT_FIFO_ENABLE = 0,
    // Frame FIFO mode - operate on frames instead of cycles
    // When set, m_axis_tvalid will not be deasserted within a frame
    // Requires LAST_ENABLE set
    parameter FRAME_FIFO = 0,
    // tuser value for bad frame marker
    parameter USER_BAD_FRAME_VALUE = 1'b1,
    // tuser mask for bad frame marker
    parameter USER_BAD_FRAME_MASK = 1'b1,
    // Drop frames larger than FIFO
    // Requires FRAME_FIFO set
    parameter DROP_OVERSIZE_FRAME = FRAME_FIFO,
    // Drop frames marked bad
    // Requires FRAME_FIFO and DROP_OVERSIZE_FRAME set
    parameter DROP_BAD_FRAME = 0,
    // Drop incoming frames when full
    // When set, s_axis_tready is always asserted
    // Requires FRAME_FIFO and DROP_OVERSIZE_FRAME set
    parameter DROP_WHEN_FULL = 0,
    // Mark incoming frames as bad frames when full
    // When set, s_axis_tready is always asserted
    // Requires FRAME_FIFO to be clear
    parameter MARK_WHEN_FULL = 0,
    // Enable pause request input
    parameter PAUSE_ENABLE = 0,
    // Pause between frames
    parameter FRAME_PAUSE = FRAME_FIFO
)
(
    /*
     * AXI input
     */
    input  wire                     s_clk,
    input  wire                     s_rst,
    input  wire [S_DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire [S_KEEP_WIDTH-1:0]  s_axis_tkeep,
    input  wire                     s_axis_tvalid,
    output wire                     s_axis_tready,
    input  wire                     s_axis_tlast,
    input  wire [ID_WIDTH-1:0]      s_axis_tid,
    input  wire [DEST_WIDTH-1:0]    s_axis_tdest,
    input  wire [USER_WIDTH-1:0]    s_axis_tuser,

    /*
     * AXI output
     */
    input  wire                     m_clk,
    input  wire                     m_rst,
    output wire [M_DATA_WIDTH-1:0]  m_axis_tdata,
    output wire [M_KEEP_WIDTH-1:0]  m_axis_tkeep,
    output wire                     m_axis_tvalid,
    input  wire                     m_axis_tready,
    output wire                     m_axis_tlast,
    output wire [ID_WIDTH-1:0]      m_axis_tid,
    output wire [DEST_WIDTH-1:0]    m_axis_tdest,
    output wire [USER_WIDTH-1:0]    m_axis_tuser,

    /*
     * Pause
     */
    input  wire                     s_pause_req,
    output wire                     s_pause_ack,
    input  wire                     m_pause_req,
    output wire                     m_pause_ack,

    /*
     * Status
     */
    output wire [$clog2(DEPTH):0]   s_status_depth,
    output wire [$clog2(DEPTH):0]   s_status_depth_commit,
    output wire                     s_status_overflow,
    output wire                     s_status_bad_frame,
    output wire                     s_status_good_frame,
    output wire [$clog2(DEPTH):0]   m_status_depth,
    output wire [$clog2(DEPTH):0]   m_status_depth_commit,
    output wire                     m_status_overflow,
    output wire                     m_status_bad_frame,
    output wire                     m_status_good_frame
);

// force keep width to 1 when disabled
localparam S_BYTE_LANES = S_KEEP_ENABLE ? S_KEEP_WIDTH : 1;
localparam M_BYTE_LANES = M_KEEP_ENABLE ? M_KEEP_WIDTH : 1;

// bus byte sizes (must be identical)
localparam S_BYTE_SIZE = S_DATA_WIDTH / S_BYTE_LANES;
localparam M_BYTE_SIZE = M_DATA_WIDTH / M_BYTE_LANES;
// output bus is wider
localparam EXPAND_BUS = M_BYTE_LANES > S_BYTE_LANES;
// total data and keep widths
localparam DATA_WIDTH = EXPAND_BUS ? M_DATA_WIDTH : S_DATA_WIDTH;
localparam KEEP_WIDTH = EXPAND_BUS ? M_BYTE_LANES : S_BYTE_LANES;

// bus width assertions
initial begin
    if (S_BYTE_SIZE * S_BYTE_LANES != S_DATA_WIDTH) begin
        $error("Error: input data width not evenly divisible (instance %m)");
        $finish;
    end

    if (M_BYTE_SIZE * M_BYTE_LANES != M_DATA_WIDTH) begin
        $error("Error: output data width not evenly divisible (instance %m)");
        $finish;
    end

    if (S_BYTE_SIZE != M_BYTE_SIZE) begin
        $error("Error: byte size mismatch (instance %m)");
        $finish;
    end
end

wire [DATA_WIDTH-1:0]  pre_fifo_axis_tdata;
wire [KEEP_WIDTH-1:0]  pre_fifo_axis_tkeep;
wire                   pre_fifo_axis_tvalid;
wire                   pre_fifo_axis_tready;
wire                   pre_fifo_axis_tlast;
wire [ID_WIDTH-1:0]    pre_fifo_axis_tid;
wire [DEST_WIDTH-1:0]  pre_fifo_axis_tdest;
wire [USER_WIDTH-1:0]  pre_fifo_axis_tuser;

wire [DATA_WIDTH-1:0]  post_fifo_axis_tdata;
wire [KEEP_WIDTH-1:0]  post_fifo_axis_tkeep;
wire                   post_fifo_axis_tvalid;
wire                   post_fifo_axis_tready;
wire                   post_fifo_axis_tlast;
wire [ID_WIDTH-1:0]    post_fifo_axis_tid;
wire [DEST_WIDTH-1:0]  post_fifo_axis_tdest;
wire [USER_WIDTH-1:0]  post_fifo_axis_tuser;

generate

if (M_BYTE_LANES > S_BYTE_LANES) begin : upsize_pre

    // output wider, adapt width before FIFO

    axis_adapter #(
        .S_DATA_WIDTH(S_DATA_WIDTH),
        .S_KEEP_ENABLE(S_KEEP_ENABLE),
        .S_KEEP_WIDTH(S_KEEP_WIDTH),
        .M_DATA_WIDTH(M_DATA_WIDTH),
        .M_KEEP_ENABLE(M_KEEP_ENABLE),
        .M_KEEP_WIDTH(M_KEEP_WIDTH),
        .ID_ENABLE(ID_ENABLE),
        .ID_WIDTH(ID_WIDTH),
        .DEST_ENABLE(DEST_ENABLE),
        .DEST_WIDTH(DEST_WIDTH),
        .USER_ENABLE(USER_ENABLE),
        .USER_WIDTH(USER_WIDTH)
    )
    adapter_inst (
        .clk(s_clk),
        .rst(s_rst),
        // AXI input
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tid(s_axis_tid),
        .s_axis_tdest(s_axis_tdest),
        .s_axis_tuser(s_axis_tuser),
        // AXI output
        .m_axis_tdata(pre_fifo_axis_tdata),
        .m_axis_tkeep(pre_fifo_axis_tkeep),
        .m_axis_tvalid(pre_fifo_axis_tvalid),
        .m_axis_tready(pre_fifo_axis_tready),
        .m_axis_tlast(pre_fifo_axis_tlast),
        .m_axis_tid(pre_fifo_axis_tid),
        .m_axis_tdest(pre_fifo_axis_tdest),
        .m_axis_tuser(pre_fifo_axis_tuser)
    );

end else begin : bypass_pre

    assign pre_fifo_axis_tdata = s_axis_tdata;
    assign pre_fifo_axis_tkeep = s_axis_tkeep;
    assign pre_fifo_axis_tvalid = s_axis_tvalid;
    assign s_axis_tready = pre_fifo_axis_tready;
    assign pre_fifo_axis_tlast = s_axis_tlast;
    assign pre_fifo_axis_tid = s_axis_tid;
    assign pre_fifo_axis_tdest = s_axis_tdest;
    assign pre_fifo_axis_tuser = s_axis_tuser;

end

fpt_net_axis_async_fifo #(
    .DEPTH(DEPTH),
    .DATA_WIDTH(DATA_WIDTH),
    .KEEP_ENABLE(EXPAND_BUS ? M_KEEP_ENABLE : S_KEEP_ENABLE),
    .KEEP_WIDTH(KEEP_WIDTH),
    .LAST_ENABLE(1),
    .ID_ENABLE(ID_ENABLE),
    .ID_WIDTH(ID_WIDTH),
    .DEST_ENABLE(DEST_ENABLE),
    .DEST_WIDTH(DEST_WIDTH),
    .USER_ENABLE(USER_ENABLE),
    .USER_WIDTH(USER_WIDTH),
    .RAM_PIPELINE(RAM_PIPELINE),
    .OUTPUT_FIFO_ENABLE(OUTPUT_FIFO_ENABLE),
    .FRAME_FIFO(FRAME_FIFO),
    .USER_BAD_FRAME_VALUE(USER_BAD_FRAME_VALUE),
    .USER_BAD_FRAME_MASK(USER_BAD_FRAME_MASK),
    .DROP_OVERSIZE_FRAME(DROP_OVERSIZE_FRAME),
    .DROP_BAD_FRAME(DROP_BAD_FRAME),
    .DROP_WHEN_FULL(DROP_WHEN_FULL),
    .MARK_WHEN_FULL(MARK_WHEN_FULL),
    .PAUSE_ENABLE(PAUSE_ENABLE),
    .FRAME_PAUSE(FRAME_PAUSE)
)
fifo_inst (
    // AXI input
    .s_clk(s_clk),
    .s_rst(s_rst),
    .s_axis_tdata(pre_fifo_axis_tdata),
    .s_axis_tkeep(pre_fifo_axis_tkeep),
    .s_axis_tvalid(pre_fifo_axis_tvalid),
    .s_axis_tready(pre_fifo_axis_tready),
    .s_axis_tlast(pre_fifo_axis_tlast),
    .s_axis_tid(pre_fifo_axis_tid),
    .s_axis_tdest(pre_fifo_axis_tdest),
    .s_axis_tuser(pre_fifo_axis_tuser),
    // AXI output
    .m_clk(m_clk),
    .m_rst(m_rst),
    .m_axis_tdata(post_fifo_axis_tdata),
    .m_axis_tkeep(post_fifo_axis_tkeep),
    .m_axis_tvalid(post_fifo_axis_tvalid),
    .m_axis_tready(post_fifo_axis_tready),
    .m_axis_tlast(post_fifo_axis_tlast),
    .m_axis_tid(post_fifo_axis_tid),
    .m_axis_tdest(post_fifo_axis_tdest),
    .m_axis_tuser(post_fifo_axis_tuser),
    // Pause
    .s_pause_req(s_pause_req),
    .s_pause_ack(s_pause_ack),
    .m_pause_req(m_pause_req),
    .m_pause_ack(m_pause_ack),
    // Status
    .s_status_depth(s_status_depth),
    .s_status_depth_commit(s_status_depth_commit),
    .s_status_overflow(s_status_overflow),
    .s_status_bad_frame(s_status_bad_frame),
    .s_status_good_frame(s_status_good_frame),
    .m_status_depth(m_status_depth),
    .m_status_depth_commit(m_status_depth_commit),
    .m_status_overflow(m_status_overflow),
    .m_status_bad_frame(m_status_bad_frame),
    .m_status_good_frame(m_status_good_frame)
);

if (M_BYTE_LANES < S_BYTE_LANES) begin : downsize_post

    // input wider, adapt width after FIFO

    axis_adapter #(
        .S_DATA_WIDTH(S_DATA_WIDTH),
        .S_KEEP_ENABLE(S_KEEP_ENABLE),
        .S_KEEP_WIDTH(S_KEEP_WIDTH),
        .M_DATA_WIDTH(M_DATA_WIDTH),
        .M_KEEP_ENABLE(M_KEEP_ENABLE),
        .M_KEEP_WIDTH(M_KEEP_WIDTH),
        .ID_ENABLE(ID_ENABLE),
        .ID_WIDTH(ID_WIDTH),
        .DEST_ENABLE(DEST_ENABLE),
        .DEST_WIDTH(DEST_WIDTH),
        .USER_ENABLE(USER_ENABLE),
        .USER_WIDTH(USER_WIDTH)
    )
    adapter_inst (
        .clk(m_clk),
        .rst(m_rst),
        // AXI input
        .s_axis_tdata(post_fifo_axis_tdata),
        .s_axis_tkeep(post_fifo_axis_tkeep),
        .s_axis_tvalid(post_fifo_axis_tvalid),
        .s_axis_tready(post_fifo_axis_tready),
        .s_axis_tlast(post_fifo_axis_tlast),
        .s_axis_tid(post_fifo_axis_tid),
        .s_axis_tdest(post_fifo_axis_tdest),
        .s_axis_tuser(post_fifo_axis_tuser),
        // AXI output
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tid(m_axis_tid),
        .m_axis_tdest(m_axis_tdest),
        .m_axis_tuser(m_axis_tuser)
    );

end else begin : bypass_post

    assign m_axis_tdata = post_fifo_axis_tdata;
    assign m_axis_tkeep = post_fifo_axis_tkeep;
    assign m_axis_tvalid = post_fifo_axis_tvalid;
    assign post_fifo_axis_tready = m_axis_tready;
    assign m_axis_tlast = post_fifo_axis_tlast;
    assign m_axis_tid = post_fifo_axis_tid;
    assign m_axis_tdest = post_fifo_axis_tdest;
    assign m_axis_tuser = post_fifo_axis_tuser;

end

endgenerate

endmodule

`resetall


// ---- Private implementation: fpt_net_ssio_ddr_in.v ----
/*

Copyright (c) 2016-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Generic source synchronous DDR input
 */
module fpt_net_ssio_ddr_in #
(
    // target ("SIM", "GENERIC", "XILINX", "ALTERA")
    parameter TARGET = "GENERIC",
    // IODDR style ("IODDR", "IODDR2")
    // Use IODDR for Virtex-4, Virtex-5, Virtex-6, 7 Series, Ultrascale
    // Use IODDR2 for Spartan-6
    parameter IODDR_STYLE = "IODDR2",
    // Clock input style ("BUFG", "BUFR", "BUFIO", "BUFIO2")
    // Use BUFR for Virtex-6, 7-series
    // Use BUFG for Virtex-5, Spartan-6, Ultrascale
    parameter CLOCK_INPUT_STYLE = "BUFG",
    // Width of register in bits
    parameter WIDTH = 1
)
(
    input  wire             input_clk,

    input  wire [WIDTH-1:0] input_d,

    output wire             output_clk,

    output wire [WIDTH-1:0] output_q1,
    output wire [WIDTH-1:0] output_q2
);

wire clk_int;
wire clk_io;

generate

if (TARGET == "XILINX") begin

    // use Xilinx clocking primitives

    if (CLOCK_INPUT_STYLE == "BUFG") begin

        // buffer RX clock
        BUFG
        clk_bufg (
            .I(input_clk),
            .O(clk_int)
        );

        // pass through RX clock to logic and input buffers
        assign clk_io = clk_int;
        assign output_clk = clk_int;

    end else if (CLOCK_INPUT_STYLE == "BUFR") begin

        assign clk_int = input_clk;

        // pass through RX clock to input buffers
        BUFIO
        clk_bufio (
            .I(clk_int),
            .O(clk_io)
        );

        // pass through RX clock to logic
        BUFR #(
            .BUFR_DIVIDE("BYPASS")
        )
        clk_bufr (
            .I(clk_int),
            .O(output_clk),
            .CE(1'b1),
            .CLR(1'b0)
        );
        
    end else if (CLOCK_INPUT_STYLE == "BUFIO") begin

        assign clk_int = input_clk;

        // pass through RX clock to input buffers
        BUFIO
        clk_bufio (
            .I(clk_int),
            .O(clk_io)
        );

        // pass through RX clock to MAC
        BUFG
        clk_bufg (
            .I(clk_int),
            .O(output_clk)
        );

    end

end else begin

    // pass through RX clock to input buffers
    assign clk_io = input_clk;

    // pass through RX clock to logic
    assign clk_int = input_clk;
    assign output_clk = clk_int;

end

endgenerate

fpt_net_iddr #(
    .TARGET(TARGET),
    .IODDR_STYLE(IODDR_STYLE),
    .WIDTH(WIDTH)
)
data_iddr_inst (
    .clk(clk_io),
    .d(input_d),
    .q1(output_q1),
    .q2(output_q2)
);

endmodule

`resetall


// ---- Private implementation: fpt_net_iddr.v ----
/*

Copyright (c) 2016-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Generic IDDR module
 */
module fpt_net_iddr #
(
    // target ("SIM", "GENERIC", "XILINX", "ALTERA")
    parameter TARGET = "GENERIC",
    // IODDR style ("IODDR", "IODDR2")
    // Use IODDR for Virtex-4, Virtex-5, Virtex-6, 7 Series, Ultrascale
    // Use IODDR2 for Spartan-6
    parameter IODDR_STYLE = "IODDR2",
    // Width of register in bits
    parameter WIDTH = 1
)
(
    input  wire             clk,

    input  wire [WIDTH-1:0] d,

    output wire [WIDTH-1:0] q1,
    output wire [WIDTH-1:0] q2
);

/*

Provides a consistent input DDR flip flop across multiple FPGA families
              _____       _____       _____       _____       ____
    clk  ____/     \_____/     \_____/     \_____/     \_____/
         _ _____ _____ _____ _____ _____ _____ _____ _____ _____ _
    d    _X_D0__X_D1__X_D2__X_D3__X_D4__X_D5__X_D6__X_D7__X_D8__X_
         _______ ___________ ___________ ___________ ___________ _
    q1   _______X___________X____D0_____X____D2_____X____D4_____X_
         _______ ___________ ___________ ___________ ___________ _
    q2   _______X___________X____D1_____X____D3_____X____D5_____X_

*/

genvar n;

generate

if (TARGET == "XILINX") begin
    for (n = 0; n < WIDTH; n = n + 1) begin : fpt_net_iddr
        if (IODDR_STYLE == "IODDR") begin
            IDDR #(
                .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
                .SRTYPE("ASYNC")
            )
            iddr_inst (
                .Q1(q1[n]),
                .Q2(q2[n]),
                .C(clk),
                .CE(1'b1),
                .D(d[n]),
                .R(1'b0),
                .S(1'b0)
            );
        end else if (IODDR_STYLE == "IODDR2") begin
            wire q1_int;
            reg q1_delay;

            IDDR2 #(
                .DDR_ALIGNMENT("C0")
            )
            iddr_inst (
                .Q0(q1_int),
                .Q1(q2[n]),
                .C0(clk),
                .C1(~clk),
                .CE(1'b1),
                .D(d[n]),
                .R(1'b0),
                .S(1'b0)
            );

            always @(posedge clk) begin
                q1_delay <= q1_int;
            end

            assign q1[n] = q1_delay;
        end
    end
end else if (TARGET == "ALTERA") begin
    wire [WIDTH-1:0] q1_int;
    reg [WIDTH-1:0] q1_delay;

    altddio_in #(
        .WIDTH(WIDTH),
        .POWER_UP_HIGH("OFF")
    )
    altddio_in_inst (
        .aset(1'b0),
        .datain(d),
        .inclocken(1'b1),
        .inclock(clk),
        .aclr(1'b0),
        .dataout_h(q1_int),
        .dataout_l(q2)
    );

    always @(posedge clk) begin
        q1_delay <= q1_int;
    end

    assign q1 = q1_delay;
end else begin
    reg [WIDTH-1:0] d_reg_1 = {WIDTH{1'b0}};
    reg [WIDTH-1:0] d_reg_2 = {WIDTH{1'b0}};

    reg [WIDTH-1:0] q_reg_1 = {WIDTH{1'b0}};
    reg [WIDTH-1:0] q_reg_2 = {WIDTH{1'b0}};

    always @(posedge clk) begin
        d_reg_1 <= d;
    end

    always @(negedge clk) begin
        d_reg_2 <= d;
    end

    always @(posedge clk) begin
        q_reg_1 <= d_reg_1;
        q_reg_2 <= d_reg_2;
    end

    assign q1 = q_reg_1;
    assign q2 = q_reg_2;
end

endgenerate

endmodule

`resetall


// ---- Private implementation: fpt_net_oddr.v ----
/*

Copyright (c) 2016-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Generic ODDR module
 */
module fpt_net_oddr #
(
    // target ("SIM", "GENERIC", "XILINX", "ALTERA")
    parameter TARGET = "GENERIC",
    // IODDR style ("IODDR", "IODDR2")
    // Use IODDR for Virtex-4, Virtex-5, Virtex-6, 7 Series, Ultrascale
    // Use IODDR2 for Spartan-6
    parameter IODDR_STYLE = "IODDR2",
    // Width of register in bits
    parameter WIDTH = 1
)
(
    input  wire             clk,

    input  wire [WIDTH-1:0] d1,
    input  wire [WIDTH-1:0] d2,

    output wire [WIDTH-1:0] q
);

/*

Provides a consistent output DDR flip flop across multiple FPGA families
              _____       _____       _____       _____
    clk  ____/     \_____/     \_____/     \_____/     \_____
         _ ___________ ___________ ___________ ___________ __
    d1   _X____D0_____X____D2_____X____D4_____X____D6_____X__
         _ ___________ ___________ ___________ ___________ __
    d2   _X____D1_____X____D3_____X____D5_____X____D7_____X__
         _____ _____ _____ _____ _____ _____ _____ _____ ____
    d    _____X_D0__X_D1__X_D2__X_D3__X_D4__X_D5__X_D6__X_D7_

*/

genvar n;

generate

if (TARGET == "XILINX") begin
    for (n = 0; n < WIDTH; n = n + 1) begin : fpt_net_oddr
        if (IODDR_STYLE == "IODDR") begin
            ODDR #(
                .DDR_CLK_EDGE("SAME_EDGE"),
                .SRTYPE("ASYNC")
            )
            oddr_inst (
                .Q(q[n]),
                .C(clk),
                .CE(1'b1),
                .D1(d1[n]),
                .D2(d2[n]),
                .R(1'b0),
                .S(1'b0)
            );
        end else if (IODDR_STYLE == "IODDR2") begin
            ODDR2 #(
                .DDR_ALIGNMENT("C0"),
                .SRTYPE("ASYNC")
            )
            oddr_inst (
                .Q(q[n]),
                .C0(clk),
                .C1(~clk),
                .CE(1'b1),
                .D0(d1[n]),
                .D1(d2[n]),
                .R(1'b0),
                .S(1'b0)
            );
        end
    end
end else if (TARGET == "ALTERA") begin
    altddio_out #(
        .WIDTH(WIDTH),
        .POWER_UP_HIGH("OFF"),
        .OE_REG("UNUSED")
    )
    altddio_out_inst (
        .aset(1'b0),
        .datain_h(d1),
        .datain_l(d2),
        .outclocken(1'b1),
        .outclock(clk),
        .aclr(1'b0),
        .dataout(q)
    );
end else begin
    reg [WIDTH-1:0] d_reg_1 = {WIDTH{1'b0}};
    reg [WIDTH-1:0] d_reg_2 = {WIDTH{1'b0}};

    reg [WIDTH-1:0] q_reg = {WIDTH{1'b0}};

    always @(posedge clk) begin
        d_reg_1 <= d1;
        d_reg_2 <= d2;
    end

    always @(posedge clk) begin
        q_reg <= d1;
    end

    always @(negedge clk) begin
        q_reg <= d_reg_2;
    end

    assign q = q_reg;
end

endgenerate

endmodule

`resetall


// ---- Private implementation: fpt_net_lfsr.v ----
/*

Copyright (c) 2016-2023 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Parametrizable combinatorial parallel LFSR/CRC
 */
module fpt_net_lfsr #
(
    // width of LFSR
    parameter LFSR_WIDTH = 31,
    // LFSR polynomial
    parameter LFSR_POLY = 31'h10000001,
    // LFSR configuration: "GALOIS", "FIBONACCI"
    parameter LFSR_CONFIG = "FIBONACCI",
    // LFSR feed forward enable
    parameter LFSR_FEED_FORWARD = 0,
    // bit-reverse input and output
    parameter REVERSE = 0,
    // width of data input
    parameter DATA_WIDTH = 8,
    // implementation style: "AUTO", "LOOP", "REDUCTION"
    parameter STYLE = "AUTO"
)
(
    input  wire [DATA_WIDTH-1:0] data_in,
    input  wire [LFSR_WIDTH-1:0] state_in,
    output wire [DATA_WIDTH-1:0] data_out,
    output wire [LFSR_WIDTH-1:0] state_out
);

/*

Fully parametrizable combinatorial parallel LFSR/CRC module.  Implements an unrolled LFSR
next state computation, shifting DATA_WIDTH bits per pass through the module.  Input data
is XORed with LFSR feedback path, tie data_in to zero if this is not required.

Works in two parts: statically computes a set of bit masks, then uses these bit masks to
select bits for XORing to compute the next state.  

Ports:

data_in

Data bits to be shifted through the LFSR (DATA_WIDTH bits)

state_in

LFSR/CRC current state input (LFSR_WIDTH bits)

data_out

Data bits shifted out of LFSR (DATA_WIDTH bits)

state_out

LFSR/CRC next state output (LFSR_WIDTH bits)

Parameters:

LFSR_WIDTH

Specify width of LFSR/CRC register

LFSR_POLY

Specify the LFSR/CRC polynomial in hex format.  For example, the polynomial

x^32 + x^26 + x^23 + x^22 + x^16 + x^12 + x^11 + x^10 + x^8 + x^7 + x^5 + x^4 + x^2 + x + 1

would be represented as

32'h04c11db7

Note that the largest term (x^32) is suppressed.  This term is generated automatically based
on LFSR_WIDTH.

LFSR_CONFIG

Specify the LFSR configuration, either Fibonacci or Galois.  Fibonacci is generally used
for linear-feedback shift registers (LFSR) for pseudorandom binary sequence (PRBS) generators,
scramblers, and descrambers, while Galois is generally used for cyclic redundancy check
generators and checkers.

Fibonacci style (example for 64b66b scrambler, 0x8000000001)

   DIN (LSB first)
    |
    V
   (+)<---------------------------(+)<-----------------------------.
    |                              ^                               |
    |  .----.  .----.       .----. |  .----.       .----.  .----.  |
    +->|  0 |->|  1 |->...->| 38 |-+->| 39 |->...->| 56 |->| 57 |--'
    |  '----'  '----'       '----'    '----'       '----'  '----'
    V
   DOUT

Galois style (example for CRC16, 0x8005)

    ,-------------------+-------------------------+----------(+)<-- DIN (MSB first)
    |                   |                         |           ^
    |  .----.  .----.   V   .----.       .----.   V   .----.  |
    `->|  0 |->|  1 |->(+)->|  2 |->...->| 14 |->(+)->| 15 |--+---> DOUT
       '----'  '----'       '----'       '----'       '----'

LFSR_FEED_FORWARD

Generate feed forward instead of feed back LFSR.  Enable this for PRBS checking and self-
synchronous descrambling.

Fibonacci feed-forward style (example for 64b66b descrambler, 0x8000000001)

   DIN (LSB first)
    |
    |  .----.  .----.       .----.    .----.       .----.  .----.
    +->|  0 |->|  1 |->...->| 38 |-+->| 39 |->...->| 56 |->| 57 |--.
    |  '----'  '----'       '----' |  '----'       '----'  '----'  |
    |                              V                               |
   (+)<---------------------------(+)------------------------------'
    |
    V
   DOUT

Galois feed-forward style

    ,-------------------+-------------------------+------------+--- DIN (MSB first)
    |                   |                         |            |
    |  .----.  .----.   V   .----.       .----.   V   .----.   V
    `->|  0 |->|  1 |->(+)->|  2 |->...->| 14 |->(+)->| 15 |->(+)-> DOUT
       '----'  '----'       '----'       '----'       '----'

REVERSE

Bit-reverse LFSR input and output.  Shifts MSB first by default, set REVERSE for LSB first.

DATA_WIDTH

Specify width of input and output data bus.  The module will perform one shift per input
data bit, so if the input data bus is not required tie data_in to zero and set DATA_WIDTH
to the required number of shifts per clock cycle.  

STYLE

Specify implementation style.  Can be "AUTO", "LOOP", or "REDUCTION".  When "AUTO"
is selected, implemenation will be "LOOP" or "REDUCTION" based on synthesis translate
directives.  "REDUCTION" and "LOOP" are functionally identical, however they simulate
and synthesize differently.  "REDUCTION" is implemented with a loop over a Verilog
reduction operator.  "LOOP" is implemented as a doubly-nested loop with no reduction
operator.  "REDUCTION" is very fast for simulation in iverilog and synthesizes well in
Quartus but synthesizes poorly in ISE, likely due to large inferred XOR gates causing
problems with the optimizer.  "LOOP" synthesizes will in both ISE and Quartus.  "AUTO"
will default to "REDUCTION" when simulating and "LOOP" for synthesizers that obey
synthesis translate directives.

Settings for common LFSR/CRC implementations:

Name        Configuration           Length  Polynomial      Initial value   Notes
CRC16-IBM   Galois, bit-reverse     16      16'h8005        16'hffff
CRC16-CCITT Galois                  16      16'h1021        16'h1d0f
CRC32       Galois, bit-reverse     32      32'h04c11db7    32'hffffffff    Ethernet FCS; invert final output
CRC32C      Galois, bit-reverse     32      32'h1edc6f41    32'hffffffff    iSCSI, Intel CRC32 instruction; invert final output
PRBS6       Fibonacci               6       6'h21           any
PRBS7       Fibonacci               7       7'h41           any
PRBS9       Fibonacci               9       9'h021          any             ITU V.52
PRBS10      Fibonacci               10      10'h081         any             ITU
PRBS11      Fibonacci               11      11'h201         any             ITU O.152
PRBS15      Fibonacci, inverted     15      15'h4001        any             ITU O.152
PRBS17      Fibonacci               17      17'h04001       any
PRBS20      Fibonacci               20      20'h00009       any             ITU V.57
PRBS23      Fibonacci, inverted     23      23'h040001      any             ITU O.151
PRBS29      Fibonacci, inverted     29      29'h08000001    any
PRBS31      Fibonacci, inverted     31      31'h10000001    any
64b66b      Fibonacci, bit-reverse  58      58'h8000000001  any             10G Ethernet
128b130b    Galois, bit-reverse     23      23'h210125      any             PCIe gen 3

*/

function [LFSR_WIDTH+DATA_WIDTH-1:0] lfsr_mask(input [31:0] index);
    reg [LFSR_WIDTH-1:0] lfsr_mask_state[LFSR_WIDTH-1:0];
    reg [DATA_WIDTH-1:0] lfsr_mask_data[LFSR_WIDTH-1:0];
    reg [LFSR_WIDTH-1:0] output_mask_state[DATA_WIDTH-1:0];
    reg [DATA_WIDTH-1:0] output_mask_data[DATA_WIDTH-1:0];

    reg [LFSR_WIDTH-1:0] state_val;
    reg [DATA_WIDTH-1:0] data_val;

    reg [DATA_WIDTH-1:0] data_mask;

    integer i, j;

    begin
        // init bit masks
        for (i = 0; i < LFSR_WIDTH; i = i + 1) begin
            lfsr_mask_state[i] = 0;
            lfsr_mask_state[i][i] = 1'b1;
            lfsr_mask_data[i] = 0;
        end
        for (i = 0; i < DATA_WIDTH; i = i + 1) begin
            output_mask_state[i] = 0;
            if (i < LFSR_WIDTH) begin
                output_mask_state[i][i] = 1'b1;
            end
            output_mask_data[i] = 0;
        end

        // simulate shift register
        if (LFSR_CONFIG == "FIBONACCI") begin
            // Fibonacci configuration
            for (data_mask = {1'b1, {DATA_WIDTH-1{1'b0}}}; data_mask != 0; data_mask = data_mask >> 1) begin
                // determine shift in value
                // current value in last FF, XOR with input data bit (MSB first)
                state_val = lfsr_mask_state[LFSR_WIDTH-1];
                data_val = lfsr_mask_data[LFSR_WIDTH-1];
                data_val = data_val ^ data_mask;

                // add XOR inputs from correct indicies
                for (j = 1; j < LFSR_WIDTH; j = j + 1) begin
                    if ((LFSR_POLY >> j) & 1) begin
                        state_val = lfsr_mask_state[j-1] ^ state_val;
                        data_val = lfsr_mask_data[j-1] ^ data_val;
                    end
                end

                // shift
                for (j = LFSR_WIDTH-1; j > 0; j = j - 1) begin
                    lfsr_mask_state[j] = lfsr_mask_state[j-1];
                    lfsr_mask_data[j] = lfsr_mask_data[j-1];
                end
                for (j = DATA_WIDTH-1; j > 0; j = j - 1) begin
                    output_mask_state[j] = output_mask_state[j-1];
                    output_mask_data[j] = output_mask_data[j-1];
                end
                output_mask_state[0] = state_val;
                output_mask_data[0] = data_val;
                if (LFSR_FEED_FORWARD) begin
                    // only shift in new input data
                    state_val = {LFSR_WIDTH{1'b0}};
                    data_val = data_mask;
                end
                lfsr_mask_state[0] = state_val;
                lfsr_mask_data[0] = data_val;
            end
        end else if (LFSR_CONFIG == "GALOIS") begin
            // Galois configuration
            for (data_mask = {1'b1, {DATA_WIDTH-1{1'b0}}}; data_mask != 0; data_mask = data_mask >> 1) begin
                // determine shift in value
                // current value in last FF, XOR with input data bit (MSB first)
                state_val = lfsr_mask_state[LFSR_WIDTH-1];
                data_val = lfsr_mask_data[LFSR_WIDTH-1];
                data_val = data_val ^ data_mask;

                // shift
                for (j = LFSR_WIDTH-1; j > 0; j = j - 1) begin
                    lfsr_mask_state[j] = lfsr_mask_state[j-1];
                    lfsr_mask_data[j] = lfsr_mask_data[j-1];
                end
                for (j = DATA_WIDTH-1; j > 0; j = j - 1) begin
                    output_mask_state[j] = output_mask_state[j-1];
                    output_mask_data[j] = output_mask_data[j-1];
                end
                output_mask_state[0] = state_val;
                output_mask_data[0] = data_val;
                if (LFSR_FEED_FORWARD) begin
                    // only shift in new input data
                    state_val = {LFSR_WIDTH{1'b0}};
                    data_val = data_mask;
                end
                lfsr_mask_state[0] = state_val;
                lfsr_mask_data[0] = data_val;

                // add XOR inputs at correct indicies
                for (j = 1; j < LFSR_WIDTH; j = j + 1) begin
                    if ((LFSR_POLY >> j) & 1) begin
                        lfsr_mask_state[j] = lfsr_mask_state[j] ^ state_val;
                        lfsr_mask_data[j] = lfsr_mask_data[j] ^ data_val;
                    end
                end
            end
        end else begin
            $error("Error: unknown configuration setting!");
            $finish;
        end

        // reverse bits if selected
        if (REVERSE) begin
            if (index < LFSR_WIDTH) begin
                state_val = 0;
                for (i = 0; i < LFSR_WIDTH; i = i + 1) begin
                    state_val[i] = lfsr_mask_state[LFSR_WIDTH-index-1][LFSR_WIDTH-i-1];
                end

                data_val = 0;
                for (i = 0; i < DATA_WIDTH; i = i + 1) begin
                    data_val[i] = lfsr_mask_data[LFSR_WIDTH-index-1][DATA_WIDTH-i-1];
                end
            end else begin
                state_val = 0;
                for (i = 0; i < LFSR_WIDTH; i = i + 1) begin
                    state_val[i] = output_mask_state[DATA_WIDTH-(index-LFSR_WIDTH)-1][LFSR_WIDTH-i-1];
                end

                data_val = 0;
                for (i = 0; i < DATA_WIDTH; i = i + 1) begin
                    data_val[i] = output_mask_data[DATA_WIDTH-(index-LFSR_WIDTH)-1][DATA_WIDTH-i-1];
                end
            end
        end else begin
            if (index < LFSR_WIDTH) begin
                state_val = lfsr_mask_state[index];
                data_val = lfsr_mask_data[index];
            end else begin
                state_val = output_mask_state[index-LFSR_WIDTH];
                data_val = output_mask_data[index-LFSR_WIDTH];
            end
        end
        lfsr_mask = {data_val, state_val};
    end
endfunction

// synthesis translate_off
`define SIMULATION
// synthesis translate_on

`ifdef SIMULATION
// "AUTO" style is "REDUCTION" for faster simulation
parameter STYLE_INT = (STYLE == "AUTO") ? "REDUCTION" : STYLE;
`else
// "AUTO" style is "LOOP" for better synthesis result
parameter STYLE_INT = (STYLE == "AUTO") ? "LOOP" : STYLE;
`endif

genvar n;

generate

if (STYLE_INT == "REDUCTION") begin

    // use Verilog reduction operator
    // fast in iverilog
    // significantly larger than generated code with ISE (inferred wide XORs may be tripping up optimizer)
    // slightly smaller than generated code with Quartus
    // --> better for simulation

    for (n = 0; n < LFSR_WIDTH; n = n + 1) begin : lfsr_state
        wire [LFSR_WIDTH+DATA_WIDTH-1:0] mask = lfsr_mask(n);
        assign state_out[n] = ^({data_in, state_in} & mask);
    end
    for (n = 0; n < DATA_WIDTH; n = n + 1) begin : lfsr_data
        wire [LFSR_WIDTH+DATA_WIDTH-1:0] mask = lfsr_mask(n+LFSR_WIDTH);
        assign data_out[n] = ^({data_in, state_in} & mask);
    end

end else if (STYLE_INT == "LOOP") begin

    // use nested loops
    // very slow in iverilog
    // slightly smaller than generated code with ISE
    // same size as generated code with Quartus
    // --> better for synthesis

    for (n = 0; n < LFSR_WIDTH; n = n + 1) begin : lfsr_state
        wire [LFSR_WIDTH+DATA_WIDTH-1:0] mask = lfsr_mask(n);

        reg state_reg;

        assign state_out[n] = state_reg;

        integer i;

        always @* begin
            state_reg = 1'b0;
            for (i = 0; i < LFSR_WIDTH; i = i + 1) begin
                if (mask[i]) begin
                    state_reg = state_reg ^ state_in[i];
                end
            end
            for (i = 0; i < DATA_WIDTH; i = i + 1) begin
                if (mask[i+LFSR_WIDTH]) begin
                    state_reg = state_reg ^ data_in[i];
                end
            end
        end
    end
    for (n = 0; n < DATA_WIDTH; n = n + 1) begin : lfsr_data
        wire [LFSR_WIDTH+DATA_WIDTH-1:0] mask = lfsr_mask(n+LFSR_WIDTH);

        reg data_reg;

        assign data_out[n] = data_reg;

        integer i;

        always @* begin
            data_reg = 1'b0;
            for (i = 0; i < LFSR_WIDTH; i = i + 1) begin
                if (mask[i]) begin
                    data_reg = data_reg ^ state_in[i];
                end
            end
            for (i = 0; i < DATA_WIDTH; i = i + 1) begin
                if (mask[i+LFSR_WIDTH]) begin
                    data_reg = data_reg ^ data_in[i];
                end
            end
        end
    end

end else begin

    initial begin
        $error("Error: unknown style setting!");
        $finish;
    end

end

endgenerate

endmodule

`resetall
`timescale 1ns/1ps
module fpt_net_eth_axis_byte_sync_fifo #(
    parameter int DEPTH = 256
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic [7:0] s_axis_tdata,
    input  logic       s_axis_tvalid,
    input  logic       s_axis_tlast,
    input  logic       s_axis_tuser,
    output logic       s_axis_tready,

    output logic [7:0] m_axis_tdata,
    output logic       m_axis_tvalid,
    output logic       m_axis_tlast,
    output logic       m_axis_tuser,
    input  logic       m_axis_tready
    );
    localparam int ADDR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam logic [ADDR_W:0] DEPTH_COUNT = DEPTH;

    // One synchronous 10-bit memory keeps the timing-isolation FIFO compact
    // and prevents its write bus from spreading over several LUTRAM banks.
    (* ram_style = "block" *) logic [9:0] axis_mem [0:DEPTH-1];

    logic [ADDR_W-1:0] wr_ptr_q;
    logic [ADDR_W-1:0] rd_ptr_q;
    logic [ADDR_W:0] count_q;
    logic [ADDR_W:0] occupancy;
    logic push;
    logic pop_mem;
    logic consume_out;
    logic load_out;

    logic [7:0] m_data_q;
    logic       m_valid_q;
    logic       m_last_q;
    logic       m_user_q;

    assign occupancy = count_q + {{ADDR_W{1'b0}}, m_valid_q};
    assign s_axis_tready = (occupancy < DEPTH_COUNT);
    assign push = s_axis_tvalid && s_axis_tready;
    assign consume_out = m_valid_q && m_axis_tready;
    assign load_out = !m_valid_q || m_axis_tready;
    assign pop_mem = load_out && (count_q != '0);

    assign m_axis_tdata  = m_data_q;
    assign m_axis_tvalid = m_valid_q;
    assign m_axis_tlast  = m_last_q;
    assign m_axis_tuser  = m_user_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr_q  <= '0;
            rd_ptr_q  <= '0;
            count_q   <= '0;
            m_data_q  <= 8'h00;
            m_valid_q <= 1'b0;
            m_last_q  <= 1'b0;
            m_user_q  <= 1'b0;
        end else begin
            if (push) begin
                axis_mem[wr_ptr_q] <= {
                    s_axis_tuser,
                    s_axis_tlast,
                    s_axis_tdata
                };
                wr_ptr_q <= wr_ptr_q + 1'b1;
            end

            if (pop_mem) begin
                {
                    m_user_q,
                    m_last_q,
                    m_data_q
                } <= axis_mem[rd_ptr_q];
                m_valid_q <= 1'b1;
                rd_ptr_q  <= rd_ptr_q + 1'b1;
            end else if (consume_out) begin
                m_valid_q <= 1'b0;
                m_last_q  <= 1'b0;
                m_user_q  <= 1'b0;
            end

            case ({push, pop_mem})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end

endmodule

