`timescale 1ns/1ps
module tb_requant_base #(parameter integer GROUP_SIZE=32);
    logic clk=0, rst=1;
    always #5 clk=~clk;
    logic cfg_valid=0, in_valid=0, in_pause=0, out_ready=0;
    wire cfg_ready, in_ready, out_valid, busy, done, group_saturated;
    logic [15:0] cfg_row=0, cfg_group=0, cfg_k=0, cfg_len=0, cfg_scale=0;
    logic signed [31:0] in_data=0;
    wire signed [7:0] out_data;
    wire out_saturated, out_last;
    wire [15:0] out_row,out_group,out_index,out_scale;
    wire [1:0] error_code;
    requant_group #(.GROUP_SIZE(GROUP_SIZE)) dut(.*);
    integer checks=0, outputs=0, groups=0, rejects=0, resets=0, held_checks=0;
    integer tick=0, csv, ncases, scan, fd, c, mode, len, rowid, gid, kval, scale;
    integer value[0:4095], golden[0:4095], sat[0:4095];
    integer qindex=0, received=0, cumulative_sat=0, input_tick=0, previous_input=0;
    integer group_begin=0, first_input=0, last_output=0, input_stalls=0, output_stalls=0;
    integer min_latency=1000000,max_latency=0, min_ii=1000000,max_ii=0;
    bit checking=0, held=0, corrupt=0;
    logic [74:0] previous_payload;
    wire [74:0] payload={out_row,out_group,out_index,out_scale,out_last,out_saturated,out_data,group_saturated};
    task automatic require(input bit condition,input string message);
        begin
            checks++;
            if(!condition) begin
                $display("REQUANT_CHECK_FAILED group_size=%0d tick=%0d case=%0d index=%0d: %s",GROUP_SIZE,tick,c,qindex,message);
                $fatal(1,"REQUANT_CHECK_FAILED");
            end
        end
    endtask
    always @(posedge clk) begin
        tick++;
        if(rst) held=0;
        else begin
            if(held) begin require(out_valid && payload===previous_payload,"output and all metadata hold under backpressure"); held_checks++; end
            held=out_valid && !out_ready; previous_payload=payload;
            if(checking) begin
                if(in_valid && !in_ready) input_stalls++;
                if(out_valid && !out_ready) output_stalls++;
                if(in_valid && in_ready) begin
                    require(!out_valid,"one scalar owns divider/output");
                    input_tick=tick;
                    if(received==0) first_input=tick;
                    else begin
                        if(tick-previous_input<min_ii) min_ii=tick-previous_input;
                        if(tick-previous_input>max_ii) max_ii=tick-previous_input;
                        if(mode==0) require(tick-previous_input==35,"continuous scalar initiation interval is 35 clocks");
                    end
                    previous_input=tick;
                end
                // First visible out_valid is sampled 34 edges after input handshake.
                if(out_valid) begin
                    require(tick-input_tick>=34,"output cannot appear early");
                    require($signed(out_data)==golden[received],"bit-exact quantized data");
                    require(out_saturated==sat[received],"element saturation flag");
                    require(out_row==rowid && out_group==gid && out_scale==scale,"descriptor metadata");
                    require(out_index==received && out_last==(received==len-1),"index/length/last");
                    require(!cfg_ready && !in_ready && busy && !done,"group and scalar ownership");
                end
                if(out_valid && out_ready) begin
                    if(mode==0) require(tick-input_tick==34,"continuous input-to-output handshake is 34 clocks");
                    if(tick-input_tick<min_latency) min_latency=tick-input_tick;
                    if(tick-input_tick>max_latency) max_latency=tick-input_tick;
                    cumulative_sat |= sat[received];
                    require(group_saturated==cumulative_sat,"group saturation accumulates");
                    received++; outputs++; last_output=tick;
                end
            end
        end
    end
    task automatic reset_now;
        begin
            @(negedge clk); rst=1; cfg_valid=0; in_valid=0; in_pause=0; out_ready=0; checking=0;
            @(posedge clk); #1;
            require(!busy && !done && error_code==0 && !out_valid && !in_ready && !cfg_ready && !group_saturated,"reset cancels activity and status");
            @(negedge clk); rst=0; resets++;
            repeat(2) @(negedge clk);
            require(cfg_ready && !busy && !out_valid && !done,"idle after reset");
        end
    endtask
    task automatic descriptor(input integer r,g,k,l,s,err);
        begin
            @(negedge clk);
            cfg_valid=1; cfg_row=r; cfg_group=g; cfg_k=k; cfg_len=l; cfg_scale=s;
            require(cfg_ready,"descriptor accepted only while idle");
            @(posedge clk); #1;
            require(error_code==err,"descriptor error priority/code");
            if(err!=0) begin
                require(done && !busy && !out_valid && !in_ready,"rejected descriptor consumes no data"); rejects++;
            end else require(busy && !cfg_ready && !done && !group_saturated,"accepted descriptor owns group");
            @(negedge clk); cfg_valid=0;
            if(err!=0) begin
                @(posedge clk); #1;
                require(!done && error_code==err && !busy,"done pulses, error persists until next descriptor");
            end
        end
    endtask
    task automatic run_case;
        integer waitcycles;
        begin
            descriptor(rowid,gid,kval,len,scale,0);
            received=0; cumulative_sat=0; input_stalls=0; output_stalls=0;
            group_begin=tick; checking=1;
            for(qindex=0;qindex<len;qindex++) begin
                if(mode==1) repeat((qindex+c)%5) @(negedge clk);
                in_valid=1; in_data=value[qindex];
                if(mode==1 && qindex%3==0) begin
                    in_pause=1; repeat(4) @(negedge clk);
                    require(!in_ready,"explicit input pause"); in_pause=0;
                end
                // All payload remains stable until accepted; one-edge early NBA safe.
                do begin @(posedge clk); end while(!in_ready);
                @(negedge clk); in_valid=0;
                // Send a pending descriptor during activity; must not replace tags.
                cfg_valid=1; cfg_scale=1; cfg_row=16'hffff; cfg_group=16'hffff;
                waitcycles=0;
                while(!out_valid) begin
                    @(negedge clk); waitcycles++;
                    require(waitcycles<100,"per-element timeout");
                    require(!cfg_ready,"busy blocks replacement descriptor");
                end
                cfg_valid=0;
                if(mode==1) begin
                    out_ready=0; repeat(10+(qindex+c)%7) @(negedge clk);
                    if(qindex==0) repeat(40) @(negedge clk);
                end
                out_ready=1;
                @(posedge clk); #1;
                require(received==qindex+1,"exactly one accepted output per input");
                require(done==(qindex==len-1),"done only after final output acceptance");
                require(error_code==0,"busy cfg ignored");
                @(negedge clk); out_ready=(mode==0);
            end
            checking=0; groups++;
            require(!busy && cfg_ready,"final output releases group");
            $fwrite(csv,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",GROUP_SIZE,c,mode,len,scale,last_output-group_begin,first_input-group_begin,last_output-first_input,input_stalls,output_stalls);
            @(posedge clk); #1; require(!done,"completion is one clock pulse");
        end
    endtask
    task automatic active_reset(input integer delay_clocks,input bit held_output);
        begin
            descriptor(7,1,GROUP_SIZE+2,2,1,0);
            @(negedge clk); in_valid=1; in_data=32'sh80000000;
            @(posedge clk); require(in_ready,"reset test input accepted");
            @(negedge clk); in_valid=0;
            if(held_output) begin
                while(!out_valid) @(negedge clk);
                repeat(12) @(negedge clk);
            end else repeat(delay_clocks) @(negedge clk);
            require(busy,"reset during owned group"); reset_now();
            repeat(45) begin @(negedge clk); require(!out_valid && !done,"no stale output after reset"); end
        end
    endtask
    initial begin
        if($test$plusargs("FORCE_TIMEOUT")) begin
            #100000; $fatal(1,"REQUANT_TIMEOUT");
        end
        #20000000; $fatal(1,"REQUANT_TIMEOUT");
    end
    initial begin
        corrupt=$test$plusargs("CORRUPT_EXPECTED");
        csv=$fopen("results.csv","w"); require(csv!=0,"open results");
        $fwrite(csv,"group_size,case,mode,length,scale,cycles_from_cfg_following_negedge,first_input_delta,output_span,input_stalls,output_stalls\n");
        reset_now();
        descriptor(0,0,1,1,0,1);
        descriptor(0,0,0,0,0,2);
        descriptor(0,0,4097,GROUP_SIZE,1,2);
        descriptor(0,0,GROUP_SIZE,0,1,2);
        descriptor(0,0,GROUP_SIZE,GROUP_SIZE+1,1,2);
        descriptor(0,1,GROUP_SIZE,GROUP_SIZE,1,2);
        descriptor(0,65535,4096,1,1,2);
        descriptor(0,1,GROUP_SIZE+3,2,1,2);
        descriptor(0,1,GROUP_SIZE+3,4,0,2);
        // Reset waiting for input, during division first/last iterations, rounding,
        // and output backpressure; then recover with all vectors below.
        descriptor(1,0,1,1,1,0); reset_now();
        active_reset(0,0); active_reset(15,0); active_reset(31,0); active_reset(32,0); active_reset(0,1);
        for(mode=0;mode<2;mode++) begin
            fd=$fopen("vectors.txt","r"); require(fd!=0,"open vectors");
            scan=$fscanf(fd,"%d",ncases); require(scan==1,"read case count");
            for(c=0;c<ncases;c++) begin
                scan=$fscanf(fd,"%d %d %d %d %d",rowid,gid,kval,len,scale); require(scan==5 && len<=GROUP_SIZE,"read descriptor");
                for(integer i=0;i<len;i++) begin
                    scan=$fscanf(fd,"%d %d %d",value[i],golden[i],sat[i]); require(scan==3,"read element");
                end
                if(corrupt && c==0 && mode==0) golden[0]=golden[0]+1;
                out_ready=(mode==0); run_case();
            end
            $fclose(fd);
        end
        // Reset mid-group after a successfully transferred scalar.
        descriptor(0,0,2,2,1,0); out_ready=1;
        @(negedge clk); in_valid=1; in_data=8;
        @(posedge clk); require(in_ready,"midgroup input accepted");
        @(negedge clk); in_valid=0;
        while(!out_valid) @(negedge clk);
        @(posedge clk); #1; require(busy && !done,"nonfinal output keeps group");
        reset_now();
        // One clean group verifies recovery after the final reset.
        mode=0; len=1; rowid=65535; gid=0; kval=1; scale=1;
        value[0]=-8; golden[0]=-1; sat[0]=0; out_ready=1; run_case();
        require(held_checks>0 && rejects==9 && resets==8,"coverage counts");
        require(min_latency==34 && min_ii==35,"minimum measured latency/II");
        $fclose(csv);
        $display("REQUANT_TESTS_PASS group_size=%0d groups=%0d outputs=%0d checks=%0d rejects=%0d resets=%0d held_checks=%0d min_latency=%0d max_latency=%0d min_ii=%0d max_ii=%0d",GROUP_SIZE,groups,outputs,checks,rejects,resets,held_checks,min_latency,max_latency,min_ii,max_ii);
        $finish;
    end
endmodule
module tb_requant_group; tb_requant_base #(.GROUP_SIZE(32)) test(); endmodule
module tb_requant_group12; tb_requant_base #(.GROUP_SIZE(12)) test(); endmodule
