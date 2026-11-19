# Bind the clock-wizard primary clock to the board port. Keep its 0.2 ns
# input jitter and avoid the legacy internal-pin / board-root redefinition.
create_clock -name u_clk_wiz_0/inst/clk_in1 -period 20.000 [get_ports FPGA_CLK]
set_input_jitter [get_clocks u_clk_wiz_0/inst/clk_in1] 0.200

# RGMII receive clock from the PHY.  In 1 GbE mode this is 125 MHz.
create_clock -name RGMII_RXC -period 8.000 -waveform {0.000 4.000} [get_ports rgmii_rxc]

# Electrical properties for the Ethernet pins.  Pin locations live in
# attention.xdc; keeping drive/slew here avoids editing its legacy encoding.
set_property DRIVE 8 [get_ports {rgmii_txc rgmii_tx_ctl rgmii_txd[*] mdc phy_rst_n}]
set_property SLEW FAST [get_ports {rgmii_txc rgmii_tx_ctl rgmii_txd[*] mdc phy_rst_n}]
set_property PULLUP true [get_ports {mdio phy_int_n}]

# RGMII source-synchronous I/O timing.  These numbers follow the same shape as
# the Xilinx TEMAC RGMII constraints and assume an RGMII-ID style board/PHY
# path, where RXC/TXC are phase shifted relative to data.  If the PHY is not in
# an internal-delay mode, add FPGA-side IDELAY/clock shifting before relying on
# these constraints for hardware stability.
create_clock -name RGMII_RXC_VIRT -period 8.000 -waveform {0.000 4.000}

set free_mac_rgmii_clk_oddr [get_cells -quiet -hierarchical -filter {NAME =~ *u_eth_mac_1g_rgmii_fifo*rgmii_phy_if_inst*clk_oddr_inst*oddr_inst}]
set free_mac_rgmii_clk_oddr_c [get_pins -quiet -of_objects $free_mac_rgmii_clk_oddr -filter {REF_PIN_NAME == C}]
create_generated_clock -name RGMII_TXC -divide_by 1 -source $free_mac_rgmii_clk_oddr_c [get_ports rgmii_txc]

