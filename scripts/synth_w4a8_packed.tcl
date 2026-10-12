set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build synth_w4a8_packed]
file mkdir $out
set f [open [file join $root build selected_part.txt] r]
set part [string trim [read $f]]
close $f
if {$part ne "xcvu9p-flga2104-2L-e" || [llength [get_parts -quiet $part]] != 1} {
    puts "ERROR: previously selected evaluation VU9P part is unavailable: $part"; exit 2
}
set impl 0
if {[llength $argv]} {set impl [lindex $argv 0]}
foreach name {sync_sdp_ram mac_pe mac_array w4_unpack w4a8_packed} {
    read_verilog -sv [file join $root rtl $name.sv]
}
read_xdc [file join $root constraints clock.xdc]
synth_design -top w4a8_packed -part $part -mode out_of_context -flatten_hierarchy rebuilt
set clock_site BUFGCE_X0Y0
set_property HD.CLK_SRC $clock_site [get_ports clk]
write_checkpoint -force [file join $out synthesized.dcp]
set f [open [file join $out configuration.txt] w]
puts $f "Top=w4a8_packed ROWS=4 COLS=4 TILE_K=8 GROUP_SIZE=32 DOUBLE_BUFFER=1 MAX_M=64 MAX_N=64 MAX_K=4096 BUS_BYTES=8 SCALE_ONCE=1 PACK_COLS=1"
puts $f "Part=$part (evaluation only; board/package/speed not confirmed)"
puts $f "Clock_period_ns=10.000 Virtual_OOC_clock_source=$clock_site"
close $f
report_utilization -file [file join $out utilization_synth.rpt]
report_utilization -hierarchical -file [file join $out utilization_hier_synth.rpt]
report_timing_summary -report_unconstrained -file [file join $out timing_synth.rpt]
report_timing -from [all_registers] -to [all_registers] -max_paths 10 -file [file join $out internal_timing_synth.rpt]
check_timing -verbose -file [file join $out check_timing_synth.rpt]
report_drc -file [file join $out drc_synth.rpt]
report_ram_utilization -include_lutram -file [file join $out ram_synth.rpt]
set latches [get_cells -hier -quiet -filter {REF_NAME =~ LD*}]
set blackboxes [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]
set f [open [file join $out primitive_counts.txt] w]
puts $f "Vivado=[version -short]"
puts $f "Part=$part (evaluation only, board unspecified)"
puts $f "Latch_count=[llength $latches]"
puts $f "Blackbox_count=[llength $blackboxes]"
set refs [dict create]
foreach cell [get_cells -hier -filter {IS_PRIMITIVE == 1}] {
    dict incr refs [get_property REF_NAME $cell]
}
foreach ref [lsort [dict keys $refs]] {puts $f "$ref=[dict get $refs $ref]"}
close $f
set f [open [file join $out dsp_mapping.txt] w]
foreach cell [get_cells -hier -filter {REF_NAME == DSP48E2}] {
    puts $f $cell
    puts $f "USE_MULT=[get_property USE_MULT $cell] USE_SIMD=[get_property USE_SIMD $cell]"
}
close $f
if {[llength $latches] || [llength $blackboxes]} {puts "ERROR: latch or blackbox inferred";exit 3}
puts "W4A8_PACKED_SYNTHESIS_PASS part=$part"
if {$impl} {
    opt_design
    place_design
    route_design
    write_checkpoint -force [file join $out routed_ooc.dcp]
    report_utilization -file [file join $out utilization_ooc.rpt]
    report_timing_summary -report_unconstrained -file [file join $out timing_ooc.rpt]
    report_timing -from [all_registers] -to [all_registers] -max_paths 10 -file [file join $out internal_timing_ooc.rpt]
    check_timing -verbose -file [file join $out check_timing_ooc.rpt]
    report_route_status -file [file join $out route_status_ooc.rpt]
    report_drc -file [file join $out drc_ooc.rpt]
    puts "W4A8_PACKED_OOC_FINISHED"
}
exit
