set memory_project_root [file dirname [file dirname [info script]]]
if {[llength $argv]>0} {set memory_project_root [lindex $argv 0]}
# Session-local package lookup; supports installs with a stale user TclStore catalog.
# Does not modify the user's Vivado configuration or installation.
if {[info exists ::env(XILINX_VIVADO)]} {
    lappend auto_path [file join $::env(XILINX_VIVADO) data XilinxTclStore support appinit]
    foreach appdir [glob -nocomplain -types d [file join $::env(XILINX_VIVADO) data XilinxTclStore tclapp * *]] {
        lappend auto_path $appdir
    }
}
package require ::tclapp::support::appinit 1.2
foreach name {w4a8_memory_pkg w4a8_memory_validate w4a8_axi_read w4a8_axi_write w4a8_memory_packet w4a8_memory_bridge} {
    puts "MEMORY_SYNTH_SOURCE [file join $memory_project_root rtl $name.sv]"
    read_verilog -sv [file join $memory_project_root rtl $name.sv]
}
# Storage adapter only. No TB memory and no unified control top in the source set.
synth_design -top w4a8_memory_bridge -part xcvu9p-flga2104-2L-e -mode out_of_context
create_clock -name clk -period 10 [get_ports clk]
report_utilization -file utilization.rpt
report_timing_summary -file timing_synth.rpt
report_drc -file drc.rpt
set blackboxes [get_cells -hier -filter {IS_BLACKBOX == 1}]
if {[llength $blackboxes] != 0} {error "Storage contains black boxes"}
write_checkpoint -force w4a8_memory.dcp
puts W4A8_MEMORY_SYNTHESIS_PASS
