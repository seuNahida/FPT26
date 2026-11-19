# ACX750 attention demo top constraints.
# Top module: board_top

# 50 MHz active oscillator input.
set_property PACKAGE_PIN W19 [get_ports FPGA_CLK]
set_property IOSTANDARD LVCMOS33 [get_ports FPGA_CLK]

# Active-low push buttons.
# S0 -> reset, S1 -> start one attention run, S2 -> print latest UART report.
set_property PACKAGE_PIN D21 [get_ports FPGA_RST_N]
set_property IOSTANDARD LVCMOS33 [get_ports FPGA_RST_N]
set_property PULLUP true [get_ports FPGA_RST_N]

set_property PACKAGE_PIN E21 [get_ports START_KEY_N]
set_property IOSTANDARD LVCMOS33 [get_ports START_KEY_N]
set_property PULLUP true [get_ports START_KEY_N]

set_property PACKAGE_PIN G22 [get_ports PRINT_KEY_N]
set_property IOSTANDARD LVCMOS33 [get_ports PRINT_KEY_N]
set_property PULLUP true [get_ports PRINT_KEY_N]

# UART TX from FPGA. Connect this to the USB-UART RXD direction.
set_property PACKAGE_PIN L21 [get_ports UART_TX]
set_property IOSTANDARD LVCMOS33 [get_ports UART_TX]

# Unused buttons from the provided table:
# S3 -> G21
# S4 -> B22



#Ethernet
# 时钟与控制信号 (TX & Global)
set_property PACKAGE_PIN AB21 [get_ports rgmii_txc]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_txc]

set_property PACKAGE_PIN AA19 [get_ports rgmii_tx_ctl]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_tx_ctl]

# TX 数据线 (4-bit)
set_property PACKAGE_PIN AB20 [get_ports {rgmii_txd[0]}]
set_property PACKAGE_PIN Y19  [get_ports {rgmii_txd[1]}]
set_property PACKAGE_PIN AB22 [get_ports {rgmii_txd[2]}]
set_property PACKAGE_PIN W20  [get_ports {rgmii_txd[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {rgmii_txd[*]}]

# RX 时钟与控制信号
set_property PACKAGE_PIN Y18  [get_ports rgmii_rxc]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_rxc]

set_property PACKAGE_PIN T20  [get_ports rgmii_rx_ctl]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_rx_ctl]

