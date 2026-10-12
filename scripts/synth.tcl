set root [file normalize [file join [file dirname [info script]] ..]]
set optimized 1
if {[llength $argv]>1} {set optimized [lindex $argv 1]}
set double_buffer 1
if {[llength $argv]>2} {set double_buffer [lindex $argv 2]}
set out [file join $root build [expr {$optimized ? ($double_buffer ? "synth_db" : "synth_opt") : "synth"}]]
file mkdir $out
set f [open [file join $root build selected_part.txt] r]
set part [string trim [read $f]]
close $f
if {![string match *vu9p* $part] || [llength [get_parts -quiet $part]] != 1} {
    puts "ERROR: selected VU9P part is not installed: $part"
    exit 2
}
set impl 0
if {[llength $argv]>0} {set impl [lindex $argv 0]}
foreach name {sync_sdp_ram mac_pe mac_array tile_buffer b_pingpong matmul_top} {
    read_verilog -sv [file join $root rtl ${name}.sv]
}
read_xdc [file join $root constraints clock.xdc]
synth_design -top matmul_top -part $part -mode out_of_context -flatten_hierarchy rebuilt -generic [list OPTIMIZED=$optimized DOUBLE_BUFFER=$double_buffer B_LOAD_GAP=0]
write_checkpoint -force [file join $out synthesized.dcp]
source [file join $root scripts finalize_reports.tcl]
