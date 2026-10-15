set root [file normalize [file join [file dirname [info script]] ..]]
set impl [lindex $argv 0]
set group [lindex $argv 1]
if {$group ni {32 12}} {puts "ERROR: unsupported group";exit 2}
set part xcvu9p-flga2104-2L-e
if {[llength [get_parts -quiet $part]]!=1} {puts "ERROR: VU9P unavailable";exit 2}
set out [file join $root build synth_dynamic_g$group]
file mkdir $out
foreach name {sync_sdp_ram vector/requant_group vector/requant_dynamic} {read_verilog -sv [file join $root rtl $name.sv]}
read_xdc [file join $root constraints clock.xdc]
synth_design -top requant_dynamic -part $part -mode out_of_context -flatten_hierarchy rebuilt -generic GROUP_SIZE=$group
set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports clk]
write_checkpoint -force [file join $out synthesized.dcp]
set f [open [file join $out configuration.txt] w]
puts $f "Vivado=[version -short] Top=requant_dynamic GROUP_SIZE=$group MAX_K=4096 Part=$part Clock_ns=10 Board=unspecified Buffer=$group*32 Sync_1R1W Scale=ceil(absmax/2032),clamp_1_65535"
close $f
report_utilization -file [file join $out utilization_synth.rpt]
report_utilization -hierarchical -file [file join $out utilization_hier_synth.rpt]
report_ram_utilization -include_lutram -file [file join $out ram_synth.rpt]
report_timing_summary -report_unconstrained -file [file join $out timing_synth.rpt]
report_timing -from [all_registers] -to [all_registers] -max_paths 10 -file [file join $out internal_timing_synth.rpt]
check_timing -verbose -file [file join $out check_timing_synth.rpt]
report_drc -file [file join $out drc_synth.rpt]
set latches [get_cells -hier -quiet -filter {REF_NAME =~ LD*}]
set boxes [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]
set f [open [file join $out primitive_counts.txt] w]
puts $f "Latch_count=[llength $latches]\nBlackbox_count=[llength $boxes]"
set refs [dict create]
foreach cell [get_cells -hier -filter {IS_PRIMITIVE == 1}] {dict incr refs [get_property REF_NAME $cell]}
foreach ref [lsort [dict keys $refs]] {puts $f "$ref=[dict get $refs $ref]"}
close $f
if {[llength $latches] || [llength $boxes]} {puts "ERROR: latch/blackbox";exit 3}
puts "DYNAMIC_SYNTHESIS_PASS group=$group part=$part"
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
    puts "DYNAMIC_OOC_FINISHED group=$group"
}
exit
