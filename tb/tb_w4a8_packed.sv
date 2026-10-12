`timescale 1ns/1ps
module tb_w4a8_packed;
    parameter integer ROWS=4,COLS=4,TILE_K=8,GROUP_SIZE=32,MODES=3;
    parameter bit DOUBLE_BUFFER=1,SCALE_ONCE=1,PACK_COLS=1;
    parameter integer BUS_BYTES=8;
    localparam integer W_LANES=(PACK_COLS && BUS_BYTES==8)?2:1,W_BYTES=BUS_BYTES/W_LANES;
    integer dual_writes=0,holey_keeps=0,odd_k_requests=0;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,load_pause=0,start=0,start_ready,busy,done,error;
    logic [15:0] cfg_m=0,cfg_n=0,cfg_k=0;
    logic req_valid,req_ready,in_valid,in_ready,out_valid,out_ready=1,out_last;
    logic [15:0] req_m,req_n,req_k,req_ml,req_nl,req_kl,req_group,out_m,out_n;
    logic [BUS_BYTES*8-1:0] in_data;
    logic [BUS_BYTES-1:0] in_keep;
    logic req_scale;
    logic [31:0] input_beats,padding_bytes;
    logic signed [31:0] out_data;
    logic [31:0] total_cycles,weight_bytes,activation_bytes,scale_bytes,valid_macs,compute_cycles,
                       input_wait_cycles,output_wait_cycles,overlap_cycles;
    integer mode=0,m=0,n=0,k=0,ng=0;
    w4a8_packed #(.ROWS(ROWS),.COLS(COLS),.TILE_K(TILE_K),.GROUP_SIZE(GROUP_SIZE),
                   .DOUBLE_BUFFER(DOUBLE_BUFFER),.BUS_BYTES(BUS_BYTES),.SCALE_ONCE(SCALE_ONCE),.PACK_COLS(PACK_COLS)) dut(.*);
    w4a8_packed_memory #(.GROUP_SIZE(GROUP_SIZE),.BUS_BYTES(BUS_BYTES),.PACK_COLS(PACK_COLS)) memory(
        .clk(clk),.rst(rst),.task_start(start && start_ready),.mode(mode),.m(m),.n(n),.k(k),.ng(ng),
        .req_valid(req_valid),.req_ready(req_ready),.req_scale(req_scale),.req_m(req_m),.req_n(req_n),.req_k(req_k),
        .req_ml(req_ml),.req_nl(req_nl),.req_kl(req_kl),.req_group(req_group),
        .in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),.in_keep(in_keep));
    logic [7:0] unpack_byte=0;logic unpack_high=0;wire signed [7:0] unpack_value;
    w4_unpack unit_unpack(.packed_byte(unpack_byte),.high(unpack_high),.value(unpack_value));
    integer golden[0:4095],psum_golden[0:8191];
    bit seen[0:4095];
    integer f,rc,cases,cid,report,x,md,elapsed,outputs,groups_checked;
    integer eb,ep,wb,ew,ea,es,et,em,ec,ml,nl,len,mt,nt,q,checks=0,comparisons=0,psum_comparisons=0,tasks=0;
    integer ticks=0,all_overlap=0,all_input_wait=0,all_output_wait=0,held_input_checks=0;
    bit checking=0,force_output_stall=0,held_out=0,held_in=0,held_req=0,ready_overlap=0;
    logic [64:0] old_out;
    logic [BUS_BYTES*9-1:0] old_in;
    logic [112:0] old_req;
    wire [64:0] out_payload={out_m,out_n,out_last,out_data};
    wire [112:0] req_payload={req_m,req_n,req_k,req_ml,req_nl,req_kl,req_group,req_scale};
    task automatic require(input bit condition,input string message);
        checks++;
        if(!condition) $fatal(1,"W4A8_PACKED_CHECK_FAILED: %s time=%0t",message,$time);
    endtask
    always @(negedge clk) begin
        if(!rst) begin
            load_pause=(mode==2 && ticks%11<3);
            out_ready=!force_output_stall && (mode!=2 || ticks%7>=2);
        end
    end
    always @(posedge clk) begin
        ticks++;
        if(rst) begin held_out=0;held_in=0;held_req=0;end
        else begin
            if(held_out) require(out_valid && out_payload===old_out,"output stable during backpressure");
            if(held_in) begin require(in_valid && {in_keep,in_data}===old_in,"input byte stable during load pause");held_input_checks++;end
            if(held_req) require(req_valid && req_payload===old_req,"request stable during backpressure");
            held_out=out_valid && !out_ready;old_out=out_payload;
            held_in=in_valid && !in_ready;old_in={in_keep,in_data};
            held_req=req_valid && !req_ready;old_req=req_payload;
            if(busy && checking) begin
                elapsed++;
                if(req_valid && req_ready && req_k[0]) odd_k_requests++;
                if(in_valid && in_ready) begin
                    integer remaining;
                    require(dut.bank_state[dut.load_bank]==1,"loader owns LOADING bank");
                    case(dut.phase)
                        0:remaining=dut.bank_wbytes[dut.load_bank]-dut.load_pos;
                        1:remaining=dut.bank_kl[dut.load_bank]-dut.load_pos;
                        2:remaining=2*dut.bank_ml[dut.load_bank]-dut.load_pos;
                        3:remaining=2*dut.bank_nl[dut.load_bank]-dut.load_pos;
                    endcase
                    for(integer j=0;j<BUS_BYTES;j++)
                        if(dut.phase==0)
                            require(in_keep[j]==(j%W_BYTES<remaining && dut.load_lane+j/W_BYTES<dut.bank_nl[dut.load_bank]),"weight slot keep mask");
                        else require(in_keep[j]==(j<remaining),"nonweight keep mask");
                    if(dut.phase==0) begin
                        integer writes;
                        writes=$countones(dut.w_write);
                        require(writes==((dut.bank_nl[dut.load_bank]-dut.load_lane<W_LANES)?
                            dut.bank_nl[dut.load_bank]-dut.load_lane:W_LANES),"one write per valid weight bank");
                        if(writes==2) dual_writes++;
                        if(in_keep!=((1<<$countones(in_keep))-1)) holey_keeps++;
                    end
                end
                if(dut.read_tile) require(dut.bank_state[dut.consumer_bank]==3,"consumer owns COMPUTING bank");
                for(integer b=0;b<(DOUBLE_BUFFER?2:1);b++) begin
                    if(dut.bank_state[b]==2 && dut.bank_state[dut.consumer_bank]==3 && b!=dut.consumer_bank) ready_overlap=1;
                end
                if(dut.group_psum.wr_en && dut.slot_valid) begin
                    integer row,col,index;
                    row=dut.mt+dut.slot/COLS;col=dut.nt+dut.slot%COLS;
                    index=(row*ng+dut.ck/GROUP_SIZE)*n+col;
                    require(dut.acc[dut.slot]===psum_golden[index],"whole group integer psum matches reference");
                    groups_checked++;psum_comparisons++;
                end
                if(out_valid && out_ready) begin
                    integer index;
                    require(out_m<m && out_n<n,"valid output coordinates");
                    index=out_m*n+out_n;
                    require(!seen[index],"output exactly once");
                    require(out_data===golden[index],"bit-exact Q16.16 output");
                    require(out_last==(out_m==m-1 && out_n==n-1),"last flag");
                    seen[index]=1;outputs++;comparisons++;
                end
            end
        end
    end
    task automatic reset_device;
        @(negedge clk);rst=1;start=0;checking=0;force_output_stall=0;
        repeat(3) @(posedge clk);
        #1;require(!busy && !out_valid && !in_ready,"reset aborts work and pending output");
        @(negedge clk);rst=0;
    endtask
    task automatic launch;
        @(negedge clk);cfg_m=m;cfg_n=n;cfg_k=k;start=1;
        #1;require(start_ready,"start ready");
        @(posedge clk);#1;require(busy,"task accepted");
        @(negedge clk);start=0;
    endtask
    task automatic expected_traffic;
        ew=0;ea=0;es=0;et=0;eb=0;ep=0;
        for(mt=0;mt<m;mt+=ROWS) begin
            ml=(m-mt<ROWS)?m-mt:ROWS;
            for(nt=0;nt<n;nt+=COLS) begin
                nl=(n-nt<COLS)?n-nt:COLS;q=0;
                while(q<k) begin
                    len=TILE_K;
                    if(k-q<len) len=k-q;
                    if(GROUP_SIZE-q%GROUP_SIZE<len) len=GROUP_SIZE-q%GROUP_SIZE;
                    wb=(q%2+len+1)/2;
                    ew+=nl*wb;ea+=ml*len;et++;
                    eb+=((nl+W_LANES-1)/W_LANES)*((wb+W_BYTES-1)/W_BYTES)+ml*((len+BUS_BYTES-1)/BUS_BYTES);
                    if(!SCALE_ONCE || q+len==k || (q+len)%GROUP_SIZE==0) begin
                        es+=2*(ml+nl);
                        eb+=(2*ml+BUS_BYTES-1)/BUS_BYTES+(2*nl+BUS_BYTES-1)/BUS_BYTES;
                    end
                    q+=len;
                end
            end
        end
        ep=eb*BUS_BYTES-ew-ea-es;
        em=m*n*k;ec=((m+ROWS-1)/ROWS)*((n+COLS-1)/COLS)*k;
    endtask
    task automatic run_job(input integer case_id,feed_mode,input bit recovery);
        integer timeout_count;
        mode=feed_mode;elapsed=0;outputs=0;groups_checked=0;
        for(integer i=0;i<m*n;i++) seen[i]=0;
        launch();checking=1;
        // A busy start is rejected even if the caller changes configuration.
        @(negedge clk);start=1;cfg_m=0;cfg_n=0;cfg_k=0;
        #1;require(!start_ready,"busy refuses new start");
        @(posedge clk);#1;require(!error,"busy command did not change task");
        @(negedge clk);start=0;cfg_m=m;cfg_n=n;cfg_k=k;
        timeout_count=0;
        while(!done) begin
            @(negedge clk);timeout_count++;
            require(timeout_count<200000,"per-task timeout");
            require(!error,"no unexpected core error");
        end
        checking=0;expected_traffic();
        require(outputs==m*n && groups_checked==m*n*ng,"all outputs and groups checked");
        require(total_cycles==elapsed,"total cycle counter");
        require(weight_bytes==ew && activation_bytes==ea && scale_bytes==es,"accepted byte counters");
        require(valid_macs==em && compute_cycles==ec,"valid MAC and compute counters");
        require(memory.requests==et && memory.accepted==ew+ea+es,"memory packet totals");
        require(input_beats==eb && memory.beats==eb && padding_bytes==ep,"physical beat and padding counters");
        require(compute_cycles+input_wait_cycles+output_wait_cycles<=total_cycles,"exclusive critical-path classifications");
        if(!DOUBLE_BUFFER) require(overlap_cycles==0,"single bank cannot load during compute");
        all_overlap+=overlap_cycles;all_input_wait+=input_wait_cycles;all_output_wait+=output_wait_cycles;
        $fdisplay(report,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
            case_id,recovery,mode,ROWS,COLS,TILE_K,GROUP_SIZE,DOUBLE_BUFFER,m,n,k,
            total_cycles,weight_bytes,activation_bytes,scale_bytes,valid_macs,compute_cycles,
            input_wait_cycles,output_wait_cycles,overlap_cycles,BUS_BYTES,SCALE_ONCE,input_beats,padding_bytes,PACK_COLS);
        $display("W4A8_PACKED_CASE_PASS id=%0d recovery=%0d mode=%0d dims=%0dx%0dx%0d cycles=%0d mac=%0d overlap=%0d",
            case_id,recovery,mode,m,n,k,total_cycles,valid_macs,overlap_cycles);
        tasks++;
    endtask
    initial begin
        report=$fopen("results.csv","w");require(report!=0,"report opened");
        $fdisplay(report,"case_id,recovery,mode,ROWS,COLS,TILE_K,GROUP_SIZE,DOUBLE_BUFFER,M,N,K,total_cycles,weight_bytes,activation_bytes,scale_bytes,valid_macs,compute_cycles,input_wait_cycles,output_wait_cycles,overlap_cycles,BUS_BYTES,SCALE_ONCE,input_beats,padding_bytes,PACK_COLS");
        for(integer code=0;code<16;code++) begin
            unpack_byte=(code<<4)|code;
            unpack_high=0;#1;require(unpack_value==((code<8)?code:code-16),"all low nibble signed codes");
            unpack_high=1;#1;require(unpack_value==((code<8)?code:code-16),"all high nibble signed codes");
        end
        reset_device();
        @(negedge clk);start=1;cfg_m=0;cfg_n=1;cfg_k=1;
        @(posedge clk);#1;require(error && !busy,"invalid dimensions rejected");
        @(negedge clk);start=0;
        f=$fopen("vectors.txt","r");require(f!=0,"vectors opened");
        rc=$fscanf(f,"%d",cases);require(rc==1 && cases==12,"case header");
        for(integer job=0;job<cases;job++) begin
            rc=$fscanf(f,"%d %d %d %d %d",cid,m,n,k,ng);require(rc==5,"dimensions parsed");
            require(ng==(k+GROUP_SIZE-1)/GROUP_SIZE,"group count");
            for(x=0;x<m*k;x++) begin rc=$fscanf(f,"%d",memory.a[x]);require(rc==1,"activation vector");end
            for(x=0;x<n*((k+1)/2);x++) begin rc=$fscanf(f,"%d",memory.packed_w[x]);require(rc==1,"packed weights");end
            for(x=0;x<m*ng;x++) begin rc=$fscanf(f,"%d",memory.sx[x]);require(rc==1,"activation scales");end
            for(x=0;x<ng*n;x++) begin rc=$fscanf(f,"%d",memory.sw[x]);require(rc==1,"weight scales");end
            for(x=0;x<m*n;x++) begin rc=$fscanf(f,"%d",golden[x]);require(rc==1,"output golden");end
            for(x=0;x<m*ng*n;x++) begin rc=$fscanf(f,"%d",psum_golden[x]);require(rc==1,"psum golden");end
            for(md=0;md<MODES;md++) run_job(cid,md,0);
        if(MODES>1 && cid==10) begin
            // Random dataset; abort concurrently loading and computing.
            mode=2;launch();
            wait(dut.state==dut.RUN && (dut.loading || !DOUBLE_BUFFER));reset_device();
            run_job(cid,2,1);
            force_output_stall=1;mode=0;launch();wait(out_valid);
            repeat(5) @(negedge clk);reset_device();
            run_job(cid,0,1);
        end
        end
        $fclose(f);
        if(MODES>1) begin
            require(all_input_wait>0 && all_output_wait>0 && held_input_checks>0,"input delays/pause/output backpressure covered");
            if(DOUBLE_BUFFER) require(all_overlap>0 && ready_overlap,"load/compute overlap and ready bank covered");
        end
        $fclose(report);
        if(PACK_COLS && COLS>1) require(dual_writes>0 && holey_keeps>0,"paired writes and noncontiguous keeps covered");
        if(TILE_K%2 || GROUP_SIZE%2) require(odd_k_requests>0,"odd K starts covered");
        $display("W4A8_PACKED_TESTS_PASS rows=%0d cols=%0d tile=%0d group=%0d db=%0d tasks=%0d outputs=%0d psums=%0d checks=%0d overlap=%0d held_inputs=%0d bytes=%0d scale_once=%0d pack=%0d dual_writes=%0d holey_keeps=%0d odd_k=%0d",
            ROWS,COLS,TILE_K,GROUP_SIZE,DOUBLE_BUFFER,tasks,comparisons,psum_comparisons,checks,all_overlap,held_input_checks,BUS_BYTES,SCALE_ONCE,PACK_COLS,dual_writes,holey_keeps,odd_k_requests);
        $finish;
    end
    initial begin #20000000;$fatal(1,"W4A8_PACKED_GLOBAL_TIMEOUT");end
endmodule
module tb_w4a8_packed_unpacked;
    tb_w4a8_packed #(.PACK_COLS(0)) test();
endmodule
module tb_w4a8_packed_alt;
    tb_w4a8_packed #(.ROWS(2),.COLS(3),.TILE_K(5),.GROUP_SIZE(12)) test();
endmodule
module tb_w4a8_packed_words;
    tb_w4a8_packed #(.TILE_K(19)) test();
endmodule
module tb_w4a8_packed_single;
    tb_w4a8_packed #(.DOUBLE_BUFFER(0)) test();
endmodule
module tb_w4a8_packed_scales;
    tb_w4a8_packed #(.SCALE_ONCE(0)) test();
endmodule
module tb_w4a8_packed_directed;
    tb_w4a8_packed #(.MODES(1)) test();
endmodule
