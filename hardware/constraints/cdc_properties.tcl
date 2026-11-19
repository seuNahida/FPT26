# Implementation hook: the reused FIFO RTL prevents shift-register extraction;
# mark its synchronizer flops for MTBF-aware placement as well. The XDC already
# bounds Gray-bus propagation/skew and leaves stage-1 -> stage-2 timing active.
set synchronizers [get_cells -hier -quiet -filter {NAME =~ system/*/fifo/*sync*_reg_reg*}]
if {![llength $synchronizers]} {error "No v4 FIFO synchronizers matched; check hierarchy"}
set_property ASYNC_REG TRUE $synchronizers
puts "Marked [llength $synchronizers] v4 FIFO synchronizer registers ASYNC_REG"

# Distributed dual-clock RAM data is held until its Gray write pointer has
# crossed to the reader. Follow the FIFO author's output-register exception:
# https://github.com/alexforencich/verilog-axis/blob/master/syn/vivado/axis_async_fifo.tcl
# Only the WRITE clock -> first READ data register path is asynchronous.
# Reader address/control -> data-register timing and the Gray limits remain active.
set data_crossings 0
foreach fifo [get_cells -hier -quiet -filter {NAME =~ system/*/fifo}] {
    set write_ptrs [get_cells -hier -quiet -filter "PARENT == $fifo && NAME =~ *wr_ptr_gray_reg_reg*"]
    set read_data [get_cells -hier -quiet -filter "PARENT == $fifo && NAME =~ *m_axis_pipe_reg_reg*"]
    set write_clocks [get_clocks -quiet -of_objects [get_pins -quiet -of_objects $write_ptrs -filter {REF_PIN_NAME == C}]]
    if {[llength $write_clocks] && [llength $read_data]} {
        set_false_path -from $write_clocks -to $read_data
        incr data_crossings
    }
}
if {$data_crossings == 0} {error "No asynchronous FIFO output crossings matched"}
puts "Constrained $data_crossings Gray-qualified FIFO data crossings"
