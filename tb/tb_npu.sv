`timescale 1ns/1ps
module tb_npu;
    parameter integer ROWS=4,COLS=4,TILE_K=8,QUEUE_DEPTH=4;
    logic clk=0;
    always #5 clk=~clk;
    logic rst=1,pause=0,wr_valid=0,wr_matrix=0,cmd_valid=0;
    logic wr_ready,cmd_ready,completion_valid,completion_ready=0;
    logic [15:0] wr_row=0,wr_col=0,cmd_tag=0,cmd_m=0,cmd_n=0,cmd_k=0;
    logic signed [7:0] wr_data=0;
    logic [7:0] cmd_opcode=0,completion_status;
    logic [15:0] completion_tag,completion_m,completion_n,completion_k;
    logic [31:0] completion_cycles,completion_active_cycles;
    logic rd_req=0,rd_ready,rd_valid;
    logic [15:0] rd_row=0,rd_col=0;
    wire signed [31:0] rd_data;
    logic busy,buffers_locked,result_available;
    logic [$clog2(QUEUE_DEPTH+1)-1:0] queued_count;
    npu_top #(.ROWS(ROWS),.COLS(COLS),.TILE_K(TILE_K),.QUEUE_DEPTH(QUEUE_DEPTH)) dut(.*);
    integer a[0:511],b[0:511],golden[0:15][0:255];
    integer op[0:15],tag[0:15],mm[0:15],nn[0:15],kk[0:15],status[0:15];
    integer f,rc,groups,group_id,jobs,g,j,x,r,c,report;
    integer checks=0,comparisons=0,completed=0,full_stalls=0,simultaneous=0;
    integer complete_holds=0,write_blocks=0,pause_cycles=0,max_queued=0;
    integer resets=0,reset_outputs=0;
    bit held=0;
    logic [135:0] held_payload;
    wire [135:0] payload={completion_tag,completion_m,completion_n,completion_k,
                         completion_status,completion_cycles,completion_active_cycles};
    task automatic require(input bit ok,input string message);
        checks++;
        if(!ok) $fatal(1,"NPU_CHECK_FAILED: %s time=%0t",message,$time);
    endtask
    always @(posedge clk) begin
        if(!rst) begin
            require(queued_count<=QUEUE_DEPTH,"FIFO bounded");
            if(held) require(completion_valid && payload===held_payload,"completion stable under backpressure");
            held=completion_valid && !completion_ready;
            held_payload=payload;
            if(cmd_valid && !cmd_ready) full_stalls++;
            if(dut.push && dut.pop) simultaneous++;
            if(completion_valid && !completion_ready) complete_holds++;
            if(wr_valid && !wr_ready && buffers_locked) write_blocks++;
            if(pause) pause_cycles++;
            if(queued_count>max_queued) max_queued=queued_count;
        end else held=0;
    end
    task automatic reset_device;
        @(negedge clk);rst=1;pause=0;cmd_valid=0;wr_valid=0;rd_req=0;completion_ready=0;
        repeat(3) @(posedge clk);
        #1;require(!busy && !buffers_locked && !completion_valid && !result_available &&
                   !rd_valid && queued_count==0,"reset cancels active queued and held jobs");
        @(negedge clk);rst=0;resets++;
    endtask
    task automatic send_job(input integer index,input integer override_tag);
        integer timeout_count;
        @(negedge clk);cmd_valid=1;cmd_opcode=op[index];
        cmd_tag=(override_tag<0)?tag[index]:override_tag;
        cmd_m=mm[index];cmd_n=nn[index];cmd_k=kk[index];
        timeout_count=0;
        while(!cmd_ready) begin
            @(negedge clk);timeout_count++;
            require(timeout_count<100000,"descriptor timeout");
        end
        @(posedge clk);#1;
        @(negedge clk);cmd_valid=0;
    endtask
    task automatic await_completion;
        integer timeout_count;
        timeout_count=0;
        while(!completion_valid) begin
            @(negedge clk);timeout_count++;
            require(timeout_count<100000,"completion timeout");
        end
    endtask
    task automatic read_result(input integer row_id,col_id,expected,input bit stall_read);
        @(negedge clk);rd_req=1;rd_row=row_id;rd_col=col_id;
        if(stall_read) begin
            pause=1;
            repeat(3) begin @(posedge clk);#1;require(!rd_ready && !rd_valid,"paused read blocked");end
            @(negedge clk);pause=0;
        end
        #1;require(rd_ready,"valid result read accepted");
        @(posedge clk);#1;require(rd_valid,"synchronous read response");
        require(rd_data===expected,"result matches Python golden");comparisons++;
        @(negedge clk);rd_req=0;
    endtask
    task automatic check_job(input integer index,input integer expected_tag,input bit stall_read);
        await_completion();
        require(completion_tag==expected_tag && completion_status==status[index],"ordered tag and status");
        require(completion_m==mm[index] && completion_n==nn[index] && completion_k==kk[index],"descriptor dimensions retained");
        if(status[index]==0) begin
            require(result_available && !busy,"result belongs to held completion");
            require(completion_active_cycles>0 && completion_cycles>=completion_active_cycles,"core performance metadata");
            for(integer rr=0;rr<mm[index];rr++)
                for(integer cc=0;cc<nn[index];cc++)
                    read_result(rr,cc,golden[index][rr*nn[index]+cc],stall_read && rr==0 && cc==0);
        end else begin
            require(!result_available && completion_cycles==0 && completion_active_cycles==0,
                    "rejected descriptor has no result or execution");
            @(negedge clk);rd_req=1;rd_row=0;rd_col=0;
            #1;require(!rd_ready,"invalid descriptor cannot expose previous result");
            @(posedge clk);#1;require(!rd_valid,"invalid descriptor produces no response");
            @(negedge clk);rd_req=0;
        end
    endtask
    task automatic acknowledge(input bit during_pause);
        @(negedge clk);completion_ready=1;pause=during_pause;
        // Assert a simultaneous new read: acknowledgement must win.
        rd_req=1;rd_row=0;rd_col=0;
        #1;require(completion_valid && !rd_ready,"ack wins over new read");
        @(posedge clk);#1;
        require(!completion_valid && !result_available,"completion consumed exactly once");
        require(!rd_valid,"no new response from ack edge");
        @(negedge clk);completion_ready=0;rd_req=0;pause=0;
    endtask
    initial begin
        f=$fopen("vectors.txt","r");require(f!=0,"vector file opened");
        report=$fopen("results.csv","w");require(report!=0,"report opened");
        $fdisplay(report,"group,job,tag,status,m,n,k,core_cycles,core_active_cycles,outputs");
        rc=$fscanf(f,"%d",groups);require(rc==1 && groups==3,"group header");
        reset_device();
        for(g=0;g<groups;g++) begin
            rc=$fscanf(f,"%d %d",group_id,jobs);require(rc==2 && jobs==12,"job header");
            for(x=0;x<512;x++) begin rc=$fscanf(f,"%d",a[x]);require(rc==1,"A data");end
            for(x=0;x<512;x++) begin rc=$fscanf(f,"%d",b[x]);require(rc==1,"B data");end
            for(j=0;j<jobs;j++) begin
                rc=$fscanf(f,"%d %d %d %d %d %d",op[j],tag[j],mm[j],nn[j],kk[j],status[j]);
                require(rc==6,"descriptor data");
                if(status[j]==0) for(x=0;x<mm[j]*nn[j];x++) begin
                    rc=$fscanf(f,"%d",golden[j][x]);require(rc==1,"golden data");
                end
            end
            // Full physical capacity initialization; all jobs reuse this exact buffer snapshot.
            for(x=0;x<1024;x++) begin
                @(negedge clk);wr_valid=1;wr_matrix=x>=512;
                wr_row=(x<512)?x/32:(x-512)/16;
                wr_col=(x<512)?x%32:(x-512)%16;
                wr_data=(x<512)?a[x]:b[x-512];
                #1;require(wr_ready && !buffers_locked,"unlocked load");
                @(posedge clk);#1;
            end
            @(negedge clk);wr_valid=0;
            fork
                begin: producer
                    // Back-to-back descriptors force a simultaneous enqueue/dequeue.
                    @(negedge clk);cmd_valid=1;cmd_opcode=op[0];cmd_tag=tag[0];
                    cmd_m=mm[0];cmd_n=nn[0];cmd_k=kk[0];
                    wr_valid=1;wr_matrix=0;wr_row=0;wr_col=0;wr_data=99;
                    #1;require(cmd_ready && !wr_ready,"descriptor wins over simultaneous input write");
                    @(posedge clk);#1;
                    @(negedge clk);wr_valid=0;cmd_opcode=op[1];cmd_tag=tag[1];
                    cmd_m=mm[1];cmd_n=nn[1];cmd_k=kk[1];
                    #1;require(cmd_ready,"second burst descriptor");
                    @(posedge clk);#1;
                    @(negedge clk);cmd_valid=0;
                    for(integer p=2;p<jobs;p++) begin
                        if(p==2) begin
                            @(negedge clk);pause=1;cmd_valid=1;cmd_opcode=op[p];cmd_tag=tag[p];
                            cmd_m=mm[p];cmd_n=nn[p];cmd_k=kk[p];
                            repeat(3) begin @(posedge clk);#1;require(!cmd_ready,"paused submission blocked");end
                            @(negedge clk);pause=0;cmd_valid=0;
                        end
                        send_job(p,-1);
                    end
                end
                begin: consumer
                    for(integer q=0;q<jobs;q++) begin
                        await_completion();
                        if(q==0) begin
                            // Keep full FIFO stalled; reject a poison input write while results are retained.
                            @(negedge clk);wr_valid=1;wr_matrix=0;wr_row=0;wr_col=0;wr_data=99;
                            repeat(12) begin @(posedge clk);#1;require(!wr_ready && !busy,"result hold blocks overwrite and next dispatch");end
                            @(negedge clk);wr_valid=0;
                        end
                        check_job(q,tag[q],q==0);
                        $fdisplay(report,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                            group_id,q,completion_tag,completion_status,completion_m,completion_n,completion_k,
                            completion_cycles,completion_active_cycles,(status[q]==0)?mm[q]*nn[q]:0);
                        acknowledge(q==2);completed++;
                    end
                end
            join
            @(negedge clk);require(!buffers_locked && queued_count==0,"batch drained");
        end
        $fclose(f);
        // Abort active execution with a nonempty FIFO. RAM remains resident.
        for(j=0;j<4;j++) send_job(1,800+j);
        repeat(15) @(negedge clk);
        require(busy && queued_count>0,"reset covers active and pending");
        reset_device();
        send_job(2,900);
        wait(dut.engine.done);
        @(negedge clk);pause=1;
        @(posedge clk);#1;require(completion_valid,"core done captured even when pause follows final edge");
        @(negedge clk);pause=0;
        check_job(2,900,0);reset_outputs+=mm[2]*nn[2];acknowledge(0);
        // Abort a held completion with queued work, then restart without RAM reload.
        send_job(0,850);send_job(1,851);await_completion();
        require(queued_count>0 && completion_valid,"reset covers held completion and queue");
        reset_device();
        send_job(2,901);check_job(2,901,0);reset_outputs+=mm[2]*nn[2];acknowledge(1);
        require(full_stalls>0 && max_queued==QUEUE_DEPTH,"full FIFO backpressure covered");
        require(simultaneous>0,"simultaneous push/pop covered");
        require(write_blocks>0 && pause_cycles>0 && complete_holds>0,"ownership pause completion backpressure covered");
        require(completed==36 && reset_outputs==18,"all descriptors and post-reset outputs checked");
        $fdisplay(report,"# checks=%0d comparisons=%0d full_stalls=%0d simultaneous=%0d holds=%0d resets=%0d",
                  checks,comparisons,full_stalls,simultaneous,complete_holds,resets);
        $fclose(report);
        $display("NPU_TESTS_PASS rows=%0d cols=%0d tile_k=%0d queue=%0d descriptors=%0d comparisons=%0d checks=%0d full_stalls=%0d simultaneous=%0d reset_jobs=2",
                 ROWS,COLS,TILE_K,QUEUE_DEPTH,completed,comparisons,checks,full_stalls,simultaneous);
        $finish;
    end
    initial begin #20000000;$fatal(1,"NPU_GLOBAL_TIMEOUT");end
endmodule
module tb_npu_alt;
    tb_npu #(.ROWS(2),.COLS(3),.TILE_K(5),.QUEUE_DEPTH(3)) test();
endmodule
