# vivado -mode batch -source hardware/create_project.tcl -tclargs create|synth|impl
set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set build [file join $root build vivado]
set xpr [file join $build project fpt_v4.xpr]
set stage [lindex $argv 0]
if {$stage ni {"" create synth impl}} {error "Use create, synth or impl"}
if {[file exists $xpr]} {
    open_project $xpr
} else {
    create_project fpt_v4 [file join $build project] -part xc7a200tfbg484-2
    set_property target_language Verilog [current_project]
    add_files [list [file join $here rtl platform fpt_pkg.sv]]
    add_files [list [file join $here rtl core attn_pkg.sv]]
    foreach name {v4_common v4_math v4_sched v4_core} {
        add_files [list [file join $here rtl core ${name}.sv]]
    }
    foreach name {ethernet axis_async_fifo} {
        add_files [list [file join $here rtl platform ${name}.sv]]
    }
    add_files [glob [file join $here rtl system *.sv]]
    set_property include_dirs [list [file join $here rtl core]] [current_fileset]
    foreach name {clk_wiz_0 mig_7series_0} {
        import_ip [list [file join $here ip $name ${name}.xci]]
    }
    set mig_dir [file dirname [get_property IP_FILE [get_ips mig_7series_0]]]
    file copy -force [file join $here ip mig_7series_0 mig_b.prj] $mig_dir
    upgrade_ip [get_ips]
    generate_target all [get_ips]
    foreach name {pins.xdc timing.xdc} {
        add_files -fileset constrs_1 [list [file join $here constraints $name]]
    }
    set_property top v4_board_top [current_fileset]
}
set_property PROCESSING_ORDER LATE [get_files [list [file join $here constraints timing.xdc]]]
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
set_property INCREMENTAL_CHECKPOINT {} [get_runs synth_1]
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE RuntimeOptimized [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.OPT_DESIGN.TCL.PRE [file join $here constraints cdc_properties.tcl] [get_runs impl_1]
update_compile_order -fileset sources_1
if {$stage in {synth impl}} {
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
}
if {$stage eq "impl"} {
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
    open_run impl_1
    set report [file join $build timing.rpt]
    report_timing_summary -max_paths 20 -file $report
    report_cdc -details -file [file join $build cdc.rpt]
    report_drc -file [file join $build drc.rpt]
    report_bus_skew -warn_on_violation -file [file join $build bus_skew.rpt]
    check_timing -verbose -file [file join $build check_timing.rpt]
    set f [open $report r];set timing [read $f];close $f
    if {![string match {*All user specified timing constraints are met.*} $timing]} {
        error "Timing did not close; inspect $report"
    }
    if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]} {error "DRC errors; export refused"}
    set f [open [file join $build cdc.rpt] r];set cdc [read $f];close $f
    if {[regexp {CDC-[0-9]+[ ]+Critical} $cdc]} {error "Critical CDC; export refused"}
    set f [open [file join $build bus_skew.rpt] r];set skew [read $f];close $f
    if {[string match {*Slack (VIOLATED)*} $skew]} {error "Bus skew violation; export refused"}
    file copy -force [file join $build project fpt_v4.runs impl_1 v4_board_top.bit] [file join $build v4_system.bit]
}