# RX 数据线 (4-bit)
set_property PACKAGE_PIN P20  [get_ports {rgmii_rxd[0]}]
set_property PACKAGE_PIN N15  [get_ports {rgmii_rxd[1]}]
set_property PACKAGE_PIN AA18 [get_ports {rgmii_rxd[2]}]
set_property PACKAGE_PIN AB18 [get_ports {rgmii_rxd[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {rgmii_rxd[*]}]

# MDIO 管理接口
set_property PACKAGE_PIN R14  [get_ports mdc]
set_property IOSTANDARD LVCMOS33 [get_ports mdc]

set_property PACKAGE_PIN U21  [get_ports mdio]
set_property IOSTANDARD LVCMOS33 [get_ports mdio]

# 辅助信号 (复位与中断)
set_property PACKAGE_PIN P14  [get_ports phy_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports phy_rst_n]

set_property PACKAGE_PIN R16  [get_ports phy_int_n]
set_property IOSTANDARD LVCMOS33 [get_ports phy_int_n]
# W19 is used as the board 50 MHz oscillator input. If this package pin is not
# a clock-capable IO on the selected part/package, Vivado needs this exception
# for the local IBUF-to-BUFG debug clock path.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -quiet -of_objects [get_pins -hier -quiet {u_fpga_clk_ibuf/O}]]
# Reset synchronizer first-stage CDC exceptions.
set_false_path -quiet -to [get_pins -hier -quiet -regexp {.*u_rst_(50|100|eth|rx_mac|tx_mac)/rst_pipe_q_reg\[0\]/D}]

# Debug/status CDC timing exceptions.
# These payload registers are held stable by a req/ack toggle handshake.
set_false_path -quiet -to [get_cells -hier -quiet -filter {NAME =~ *debug_status_req_tx_sync_reg*}]
set_false_path -quiet -to [get_cells -hier -quiet -filter {NAME =~ *debug_status_ack_50_sync_reg*}]
set_false_path -quiet -to [get_cells -hier -quiet -filter {NAME =~ *temac_cfg_done_tx_sync_reg*}]
set_false_path -quiet -to [get_cells -hier -quiet -filter {NAME =~ *temac_cfg_error_tx_sync_reg*}]
set_false_path -quiet -to [get_cells -hier -quiet -filter {NAME =~ *phy_int_n_tx_sync_reg*}]

set_false_path -quiet -from [get_cells -hier -quiet -filter {NAME =~ *debug_done_50_snap_reg*}] -to [get_cells -hier -quiet -filter {NAME =~ *debug_done_tx_reg*}]
set_false_path -quiet -from [get_cells -hier -quiet -filter {NAME =~ *debug_busy_50_snap_reg*}] -to [get_cells -hier -quiet -filter {NAME =~ *debug_busy_tx_reg*}]
set_false_path -quiet -from [get_cells -hier -quiet -filter {NAME =~ *debug_error_50_snap_reg*}] -to [get_cells -hier -quiet -filter {NAME =~ *debug_error_tx_reg*}]
set_false_path -quiet -from [get_cells -hier -quiet -filter {NAME =~ *debug_core_error_50_snap_reg*}] -to [get_cells -hier -quiet -filter {NAME =~ *debug_core_error_tx_reg*}]
set_false_path -quiet -from [get_cells -hier -quiet -filter {NAME =~ *debug_cycle_count_50_snap_reg*}] -to [get_cells -hier -quiet -filter {NAME =~ *debug_cycle_count_tx_reg*}]
set_false_path -quiet -from [get_cells -hier -quiet -filter {NAME =~ *debug_output_count_50_snap_reg*}] -to [get_cells -hier -quiet -filter {NAME =~ *debug_output_count_tx_reg*}]
set_false_path -quiet -from [get_cells -hier -quiet -filter {NAME =~ *debug_pods_50_snap_reg*}] -to [get_cells -hier -quiet -filter {NAME =~ *debug_pods_tx_reg*}]

# Ethernet RX/TX mailbox CDC timing exceptions.
# The UDP stack uses a req/ack toggle mailbox between rx_clk and tx_clk.
set_false_path -quiet -to [get_cells -hier -quiet -filter {NAME =~ *u_eth_ipv4_udp_debug_stack*req_toggle_tx_meta_q_reg*}]
set_false_path -quiet -to [get_cells -hier -quiet -filter {NAME =~ *u_eth_ipv4_udp_debug_stack*ack_toggle_rx_meta_q_reg*}]
set_false_path -quiet -from [get_cells -hier -quiet -filter {NAME =~ *u_eth_ipv4_udp_debug_stack*mailbox_type_q_reg*}] -to [get_cells -hier -quiet -filter {NAME =~ *u_eth_ipv4_udp_debug_stack*tx_req_type_q_reg*}]
set_false_path -quiet -from [get_cells -hier -quiet -filter {NAME =~ *u_eth_ipv4_udp_debug_stack*mailbox_peer_mac_q_reg*}] -to [get_cells -hier -quiet -filter {NAME =~ *u_eth_ipv4_udp_debug_stack*tx_peer_mac_q_reg*}]
set_false_path -quiet -from [get_cells -hier -quiet -filter {NAME =~ *u_eth_ipv4_udp_debug_stack*mailbox_peer_ip_q_reg*}] -to [get_cells -hier -quiet -filter {NAME =~ *u_eth_ipv4_udp_debug_stack*tx_peer_ip_q_reg*}]
set_false_path -quiet -from [get_cells -hier -quiet -filter {NAME =~ *u_eth_ipv4_udp_debug_stack*mailbox_peer_port_q_reg*}] -to [get_cells -hier -quiet -filter {NAME =~ *u_eth_ipv4_udp_debug_stack*tx_peer_port_q_reg*}]