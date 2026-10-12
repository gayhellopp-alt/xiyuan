set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build synth_npu]
file mkdir $out
set f [open [file join $root build selected_part.txt] r]
set part [string trim [read $f]]
close $f
if {![string match *vu9p* $part] || [llength [get_parts -quiet $part]] != 1} {
    puts "ERROR: selected VU9P part is not installed: $part"; exit 2
}
set optimized 1
set double_buffer 1
set impl 0
if {[llength $argv]} {set impl [lindex $argv 0]}
foreach name {sync_sdp_ram mac_pe mac_array tile_buffer b_pingpong matmul_top npu_top} {
    read_verilog -sv [file join $root rtl $name.sv]
}
read_xdc [file join $root constraints clock.xdc]
synth_design -top npu_top -part $part -mode out_of_context -flatten_hierarchy rebuilt
write_checkpoint -force [file join $out synthesized.dcp]
set f [open [file join $out npu_configuration.txt] w]
puts $f "Top=npu_top QUEUE_DEPTH=4 OPCODE_GEMM=1 Completion_ack_required=1"
puts $f "Resident_shared_buffers=1 Queue_descriptor_bits=72"
close $f
source [file join $root scripts finalize_reports.tcl]
