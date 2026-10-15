set kv_project_root [lindex $argv 0]
if {[info exists ::env(XILINX_VIVADO)]} {
    lappend auto_path [file join $::env(XILINX_VIVADO) data XilinxTclStore support appinit]
    foreach appdir [glob -nocomplain -types d [file join $::env(XILINX_VIVADO) data XilinxTclStore tclapp * *]] {lappend auto_path $appdir}
}
package require ::tclapp::support::appinit 1.2
foreach name {kv_cache_pkg kv_cache_address storage_axi_byte_write w4a8_axi_read kv_cache} {
    read_verilog -sv [file join $kv_project_root rtl $name.sv]
}
synth_design -top kv_cache -part xcvu9p-flga2104-2L-e -mode out_of_context
create_clock -period 10 [get_ports clk]
report_utilization -file utilization.rpt
report_timing_summary -file timing_synth.rpt
report_drc -file drc.rpt
if {[llength [get_cells -hier -filter {IS_BLACKBOX == 1}]]!=0} {error "KV black boxes"}
write_checkpoint -force kv_cache.dcp
puts KV_SYNTHESIS_PASS