set free_mac_rgmii_rx_ports [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
set free_mac_rgmii_rx_capture_clks [get_clocks -quiet -include_generated_clocks RGMII_RXC]
# Input delays must track board_top / ethernet.RGMII_RX_IDELAY_TAPS: the FPGA
# IDELAYE2 shifts the data 78.125 ps/tap before the IDDRs.  Measured on the
# board flow (15:10/15:30 builds): IDELAY=16 (1.25 ns) matched -1.500/-2.800
# and gave ~1% frame loss; IDELAY=26 (2.03 ns) needed -2.280/-3.580 for timing
# but gave ~97% frame loss on the link, proving the PHY already provides the
# RGMII internal delay (RGMII-ID) and the FPGA taps only push the sample
# point past the data eye.  IDELAY=0 => -0.250/-1.550 (16 taps = 1.25 ns less
# than the IDELAY=16 pair).
set_input_delay -clock [get_clocks RGMII_RXC_VIRT] -max -0.250 $free_mac_rgmii_rx_ports
set_input_delay -clock [get_clocks RGMII_RXC_VIRT] -min -1.550 $free_mac_rgmii_rx_ports
set_input_delay -clock [get_clocks RGMII_RXC_VIRT] -clock_fall -add_delay -max -0.250 $free_mac_rgmii_rx_ports
set_input_delay -clock [get_clocks RGMII_RXC_VIRT] -clock_fall -add_delay -min -1.550 $free_mac_rgmii_rx_ports

set_false_path -rise_from [get_clocks RGMII_RXC_VIRT] -fall_to $free_mac_rgmii_rx_capture_clks -setup
set_false_path -fall_from [get_clocks RGMII_RXC_VIRT] -rise_to $free_mac_rgmii_rx_capture_clks -setup
set_false_path -rise_from [get_clocks RGMII_RXC_VIRT] -rise_to $free_mac_rgmii_rx_capture_clks -hold
set_false_path -fall_from [get_clocks RGMII_RXC_VIRT] -fall_to $free_mac_rgmii_rx_capture_clks -hold
set_multicycle_path -from [get_clocks RGMII_RXC_VIRT] -to $free_mac_rgmii_rx_capture_clks -setup 0
set_multicycle_path -from [get_clocks RGMII_RXC_VIRT] -to $free_mac_rgmii_rx_capture_clks -hold -1

set free_mac_rgmii_tx_ports [get_ports {rgmii_txd[*] rgmii_tx_ctl}]
set free_mac_rgmii_tx_src_clks [get_clocks -quiet -of_objects $free_mac_rgmii_clk_oddr_c]
set_output_delay -clock [get_clocks RGMII_TXC] -max 0.750 $free_mac_rgmii_tx_ports
set_output_delay -clock [get_clocks RGMII_TXC] -min -0.700 $free_mac_rgmii_tx_ports
set_output_delay -clock [get_clocks RGMII_TXC] -clock_fall -add_delay -max 0.750 $free_mac_rgmii_tx_ports
set_output_delay -clock [get_clocks RGMII_TXC] -clock_fall -add_delay -min -0.700 $free_mac_rgmii_tx_ports

set_false_path -quiet -rise_from $free_mac_rgmii_tx_src_clks -fall_to [get_clocks RGMII_TXC] -setup
set_false_path -quiet -fall_from $free_mac_rgmii_tx_src_clks -rise_to [get_clocks RGMII_TXC] -setup
set_false_path -quiet -rise_from $free_mac_rgmii_tx_src_clks -rise_to [get_clocks RGMII_TXC] -hold
set_false_path -quiet -fall_from $free_mac_rgmii_tx_src_clks -fall_to [get_clocks RGMII_TXC] -hold

# eth_mac_1g_rgmii_fifo contains asynchronous FIFOs between the PHY RX clock
# and the internal logic clock.  The FIFO pointer synchronizers handle CDC.
# NOTE: get_clocks -include_generated_clocks FPGA_CLK resolves to only FPGA_CLK
# in this flow (the clk_wiz MMCM output clocks do not inherit it), so the
# clk_wiz outputs are listed explicitly via a name pattern.  Without this,
# RGMII_RXC->clk_100MHZ synchronizer chains (good/bad frame status) are timed
# as real data paths and fail on clock skew between the PHY clock and the
# MMCM output.
# XDC supports only a restricted Tcl subset: no concat/remove_from_collection.
set free_mac_logic_clks [get_clocks -quiet {FPGA_CLK *clk_wiz_0}]
set_clock_groups -asynchronous \
    -group $free_mac_logic_clks \
    -group [get_clocks RGMII_RXC]

# RGMII_RXC is generated by the external PHY, so its phase has no fixed
# relationship to the internal 100/125 MHz clocks.  Keep setup checks on the
# explicitly bounded synchronizer-entry paths below, but suppress meaningless
# inter-clock hold checks that implementation cannot close by routing.
set free_mac_clk_100 [get_clocks -quiet clk_125MHZ_clk_wiz_0]
set free_mac_clk_125 [get_clocks -quiet clk_125MHZ_clk_wiz_0]
set_false_path -quiet -from [get_clocks RGMII_RXC] -to $free_mac_clk_100 -hold
set_false_path -quiet -from $free_mac_clk_100 -to [get_clocks RGMII_RXC] -hold
set_false_path -quiet -from [get_clocks RGMII_RXC] -to $free_mac_clk_125 -hold
set_false_path -quiet -from $free_mac_clk_125 -to [get_clocks RGMII_RXC] -hold

# Static/asynchronous sideband pins are not synchronous data interfaces.
set_false_path -from [get_ports {FPGA_RST_N START_KEY_N PRINT_KEY_N phy_int_n mdio}]
set_false_path -to [get_ports {UART_TX mdc mdio phy_rst_n}]

# verilog-ethernet ships these as Vivado Tcl helper scripts.  Keep static XDC
# equivalents here so the project run picks up the synchronizer intent.  Use
# NAME filters instead of hierarchical regexp patterns; XDC object matching is
# less forgiving than a sourced Tcl script.
set free_mac_eth_sync_regs [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo*sync*reg*}]
set_property ASYNC_REG TRUE $free_mac_eth_sync_regs

