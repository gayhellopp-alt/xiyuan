"""One-time derivation of the isolated valid-slot baseline and inherited TB.

The generated RTL/TB are checked in as standalone sources; normal validation
does not invoke this generator or modify the preserved wave implementation.
"""
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]


def once(s,old,new):
    assert s.count(old)==1,(old,s.count(old))
    return s.replace(old,new)


def main():
    check_only='--check' in sys.argv
    s=(ROOT/'rtl/w4a8_wave.sv').read_text(encoding='utf8')
    s=once(s,'module w4a8_wave #(','module w4a8_valid #(')
    s=once(s,'parameter bit A_REUSE=1,SYSTOLIC=1,GROUP_STREAM=1','parameter bit A_REUSE=1,SYSTOLIC=1,GROUP_STREAM=1,VALID_ONLY=1')
    s=once(s,'    logic slot_valid;','''    logic slot_valid;
    // Sparse canonical addresses; skip holes, never change PE/coordinate mapping.
    function automatic [15:0] last_slot(input logic [15:0] ml,nl);
        last_slot=VALID_ONLY ? (ml-1)*COLS+nl-1 : RC-1;
    endfunction
    function automatic [15:0] next_slot(input logic [15:0] current_slot,nl);
        next_slot=(VALID_ONLY && current_slot%COLS+1==nl) ?
            current_slot+COLS-nl+1 : current_slot+1;
    endfunction''')
    s=once(s,'if(slot==RC-1) begin\n                slot<=0;ck<=0;', 'if(slot==last_slot(cm_len,cn_len)) begin\n                slot<=0;ck<=0;')
    s=once(s,'end else begin slot<=slot+1;state<=OUT_REQ;end','end else begin slot<=next_slot(slot,cn_len);state<=OUT_REQ;end')
    s=once(s,'if(issue_slot==RC-1) issue_done<=1;else issue_slot<=issue_slot+1;',
        'if(issue_slot==last_slot(psum_ml[psum_cons],psum_nl[psum_cons])) issue_done<=1;\n                        else issue_slot<=next_slot(issue_slot,psum_nl[psum_cons]);')
    s=once(s,'if(p_retire && tag1==RC-1) begin','if(p_retire && tag1==last_slot(psum_ml[psum_cons],psum_nl[psum_cons])) begin')
    s=once(s,'if(slot==RC-1) begin slot<=0;state<=WAIT_TILE;end else slot<=slot+1;',
        'if(slot==last_slot(cm_len,cn_len)) begin slot<=0;state<=WAIT_TILE;end\n                        else slot<=next_slot(slot,cn_len);')
    s=once(s,'SAVE_G: if(slot==RC-1) begin','SAVE_G: if(slot==last_slot(cm_len,cn_len)) begin')
    s=once(s,'end else slot<=slot+1;\n                    WAIT_POST:',
        'end else slot<=next_slot(slot,cn_len);\n                    WAIT_POST:')
    if check_only: assert (ROOT/'rtl/w4a8_valid.sv').read_text(encoding='utf8')==s
    else: (ROOT/'rtl/w4a8_valid.sv').write_text(s,encoding='utf8')

    t=(ROOT/'tb/tb_w4a8_wave.sv').read_text(encoding='utf8')
    t=t.replace('tb_w4a8_wave','tb_w4a8_valid').replace('W4A8_WAVE','W4A8_VALID')
    t=once(t,'parameter bit POST_OVERLAP=1,POST_PIPELINE=1,A_REUSE=1,SYSTOLIC=1,GROUP_STREAM=1;',
        'parameter bit POST_OVERLAP=1,POST_PIPELINE=1,A_REUSE=1,SYSTOLIC=1,GROUP_STREAM=1,VALID_ONLY=1;')
    t=once(t,'w4a8_wave #(','w4a8_valid #(')
    t=once(t,'.GROUP_STREAM(GROUP_STREAM)) dut(.*);','.GROUP_STREAM(GROUP_STREAM),.VALID_ONLY(VALID_ONLY)) dut(.*);')
    t=once(t,'post_issue_cycles==psum_groups*ROWS*COLS && post_retire_cycles==post_issue_cycles',
        'post_issue_cycles==(VALID_ONLY?m*n*ng:psum_groups*ROWS*COLS) && post_retire_cycles==post_issue_cycles')
    # All original math/PE/freeze/ownership checks remain; extra monitor is local.
    t=once(t,'    if(SYSTOLIC) begin: forwarding_monitor','''    `include "valid_slot_monitor.svh"
    if(SYSTOLIC) begin: forwarding_monitor''')
    # Add a separate CSV for independently counted state/transaction totals.
    t=once(t,'        tasks++;','''        $fdisplay(slot_report,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
            case_id,recovery,mode,VALID_ONLY,count_init,count_save,count_out_req,count_issue,count_retire,raw_checks);
        require(count_init==(VALID_ONLY?m*n:((m+ROWS-1)/ROWS)*((n+COLS-1)/COLS)*ROWS*COLS),"initialized slot count");
        require(count_out_req==count_init && count_save==post_issue_cycles && count_issue==post_issue_cycles && count_retire==post_retire_cycles,"independent valid/full slot totals");
        tasks++;''')
    t=once(t,'        report=$fopen("results.csv","w");require(report!=0,"report opened");','''        slot_report=$fopen("slots.csv","w");require(slot_report!=0,"slot report opened");
        $fdisplay(slot_report,"case_id,recovery,mode,VALID_ONLY,init_slots,saved_slots,out_req_slots,issued_slots,retired_slots,raw_checks");
        report=$fopen("results.csv","w");require(report!=0,"report opened");''')
    t=once(t,'        $fclose(report);','        $fclose(report);$fclose(slot_report);')
    t=once(t,'    initial begin #20000000;$fatal(1,"W4A8_VALID_GLOBAL_TIMEOUT");end',
        '''    initial begin
        if($test$plusargs("FORCE_TIMEOUT")) begin #100000;$fatal(1,"W4A8_VALID_GLOBAL_TIMEOUT");end
        #20000000;$fatal(1,"W4A8_VALID_GLOBAL_TIMEOUT");
    end''')
    t+= '''\nmodule tb_w4a8_valid_base4;tb_w4a8_valid #(.VALID_ONLY(0)) test();endmodule
module tb_w4a8_valid_base8;tb_w4a8_valid #(.ROWS(8),.COLS(8),.VALID_ONLY(0)) test();endmodule
'''
    if check_only: assert (ROOT/'tb/tb_w4a8_valid.sv').read_text(encoding='utf8')==t
    else: (ROOT/'tb/tb_w4a8_valid.sv').write_text(t,encoding='utf8')
    print('VALID_VARIANT_GENERATOR_CHECK_PASS' if check_only else 'VALID_VARIANT_CREATED preserved rtl/w4a8_wave.sv and tb/tb_w4a8_wave.sv')


if __name__=='__main__':main()
