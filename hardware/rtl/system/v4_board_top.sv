`timescale 1ns/1ps
// Only clocks, resets and subsystem connections belong in this top.
module v4_board_top (
    input  logic       FPGA_CLK,
    input  logic       FPGA_RST_N,
    input  logic       START_KEY_N,
    input  logic       PRINT_KEY_N,
    output logic       UART_TX,

    output logic [3:0] rgmii_txd,
    output logic       rgmii_tx_ctl,
    output logic       rgmii_txc,
    input  logic [3:0] rgmii_rxd,
    input  logic       rgmii_rx_ctl,
    input  logic       rgmii_rxc,

    inout  wire        mdio,
    output logic       mdc,
    output logic       phy_rst_n,
    input  logic       phy_int_n,

    inout  wire [31:0] ddr3_dq,
    inout  wire [3:0]  ddr3_dqs_n,
    inout  wire [3:0]  ddr3_dqs_p,
    output logic [14:0] ddr3_addr,
    output logic [2:0]  ddr3_ba,
    output logic        ddr3_ras_n,
    output logic        ddr3_cas_n,
    output logic        ddr3_we_n,
    output logic        ddr3_reset_n,
    output logic [0:0]  ddr3_ck_p,
    output logic [0:0]  ddr3_ck_n,
    output logic [0:0]  ddr3_cke,
    output logic [0:0]  ddr3_cs_n,
    output logic [3:0]  ddr3_dm,
    output logic [0:0]  ddr3_odt
);
    import fpt_pkg::*;
    wire clk, host_clk, mac_clk, ref_clk, sys_clk, locked, clk_ibuf;
    wire rst_n, host_rst_n, mac_rst_n, ref_rst_n;
    IBUF u_fpga_clk_ibuf (.I(FPGA_CLK), .O(clk_ibuf));
    BUFG u_fpga_clk_bufg (.I(clk_ibuf), .O(clk));
    clk_wiz_0 u_clk_wiz_0 (
        .clk_in1(clk), .reset(~FPGA_RST_N), .locked(locked),
        .clk_100MHZ(), .clk_125MHZ(mac_clk),
        .clk_200MHZ(ref_clk), .clk_250MHZ(sys_clk)
    );
    v4_reset u_rst_compute (.clk(clk), .async_rst_n(FPGA_RST_N && locked), .rst_n(rst_n));
    v4_reset u_rst_host (.clk(host_clk), .async_rst_n(FPGA_RST_N && locked), .rst_n(host_rst_n));
    v4_reset u_rst_mac (.clk(mac_clk), .async_rst_n(FPGA_RST_N && locked), .rst_n(mac_rst_n));
    v4_reset u_rst_ref (.clk(ref_clk), .async_rst_n(FPGA_RST_N && locked), .rst_n(ref_rst_n));
    assign host_clk = mac_clk; // 125 MHz byte processing matches the GbE MAC.
    assign UART_TX = 1;

    command_t command;
    response_t response;
    bulk_write_t bulk_write;
    bulk_read_t bulk_read;
    status_t host_status;
    logic command_ready;
    logic [31:0] bulk_read_data;
    logic ddr_clk,ddr_sync_rst,calibrated;
    wire ddr_rst_n;
    v4_reset u_rst_ddr(.clk(ddr_clk),.async_rst_n(calibrated && !ddr_sync_rst),.rst_n(ddr_rst_n));
    logic [28:0] app_addr;
    logic [2:0] app_cmd;
    logic app_en,app_rdy,app_wdf_end,app_wdf_wren,app_wdf_rdy,app_rd_data_end,app_rd_data_valid;
    logic [255:0] app_wdf_data,app_rd_data;
    logic [31:0] app_wdf_mask;
    v4_system system(.clk(ref_clk),.rst_n(ref_rst_n),.host_clk,.host_rst_n,.ddr_clk,.ddr_rst_n,
        .command,.command_ready,.response,.bulk_write,.bulk_read,.bulk_read_data,.host_status,
        .app_addr,.app_cmd,.app_en,.app_rdy,.app_wdf_data,.app_wdf_mask,.app_wdf_end,.app_wdf_wren,.app_wdf_rdy,
        .app_rd_data,.app_rd_data_valid,.failed());
    ethernet network (
        .clk(host_clk), .rst_n(host_rst_n), .mac_clk(mac_clk), .mac_rst_n(mac_rst_n),
        .ref_clk(ref_clk), .ref_rst_n(ref_rst_n),
        .command(command), .command_ready(command_ready), .response(response),
        .bulk_write(bulk_write), .bulk_read(bulk_read), .bulk_read_data(bulk_read_data),
        .status(host_status), .rgmii_txd(rgmii_txd), .rgmii_tx_ctl(rgmii_tx_ctl),
        .rgmii_txc(rgmii_txc), .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl),
        .rgmii_rxc(rgmii_rxc), .phy_int_n(phy_int_n), .mdio(mdio), .mdc(mdc), .phy_rst_n(phy_rst_n)
    );
    mig_7series_0 u_mig_7series_0 (
        .ddr3_dq(ddr3_dq),
        .ddr3_dqs_n(ddr3_dqs_n),
        .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_addr(ddr3_addr),
        .ddr3_ba(ddr3_ba),
        .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n),
        .ddr3_we_n(ddr3_we_n),
        .ddr3_reset_n(ddr3_reset_n),
        .ddr3_ck_p(ddr3_ck_p),
        .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cke(ddr3_cke),
        .ddr3_cs_n(ddr3_cs_n),
        .ddr3_dm(ddr3_dm),
        .ddr3_odt(ddr3_odt),
        .sys_clk_i(sys_clk),
        .clk_ref_i(ref_clk),
        .sys_rst(FPGA_RST_N && locked),
        .ui_clk(ddr_clk),
        .ui_clk_sync_rst(ddr_sync_rst),
        .init_calib_complete(calibrated),
        .app_sr_req(1'b0),
        .app_ref_req(1'b0),
        .app_zq_req(1'b0),
        .app_sr_active(),
        .app_ref_ack(),
        .app_zq_ack(),
        .device_temp(),
        .app_addr(app_addr),
        .app_cmd(app_cmd),
        .app_en(app_en),
        .app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data),
        .app_wdf_end(app_wdf_end),
        .app_wdf_mask(app_wdf_mask),
        .app_wdf_wren(app_wdf_wren),
        .app_wdf_rdy(app_wdf_rdy),
        .app_rd_data(app_rd_data),
        .app_rd_data_end(app_rd_data_end),
        .app_rd_data_valid(app_rd_data_valid)
    );
endmodule
module v4_reset(input logic clk, async_rst_n, output logic rst_n);
    (* ASYNC_REG = "TRUE" *) logic [2:0] pipe;
    always_ff @(posedge clk or negedge async_rst_n)
        if (!async_rst_n) pipe <= 0;
        else pipe <= {pipe[1:0], 1'b1};
    assign rst_n = pipe[2];
endmodule