# The asynchronous FIFO also transfers each side's reset into the opposite
# clock domain.  Match verilog-ethernet's axis_async_fifo Vivado constraints:
# keep the first-stage crossing physically short, but do not analyze it
# against the related MMCM clocks' occasional 2 ns edge separation.
set free_mac_tx_s_rst_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_fifo/fifo_inst/s_rst_sync1_reg_reg}]
set free_mac_tx_s_rst_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_fifo/fifo_inst/s_rst_sync2_reg_reg}]
set_max_delay -quiet -datapath_only 8.000 -from $free_mac_tx_s_rst_from -to $free_mac_tx_s_rst_to

set free_mac_tx_m_rst_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_fifo/fifo_inst/m_rst_sync1_reg_reg}]
set free_mac_tx_m_rst_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_fifo/fifo_inst/m_rst_sync2_reg_reg}]
set_max_delay -quiet -datapath_only 10.000 -from $free_mac_tx_m_rst_from -to $free_mac_tx_m_rst_to

set free_mac_rx_s_rst_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_fifo/fifo_inst/s_rst_sync1_reg_reg}]
set free_mac_rx_s_rst_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_fifo/fifo_inst/s_rst_sync2_reg_reg}]
set_max_delay -quiet -datapath_only 10.000 -from $free_mac_rx_s_rst_from -to $free_mac_rx_s_rst_to

set free_mac_rx_m_rst_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_fifo/fifo_inst/m_rst_sync1_reg_reg}]
set free_mac_rx_m_rst_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_fifo/fifo_inst/m_rst_sync2_reg_reg}]
set_max_delay -quiet -datapath_only 8.000 -from $free_mac_rx_m_rst_from -to $free_mac_rx_m_rst_to

# Vivado may merge equivalent first-stage reset registers from the RX and TX
# FIFOs.  Constrain the destination stage directly so the exception survives
# that legal optimization while still enforcing a short synchronizer route.
set free_mac_eth_rst_stage1 [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo*rst_sync1_reg_reg}]
set_max_delay -quiet -datapath_only 10.000 -from $free_mac_eth_rst_stage1 -to $free_mac_tx_s_rst_to
set_max_delay -quiet -datapath_only 8.000 -from $free_mac_eth_rst_stage1 -to $free_mac_tx_m_rst_to
set_max_delay -quiet -datapath_only 10.000 -from $free_mac_eth_rst_stage1 -to $free_mac_rx_s_rst_to
set_max_delay -quiet -datapath_only 8.000 -from $free_mac_eth_rst_stage1 -to $free_mac_rx_m_rst_to

# The 100 MHz MAC logic port and 125 MHz transmit engine are related MMCM
# clocks, but the MAC deliberately crosses them with asynchronous FIFO Gray
# pointers and explicit synchronizers.  Constrain only those CDC launch-to-
# first-stage paths, following verilog-ethernet's axis_async_fifo Vivado Tcl,
# so an accidental future direct crossing remains visible to timing analysis.
set free_mac_tx_rd_ptr_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_fifo/fifo_inst/rd_ptr*_reg_reg* && NAME !~ *sync*}]
set free_mac_tx_rd_ptr_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_fifo/fifo_inst/rd_ptr_gray_sync1_reg_reg*}]
set_max_delay -quiet -datapath_only 8.000 -from $free_mac_tx_rd_ptr_from -to $free_mac_tx_rd_ptr_to
set_bus_skew -quiet -from $free_mac_tx_rd_ptr_from -to $free_mac_tx_rd_ptr_to 10.000

set free_mac_tx_commit_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_fifo/fifo_inst/wr_ptr_sync_commit_reg_reg*}]
set free_mac_tx_commit_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_fifo/fifo_inst/wr_ptr_commit_sync_reg_reg*}]
set_max_delay -quiet -datapath_only 10.000 -from $free_mac_tx_commit_from -to $free_mac_tx_commit_to
set_bus_skew -quiet -from $free_mac_tx_commit_from -to $free_mac_tx_commit_to 8.000

set free_mac_tx_update_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_fifo/fifo_inst/wr_ptr_update_reg_reg}]
set free_mac_tx_update_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_fifo/fifo_inst/wr_ptr_update_sync1_reg_reg}]
set_max_delay -quiet -datapath_only 10.000 -from $free_mac_tx_update_from -to $free_mac_tx_update_to

