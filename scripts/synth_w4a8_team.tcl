set src [file normalize [file join [file dirname [info script]] ..]]
set names {task_desc_pkg w4a8_memory_pkg w4a8_memory_validate w4a8_axi_read w4a8_axi_write w4a8_memory_packet w4a8_memory_bridge sync_sdp_ram mac_pe mac_array systolic_pe systolic_array w4_unpack w4a8_wave w4a8_task_adapter w4a8_team_top}
foreach name $names {read_verilog -sv [file join $src rtl $name.sv]}
read_xdc [file join $src constraints clock.xdc]
synth_design -top w4a8_team_top -part xcvu9p-flga2104-2L-e -flatten_hierarchy rebuilt
write_checkpoint -force team_post_synth.dcp
report_utilization -file utilization.rpt
report_timing_summary -file timing.rpt
puts "W4A8_TEAM_SYNTHESIS_PASS"
exit
