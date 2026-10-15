// Independent transaction/state counters and synchronous RAM/RAW scoreboards.
integer slot_report,count_init=0,count_save=0,count_out_req=0,count_issue=0,count_retire=0,raw_checks=0;
bit snapshot_written[0:1][0:ROWS*COLS-1],y_initialized[0:ROWS*COLS-1];
logic signed [63:0] expected_y[0:ROWS*COLS-1];
always @(posedge clk) begin: valid_slot_memory_monitor
    bit check_read,check_write;
    integer read_bank,read_addr,write_addr;
    logic signed [31:0] expected_psum;
    logic signed [63:0] read_y,write_y,term;
    check_read=0;check_write=0;
    if(rst || (start && start_ready)) begin
        count_init=0;count_save=0;count_out_req=0;count_issue=0;count_retire=0;raw_checks=0;
        for(integer p=0;p<ROWS*COLS;p++) begin
            y_initialized[p]=0;expected_y[p]=0;
            for(integer b=0;b<2;b++) snapshot_written[b][p]=0;
        end
    end else if(busy && checking) begin
        if(dut.state==dut.INIT_Y) begin
            if(dut.slot==0) for(integer p=0;p<ROWS*COLS;p++) begin y_initialized[p]=0;expected_y[p]=0;end
            if(VALID_ONLY) require(dut.slot_valid,"INIT_Y touches only valid coordinates");
            y_initialized[dut.slot]=1;expected_y[dut.slot]=0;count_init++;
        end
        if(dut.state==dut.WAIT_PSUM && dut.psum_state[dut.psum_prod]==dut.P_FREE)
            for(integer p=0;p<ROWS*COLS;p++) snapshot_written[dut.psum_prod][p]=0;
        if(dut.psum_write) begin
            require(!snapshot_written[dut.psum_prod][dut.slot],"snapshot address written once");
            if(VALID_ONLY) require(dut.slot_valid,"SAVE_G touches only valid coordinates");
            snapshot_written[dut.psum_prod][dut.slot]=1;count_save++;
        end
        if(dut.state==dut.OUT_REQ) begin
            if(VALID_ONLY) require(dut.slot_valid,"output read requests only valid coordinates");
            require(y_initialized[dut.slot],"output address initialized in this tile");count_out_req++;
        end
        if(dut.p_issue) begin
            integer r,c,g,index;
            read_bank=dut.psum_cons;read_addr=dut.issue_slot;
            r=dut.psum_m[read_bank]+read_addr/COLS;c=dut.psum_n[read_bank]+read_addr%COLS;g=dut.psum_group[read_bank];
            index=(r*ng+g)*n+c;
            require(snapshot_written[read_bank][read_addr] && y_initialized[read_addr],"read owned and initialized psum/Y");
            if(VALID_ONLY) require(dut.post_slot_valid && r<m && c<n,"post read/scale only valid coordinates");
            expected_psum=(r<m && c<n)?psum_golden[index]:32'sd0;
            read_y=expected_y[read_addr];check_read=1;count_issue++;
        end
        if(dut.p_issue && dut.p_retire) begin
            require(dut.issue_slot!=dut.tag1,"no same-address Y read/write RAW collision");raw_checks++;
        end
        if(dut.p_retire) begin
            integer r,c,g,index;
            write_addr=dut.tag1;
            r=dut.psum_m[dut.psum_cons]+write_addr/COLS;c=dut.psum_n[dut.psum_cons]+write_addr%COLS;g=dut.psum_group[dut.psum_cons];
            index=(r*ng+g)*n+c;
            if(VALID_ONLY) require(r<m && c<n,"retire valid tagged coordinate");
            term=(r<m && c<n)?$signed(psum_golden[index])*$signed({1'b0,memory.sx[r*ng+g][15:0]})*$signed({1'b0,memory.sw[g*n+c][15:0]}):64'sd0;
            write_y=expected_y[write_addr]+term;
            require(dut.y_write===write_y,"unrounded INT64 group merge exact");
            expected_y[write_addr]=write_y;check_write=1;count_retire++;
        end
        #1;
        if(check_read) begin
            require(dut.psum_q[read_bank]===expected_psum,"one-cycle synchronous psum read");
            require(dut.y_q===read_y,"one-cycle synchronous Y read and prior-group value");
        end
        if(check_write) require(dut.output_accumulator.mem[write_addr]===write_y,"one-cycle synchronous Y write");
    end
end