set free_mac_tx_update_ack_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_fifo/fifo_inst/wr_ptr_update_sync3_reg_reg}]
set free_mac_tx_update_ack_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_fifo/fifo_inst/wr_ptr_update_ack_sync1_reg_reg}]
set_max_delay -quiet -datapath_only 8.000 -from $free_mac_tx_update_ack_from -to $free_mac_tx_update_ack_to

# RX FIFO CDCs are the mirror image of the TX FIFO paths above.  Their source
# clock is the external 125 MHz RGMII receive clock, so bound the first-stage
# transfer by one source period instead of timing it against an arbitrary
# RGMII_RXC/clk_100MHz edge pair.
set free_mac_rx_commit_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_fifo/fifo_inst/wr_ptr_sync_commit_reg_reg*}]
set free_mac_rx_commit_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_fifo/fifo_inst/wr_ptr_commit_sync_reg_reg*}]
set_max_delay -quiet -datapath_only 8.000 -from $free_mac_rx_commit_from -to $free_mac_rx_commit_to
set_bus_skew -quiet -from $free_mac_rx_commit_from -to $free_mac_rx_commit_to 8.000

set free_mac_rx_update_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_fifo/fifo_inst/wr_ptr_update_reg_reg}]
set free_mac_rx_update_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_fifo/fifo_inst/wr_ptr_update_sync1_reg_reg}]
set_max_delay -quiet -datapath_only 8.000 -from $free_mac_rx_update_from -to $free_mac_rx_update_to

set free_mac_rx_bad_frame_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_fifo/fifo_inst/bad_frame_sync1_reg_reg}]
set free_mac_rx_bad_frame_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_fifo/fifo_inst/bad_frame_sync2_reg_reg}]
set_max_delay -quiet -datapath_only 8.000 -from $free_mac_rx_bad_frame_from -to $free_mac_rx_bad_frame_to

set free_mac_rx_overflow_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_fifo/fifo_inst/overflow_sync1_reg_reg}]
set free_mac_rx_overflow_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_fifo/fifo_inst/overflow_sync2_reg_reg}]
set_max_delay -quiet -datapath_only 8.000 -from $free_mac_rx_overflow_from -to $free_mac_rx_overflow_to

set free_mac_rx_status_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_sync_reg_1_reg*}]
set free_mac_rx_status_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/rx_sync_reg_2_reg*}]
set_max_delay -quiet -datapath_only 8.000 -from $free_mac_rx_status_from -to $free_mac_rx_status_to

set free_mac_speed_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/eth_mac_1g_rgmii_inst/speed_reg_reg*}]
set free_mac_speed_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/speed_sync_reg_1_reg*}]
set_max_delay -quiet -datapath_only 8.000 -from $free_mac_speed_from -to $free_mac_speed_to

set free_mac_tx_status_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_sync_reg_1_reg*}]
set free_mac_tx_status_to [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo/tx_sync_reg_2_reg*}]
set_max_delay -quiet -datapath_only 8.000 -from $free_mac_tx_status_from -to $free_mac_tx_status_to

set free_mac_rgmii_rst_regs [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo*rgmii_phy_if_inst*rst_reg_reg*}]
set_property ASYNC_REG TRUE $free_mac_rgmii_rst_regs
set_false_path -to [get_pins -quiet -of_objects $free_mac_rgmii_rst_regs -filter {IS_PRESET || IS_RESET}]

set_property ASYNC_REG TRUE $free_mac_rgmii_clk_oddr

set free_mac_rgmii_clk_out_from [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD* && NAME =~ *u_eth_mac_1g_rgmii_fifo*rgmii_phy_if_inst*rgmii_tx_clk_*_reg}]
set free_mac_rgmii_clk_out_to [get_cells -quiet -hierarchical -filter {NAME =~ *u_eth_mac_1g_rgmii_fifo*rgmii_phy_if_inst*clk_oddr_inst*oddr_inst}]
# Keep the generated RGMII clock controls local to the output ODDR.  Three
# nanoseconds is still comfortably below a 125 MHz half-cycle while avoiding
# an artificial violation from the former 2 ns placement-only target.
set_max_delay -quiet -datapath_only 3.000 -from $free_mac_rgmii_clk_out_from -to $free_mac_rgmii_clk_out_to


