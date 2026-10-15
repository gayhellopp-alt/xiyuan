`timescale 1ns/1ps
module tb_dynamic_base #(parameter integer GROUP_SIZE=32);
    logic clk=0;always #5 clk=~clk;
    logic rst=1,cfg_valid=0,in_valid=0,in_pause=0,out_ready=0;
    logic [15:0] cfg_row=0,cfg_group=0,cfg_k=0,cfg_len=0;
    logic signed [31:0] in_data=0;
    wire cfg_ready,in_ready,out_valid,out_last,out_saturated,group_saturated,scale_clipped,busy,done;
    wire signed [7:0] out_data;
    wire [15:0] out_row,out_group,out_index,out_scale;
    wire [31:0] group_absmax;
    wire [1:0] error_code;
    requant_dynamic #(.GROUP_SIZE(GROUP_SIZE)) dut(.*);
    integer value[0:4095],golden[0:4095],sat[0:4095];
    integer tick=0,checks=0,outputs=0,groups=0,held_checks=0,ram_reads=0,ram_writes=0,rejects=0,resets=0;
    integer fd,csv,scan,ncases,c,mode,len,rowid,gid,kval,scale,clip,received,cumsat,begin_tick,last_input,last_out;
    integer stalls=0,min_first=1000000,max_first=0;
    logic [31:0] absmax_expected;
    logic [107:0] old_payload;
    wire [107:0] payload={out_row,out_group,out_index,out_scale,out_last,out_saturated,out_data,group_saturated,scale_clipped,group_absmax};
    bit held=0,checking=0;
    task automatic require(input bit ok,input string msg);
        checks++;if(!ok) $fatal(1,"DYNAMIC_CHECK_FAILED case=%0d tick=%0d: %s",c,tick,msg);
    endtask
    always @(posedge clk) begin
        tick++;
        if(rst) held=0;
        else begin
            if(held) begin require(out_valid && payload===old_payload,"output metadata stable under backpressure");held_checks++;end
            held=out_valid && !out_ready;old_payload=payload;
            if(dut.wr_en) begin ram_writes++;require(dut.state==dut.COLLECT && dut.write_index<dut.length,"owned synchronous write");end
            if(dut.rd_en) begin ram_reads++;require(dut.state==dut.READ_REQ && dut.read_index<dut.length && !dut.wr_en,"owned synchronous read");end
            if(checking) begin
                if(out_valid && !out_ready) stalls++;
                if(out_valid) begin
                    require(received<len && $signed(out_data)==golden[received],"bit-exact dynamic qx");
                    require(out_scale==scale && scale_clipped==clip && group_absmax==absmax_expected,"scale/absmax/range status");
                    require(out_saturated==sat[received],"element saturation");
                    require(out_row==rowid && out_group==gid && out_index==received && out_last==(received==len-1),"row/group/index/last");
                    require(busy && !cfg_ready && !in_ready && !done,"buffer ownership to output acceptance");
                end
                if(out_valid && out_ready) begin
                    if(received==0) begin
                        if(tick-last_input<min_first) min_first=tick-last_input;
                        if(tick-last_input>max_first) max_first=tick-last_input;
                        if(mode==0) require(tick-last_input==70,"first output 70 clocks after final collection");
                    end else if(mode==0) require(tick-last_out==36,"buffer read plus scalar II=36");
                    cumsat|=sat[received];require(group_saturated==cumsat,"group saturation OR");
                    received++;outputs++;last_out=tick;
                end
            end
        end
    end
    task automatic reset_now;
        @(negedge clk);rst=1;cfg_valid=0;in_valid=0;in_pause=0;out_ready=0;checking=0;
        @(posedge clk);#1;require(!busy && !done && !out_valid && error_code==0 && !scale_clipped && group_absmax==0 && !group_saturated,"reset clears ownership/status");
        @(negedge clk);rst=0;resets++;
        repeat(2) @(negedge clk);require(cfg_ready && !out_valid,"reset idle");
    endtask
    task automatic descriptor(input integer r,g,k,l,err);
        @(negedge clk);cfg_valid=1;cfg_row=r;cfg_group=g;cfg_k=k;cfg_len=l;
        require(cfg_ready,"descriptor ready");@(posedge clk);#1;
        require(error_code==err && done==(err!=0),"descriptor rejection/status");
        require(busy==(err==0),"descriptor busy");
        if(err!=0) rejects++;
        @(negedge clk);cfg_valid=0;
    endtask
    task automatic run_group;
        integer start_reads,start_writes,timeout;
        descriptor(rowid,gid,kval,len,0);begin_tick=tick;received=0;cumsat=0;stalls=0;
        start_reads=ram_reads;start_writes=ram_writes;checking=1;out_ready=(mode==0);
        for(integer i=0;i<len;i++) begin
            if(mode==1) repeat((i+c)%4) @(negedge clk);
            in_data=value[i];in_valid=1;
            if(mode==1 && i%3==0) begin in_pause=1;repeat(3) @(negedge clk);require(!in_ready,"input pause");in_pause=0;end
            @(posedge clk);require(in_ready,"collect one scalar");#1;last_input=tick;
            @(negedge clk);in_valid=0;
        end
        require(!in_ready && !cfg_ready,"full group fenced");timeout=0;
        // Pending descriptor and data cannot overwrite the owned group.
        cfg_valid=1;cfg_row=16'hffff;cfg_group=16'hffff;in_valid=1;in_data=123;
        for(integer i=0;i<len;i++) begin
            while(!out_valid) begin @(negedge clk);timeout++;require(timeout<5000,"group watchdog");end
            cfg_valid=0;in_valid=0;
            if(mode==1) begin out_ready=0;repeat(8+(i%5)) @(negedge clk);if(i==0) repeat(40) @(negedge clk);end
            out_ready=1;@(posedge clk);#1;
            require(received==i+1 && done==(i==len-1),"completion only final accepted element");
            @(negedge clk);out_ready=(mode==0);
        end
        checking=0;groups++;require(cfg_ready && !busy,"last output releases group");
        require(ram_reads-start_reads==len && ram_writes-start_writes==len,"exactly len sync reads/writes");
        if(mode==0) require(last_out-begin_tick==37*len+34,"continuous group cycle formula");
        $fwrite(csv,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",GROUP_SIZE,c,mode,len,scale,clip,last_out-begin_tick,stalls,cumsat,absmax_expected);
        @(posedge clk);#1;require(!done && error_code==0,"done pulse");
    endtask
    task automatic reset_stage(input integer stage);
        descriptor(0,0,2,2,0);
        in_valid=1;in_data=32'sh80000000;@(posedge clk);@(negedge clk);in_valid=0;
        if(stage!=0) begin
            in_valid=1;in_data=32'sh7fffffff;@(posedge clk);@(negedge clk);in_valid=0;
            case(stage)
                1:repeat(12) @(negedge clk);
                2:wait(dut.state==dut.READ_REQ);
                3:wait(dut.scalar.state==dut.scalar.DIVIDE);
                4:begin wait(out_valid);repeat(15) @(negedge clk);end
            endcase
        end
        require(busy,"active reset stage");reset_now();
        repeat(80) begin @(negedge clk);require(!out_valid && !done,"no stale RAM output after reset");end
    endtask
    initial begin
        if($test$plusargs("FORCE_TIMEOUT")) begin #100000;$fatal(1,"DYNAMIC_TIMEOUT");end
        #20000000;$fatal(1,"DYNAMIC_TIMEOUT");
    end
    initial begin
        csv=$fopen("results.csv","w");$fwrite(csv,"group_size,case,mode,length,scale,clipped,cycles,output_stalls,saturated,absmax\n");
        reset_now();descriptor(0,0,0,0,2);descriptor(0,0,4097,GROUP_SIZE,2);descriptor(0,0,GROUP_SIZE,0,2);
        descriptor(0,1,GROUP_SIZE,1,2);descriptor(0,1,GROUP_SIZE+3,2,2);descriptor(0,65535,4096,1,2);
        for(integer stage=0;stage<5;stage++) reset_stage(stage);
        for(mode=0;mode<2;mode++) begin
            fd=$fopen("vectors.txt","r");scan=$fscanf(fd,"%d",ncases);require(scan==1,"case count");
            for(c=0;c<ncases;c++) begin
                scan=$fscanf(fd,"%d %d %d %d %d %d %d",rowid,gid,kval,len,scale,clip,absmax_expected);require(scan==7,"descriptor vector");
                for(integer i=0;i<len;i++) begin scan=$fscanf(fd,"%d %d %d",value[i],golden[i],sat[i]);require(scan==3,"element vector");end
                if($test$plusargs("CORRUPT_EXPECTED") && c==0 && mode==0) golden[0]++;
                run_group();
            end
            $fclose(fd);
        end
        require(held_checks>0 && rejects==6 && resets==6 && min_first==70,"coverage counters");
        $fclose(csv);
        $display("DYNAMIC_TESTS_PASS group_size=%0d groups=%0d outputs=%0d checks=%0d rejects=%0d resets=%0d held=%0d reads=%0d writes=%0d min_first=%0d max_first=%0d",GROUP_SIZE,groups,outputs,checks,rejects,resets,held_checks,ram_reads,ram_writes,min_first,max_first);
        $finish;
    end
endmodule
module tb_requant_dynamic;tb_dynamic_base #(.GROUP_SIZE(32)) test();endmodule
module tb_requant_dynamic12;tb_dynamic_base #(.GROUP_SIZE(12)) test();endmodule
