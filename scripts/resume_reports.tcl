set root [file normalize [file join [file dirname [info script]] ..]]
set optimized 1
if {[llength $argv]>1} {set optimized [lindex $argv 1]}
set double_buffer 1
if {[llength $argv]>2} {set double_buffer [lindex $argv 2]}
set out [file join $root build [expr {$optimized ? ($double_buffer ? "synth_db" : "synth_opt") : "synth"}]]
set impl 0
if {[llength $argv]>0} {set impl [lindex $argv 0]}
open_checkpoint [file join $out synthesized.dcp]
set part [get_property PART [current_design]]
if {![string match *vu9p* $part]} {puts "ERROR: checkpoint is not VU9P"; exit 2}
puts "RESUMED_VALID_SYNTH_CHECKPOINT=$part"
source [file join $root scripts finalize_reports.tcl]