# ethernet.sv async-assert reset synchronizers. link_reset_n is formed in the
# 100 MHz domain and clears these registers directly; each three-stage chain
# re-times the release in its own clock domain.
set fpt_link_reset_sync [get_cells -hier -filter {NAME =~ network/logic_reset_sync_reg* || NAME =~ network/mac_reset_sync_reg*}]
set_false_path -to [get_pins -of_objects $fpt_link_reset_sync -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]

# Streaming FIFO Gray pointers: bounded by the 200 MHz period.
set wr_gray_from [get_cells -hier -quiet -filter {NAME =~ system/*/fifo/wr_ptr_gray_reg_reg*}]
set wr_gray_to [get_cells -hier -quiet -filter {NAME =~ system/*/fifo/wr_ptr_gray_sync1_reg_reg*}]
set_max_delay -quiet -datapath_only 5.000 -from $wr_gray_from -to $wr_gray_to
set_bus_skew -quiet -from $wr_gray_from -to $wr_gray_to 5.000
set rd_gray_from [get_cells -hier -quiet -filter {NAME =~ system/*/fifo/rd_ptr_gray_reg_reg*}]
set rd_gray_to [get_cells -hier -quiet -filter {NAME =~ system/*/fifo/rd_ptr_gray_sync1_reg_reg*}]
set_max_delay -quiet -datapath_only 5.000 -from $rd_gray_from -to $rd_gray_to
set_bus_skew -quiet -from $rd_gray_from -to $rd_gray_to 5.000
set completion_from [get_cells -hier -quiet -filter {NAME =~ system/bus/written_gray_reg*}]
set completion_to [get_cells -hier -quiet -filter {NAME =~ system/engine/written_meta_reg*}]
set_max_delay -quiet -datapath_only 5.000 -from $completion_from -to $completion_to
set_bus_skew -quiet -from $completion_from -to $completion_to 5.000
set bus_counters_from [get_cells -hier -quiet -filter {NAME =~ system/bus_gray_reg*}]
set bus_counters_to [get_cells -hier -quiet -filter {NAME =~ system/*bus_meta_reg*}]
set_max_delay -quiet -datapath_only 5.000 -from $bus_counters_from -to $bus_counters_to
set_bus_skew -quiet -from $bus_counters_from -to $bus_counters_to 5.000
set system_sync_entry [get_cells -hier -quiet -regexp {.*system/(ready_sync|fault_sync)_reg\[0\]}]
set_false_path -quiet -to $system_sync_entry
set fifo_reset_first [get_cells -hier -quiet -filter {NAME =~ system/*/fifo/*rst_sync1_reg_reg*}]
set fifo_reset_second [get_cells -hier -quiet -filter {NAME =~ system/*/fifo/*rst_sync2_reg_reg*}]
set_max_delay -quiet -datapath_only 5.000 -from $fifo_reset_first -to $fifo_reset_second

set host_cal_entry [get_cells -hier -quiet -regexp {.*system/host_access/calibrated_reg\[0\]}]
set_false_path -quiet -to $host_cal_entry

# MIG-qualified reset asserts asynchronously and releases in its UI clock.
set ddr_reset_chain [get_cells -hier -quiet -filter {NAME =~ u_rst_ddr/pipe_reg*}]
set_false_path -quiet -to [get_pins -quiet -of_objects $ddr_reset_chain -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]

# Idle-only burst configuration: source is held stable before START, with
# 15 compute clocks settling time; two UI-domain synchronizer stages.
set tuning_from [get_cells -hier -quiet -filter {NAME =~ system/controller/tuning_reg*}]
set tuning_to [get_cells -hier -quiet -filter {NAME =~ system/burst_meta_reg*}]
set_max_delay -quiet -datapath_only 5.000 -from $tuning_from -to $tuning_to
set_bus_skew -quiet -from $tuning_from -to $tuning_to 5.000

# Single-bit diagnostic job-event toggles. Hold is irrelevant at the first
# metastability-catching stage; retain a physical datapath bound for setup.
set observe_events [get_cells -hier -quiet -regexp {.*system/ddr_observe/(start_toggle|done_toggle)_reg}]
set observe_entry [get_cells -hier -quiet -regexp {.*system/ddr_observe/(start_sync|done_sync)_reg\[0\]}]
set_max_delay -quiet -datapath_only 5.000 -from $observe_events -to $observe_entry
set_false_path -quiet -hold -to $observe_entry
