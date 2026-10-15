`timescale 1ns/1ps
// Reuse the preserved packet source, bounded to MAX_DATA; only the testbench
// fills its arrays. This is not a synthesizable DMA or infinite-port memory.
module chain_layer #(parameter integer GROUP_SIZE=32)(
    input logic clk,rst,start,
    input logic [15:0] cfg_m,cfg_n,cfg_k,
    input integer mode,m,n,k,ng,
    input logic out_ready,
    output wire start_ready,busy,done,error,out_valid,out_last,
    output wire [15:0] out_m,out_n,
    output wire signed [31:0] out_data,
    output wire [31:0] total_cycles,weight_bytes,activation_bytes,scale_bytes,input_beats
);
    wire req_valid,req_ready,in_valid,in_ready,req_scale,req_activation;
    wire [15:0] req_m,req_n,req_k,req_ml,req_nl,req_kl,req_group;
    wire [63:0] in_data;wire [7:0] in_keep;
    wire load_pause=mode==1 && memory.ticks%11<3;
    wire post_pause=mode==1 && memory.ticks%17<4;
    wire array_pause=mode==1 && memory.ticks%13<3;
    w4a8_wave #(.GROUP_SIZE(GROUP_SIZE)) core(
        .clk(clk),.rst(rst),.load_pause(load_pause),.post_pause(post_pause),.array_pause(array_pause),
        .start(start),.start_ready(start_ready),.busy(busy),.done(done),.error(error),
        .cfg_m(cfg_m),.cfg_n(cfg_n),.cfg_k(cfg_k),
        .req_valid(req_valid),.req_ready(req_ready),.req_scale(req_scale),.req_activation(req_activation),
        .req_m(req_m),.req_n(req_n),.req_k(req_k),.req_ml(req_ml),.req_nl(req_nl),.req_kl(req_kl),.req_group(req_group),
        .in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),.in_keep(in_keep),
        .out_valid(out_valid),.out_ready(out_ready),.out_m(out_m),.out_n(out_n),.out_last(out_last),.out_data(out_data),
        .total_cycles(total_cycles),.weight_bytes(weight_bytes),.activation_bytes(activation_bytes),.scale_bytes(scale_bytes),.input_beats(input_beats));
    w4a8_reuse_memory #(.GROUP_SIZE(GROUP_SIZE),.MAX_DATA(4096)) memory(
        .clk(clk),.rst(rst),.task_start(start && start_ready),.mode(mode==0?0:2),.m(m),.n(n),.k(k),.ng(ng),
        .req_valid(req_valid),.req_ready(req_ready),.req_scale(req_scale),.req_activation(req_activation),
        .req_m(req_m),.req_n(req_n),.req_k(req_k),.req_ml(req_ml),.req_nl(req_nl),.req_kl(req_kl),.req_group(req_group),
        .in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),.in_keep(in_keep));
endmodule

module tb_chain_base #(parameter integer GROUP_SIZE=32);
    localparam integer FIRST_GROUP=GROUP_SIZE==32?12:32;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,start1=0,start2=0;
    logic [15:0] cm=0,ck=0,ch=0,cn=0;
    integer m=0,k=0,h=0,n=0,ng1=0,ng2=0,mode=0;
    wire ready1,busy1,done1,error1,v1,last1,ready2,busy2,done2,error2,v2,last2;
    wire [15:0] row1,col1,row2,col2;
    wire signed [31:0] data1,data2;
    wire [31:0] cycles1,wb1,ab1,sb1,beats1,cycles2,wb2,ab2,sb2,beats2;
    logic force_stall1=0,force_stall2=0;
    integer ticks=0;
    wire out_ready1=!force_stall1 && (mode==0 || ticks%9>=3);
    wire out_ready2=!force_stall2 && (mode==0 || ticks%7>=2);
    chain_layer #(.GROUP_SIZE(FIRST_GROUP)) first(
        .clk(clk),.rst(rst),.start(start1),.cfg_m(cm),.cfg_n(ch),.cfg_k(ck),.mode(mode),.m(m),.n(h),.k(k),.ng(ng1),
        .out_ready(out_ready1),.start_ready(ready1),.busy(busy1),.done(done1),.error(error1),.out_valid(v1),.out_last(last1),
        .out_m(row1),.out_n(col1),.out_data(data1),.total_cycles(cycles1),.weight_bytes(wb1),.activation_bytes(ab1),.scale_bytes(sb1),.input_beats(beats1));
    chain_layer #(.GROUP_SIZE(GROUP_SIZE)) second(
        .clk(clk),.rst(rst),.start(start2),.cfg_m(cm),.cfg_n(cn),.cfg_k(ch),.mode(mode),.m(m),.n(n),.k(h),.ng(ng2),
        .out_ready(out_ready2),.start_ready(ready2),.busy(busy2),.done(done2),.error(error2),.out_valid(v2),.out_last(last2),
        .out_m(row2),.out_n(col2),.out_data(data2),.total_cycles(cycles2),.weight_bytes(wb2),.activation_bytes(ab2),.scale_bytes(sb2),.input_beats(beats2));
    logic cfg_valid=0,in_valid=0,in_pause=0,d_ready=0;
    wire cfg_ready,in_ready,d_valid,d_last,d_sat,d_group_sat,d_clip,d_busy,d_done;
    logic [15:0] cfg_row=0,cfg_group=0,cfg_k=0,cfg_len=0;
    wire signed [7:0] d_data;
    wire [15:0] d_row,d_group,d_index,d_scale;
    wire [31:0] d_absmax;
    wire [1:0] d_error;
    logic adapter_rd=0;
    logic [8:0] adapter_addr=0;
    wire [31:0] adapter_q;
    wire adapter_wr=!rst && v1 && out_ready1;
    // One synchronous write and one synchronous read, depth 512 Q16.16 elements.
    sync_sdp_ram #(.WIDTH(32),.DEPTH(512),.STYLE("block")) adapter(
        .clk(clk),.wr_en(adapter_wr),.wr_addr(9'(row1*h+col1)),.wr_data(data1),
        .rd_en(adapter_rd && !rst),.rd_addr(adapter_addr),.rd_data(adapter_q));
    requant_dynamic #(.GROUP_SIZE(GROUP_SIZE)) dynamic_quant(
        .clk(clk),.rst(rst),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_row(cfg_row),.cfg_group(cfg_group),.cfg_k(cfg_k),.cfg_len(cfg_len),
        .in_valid(in_valid),.in_pause(in_pause),.in_ready(in_ready),.in_data($signed(adapter_q)),
        .out_valid(d_valid),.out_ready(d_ready),.out_data(d_data),.out_row(d_row),.out_group(d_group),.out_index(d_index),.out_scale(d_scale),
        .out_last(d_last),.out_saturated(d_sat),.group_saturated(d_group_sat),.scale_clipped(d_clip),.group_absmax(d_absmax),
        .busy(d_busy),.done(d_done),.error_code(d_error));
    integer y1[0:511],y2[0:511],p1[0:4095],p2[0:4095],qgold[0:511],sgold[0:511],clipgold[0:511],satgold[0:511];
    logic [31:0] absmaxgold[0:511];
    bit seen1[0:511],seen2[0:511],seenq[0:511],seenscale[0:511];
    integer checks=0,tasks=0,aborts=0,outputs1=0,outputs2=0,qoutputs=0,psums1=0,psums2=0,scaled_checks=0,reordered=0,adapter_reads=0;
    integer count1=0,count2=0,countq=0,scale_count=0,sat_count=0,clip_count=0;
    integer fd,csv,scan,ncases,cid,job,md,begin_tick,dynamic_begin,dynamic_cycles;
    integer active_row,active_group,active_index;
    bit checking=0,held1=0,held2=0,heldq=0;
    logic [64:0] old1,old2;
    logic [107:0] oldq;
    wire [107:0] qpayload={d_row,d_group,d_index,d_scale,d_last,d_sat,d_data,d_group_sat,d_clip,d_absmax};
    task automatic require(input bit ok,input string msg);
        checks++;if(!ok) $fatal(1,"CHAIN_CHECK_FAILED id=%0d tick=%0d: %s",cid,ticks,msg);
    endtask
    always @(posedge clk) begin
        ticks++;
        if(rst) begin held1=0;held2=0;heldq=0;end
        else begin
            if(held1) require(v1 && {row1,col1,last1,data1}===old1,"first output backpressure holds");
            if(held2) require(v2 && {row2,col2,last2,data2}===old2,"second output backpressure holds");
            if(heldq) require(d_valid && qpayload===oldq,"quant output backpressure holds");
            held1=v1 && !out_ready1;held2=v2 && !out_ready2;heldq=d_valid && !d_ready;
            old1={row1,col1,last1,data1};old2={row2,col2,last2,data2};oldq=qpayload;
            if(checking) begin
                require(!error1 && !error2 && d_error==0,"no unexpected stage errors");
                if(adapter_rd) begin
                    require(!adapter_wr && adapter_addr<m*h && seen1[adapter_addr],"sync adapter read initialized coordinate");adapter_reads++;
                end
                if(v1 && out_ready1) begin
                    integer index;index=row1*h+col1;
                    require(row1<m && col1<h && !seen1[index],"first coordinates exactly once");
                    require(data1===y1[index],"layer1 Q16.16 exact");
                    require(last1==(row1==m-1 && col1==h-1),"first last");
                    if(index!=count1) reordered++;
                    seen1[index]=1;count1++;outputs1++;
                end
                if(d_valid && d_ready) begin
                    integer index,sindex;index=d_row*h+d_group*GROUP_SIZE+d_index;sindex=d_row*ng2+d_group;
                    require(d_row==active_row && d_group==active_group && d_index==active_index,"second-layer group namespace and order");
                    require(index<m*h && !seenq[index] && $signed(d_data)==qgold[index],"qx exact and unique");
                    require(d_scale==sgold[sindex] && d_clip==clipgold[sindex] && d_absmax==absmaxgold[sindex],"sx/absmax/status exact");
                    require(d_sat==satgold[index],"quant saturation exact");
                    seenq[index]=1;countq++;qoutputs++;sat_count+=d_sat;
                    second.memory.a[index]=$signed(d_data);
                    if(d_index==0) begin
                        require(!seenscale[sindex],"sx stored once per row/group");
                        seenscale[sindex]=1;scale_count++;clip_count+=d_clip;second.memory.sx[sindex]=d_scale;
                    end
                end
                if(v2 && out_ready2) begin
                    integer index;index=row2*n+col2;
                    require(row2<m && col2<n && !seen2[index],"second coordinates exactly once");
                    require(data2===y2[index],"layer2 Q16.16 exact");require(last2==(row2==m-1 && col2==n-1),"second last");
                    seen2[index]=1;count2++;outputs2++;
                end
                if(first.core.psum_write && first.core.slot_valid) begin
                    integer r,col,idx;r=first.core.mt+first.core.slot/4;col=first.core.nt+first.core.slot%4;
                    idx=(r*ng1+first.core.ck/FIRST_GROUP)*h+col;
                    require(first.core.acc[first.core.slot]===p1[idx],"layer1 group psum exact");psums1++;
                end
                if(second.core.psum_write && second.core.slot_valid) begin
                    integer r,col,idx;r=second.core.mt+second.core.slot/4;col=second.core.nt+second.core.slot%4;
                    idx=(r*ng2+second.core.ck/GROUP_SIZE)*n+col;
                    require(second.core.acc[second.core.slot]===p2[idx],"layer2 group psum exact");psums2++;
                end
                if(first.core.p_retire) begin
                    integer r,col,g,idx;r=first.core.psum_m[first.core.psum_cons]+first.core.tag1/4;col=first.core.psum_n[first.core.psum_cons]+first.core.tag1%4;g=first.core.psum_group[first.core.psum_cons];idx=(r*ng1+g)*h+col;
                    if(r<m && col<h) begin
                        require(first.core.scaled==$signed(p1[idx])*$signed({1'b0,first.memory.sx[r*ng1+g][15:0]})*$signed({1'b0,first.memory.sw[g*h+col][15:0]}),"layer1 scaled snapshot exact");scaled_checks++;
                    end
                end
                if(second.core.p_retire) begin
                    integer r,col,g,idx;r=second.core.psum_m[second.core.psum_cons]+second.core.tag1/4;col=second.core.psum_n[second.core.psum_cons]+second.core.tag1%4;g=second.core.psum_group[second.core.psum_cons];idx=(r*ng2+g)*n+col;
                    if(r<m && col<n) begin
                        require(second.core.scaled==$signed(p2[idx])*$signed({1'b0,second.memory.sx[r*ng2+g][15:0]})*$signed({1'b0,second.memory.sw[g*n+col][15:0]}),"layer2 independently supplied sw exact");scaled_checks++;
                    end
                end
            end
        end
    end
    task automatic reset_all;
        @(negedge clk);rst=1;start1=0;start2=0;cfg_valid=0;in_valid=0;in_pause=0;d_ready=0;adapter_rd=0;checking=0;
        force_stall1=0;force_stall2=0;
        @(posedge clk);#1;require(!busy1 && !busy2 && !d_busy && !v1 && !v2 && !d_valid,"reset cancels all pipeline stages");
        @(negedge clk);rst=0;repeat(3) @(negedge clk);
    endtask
    task automatic init_scoreboard;
        for(integer i=0;i<512;i++) begin seen1[i]=0;seen2[i]=0;seenq[i]=0;seenscale[i]=0;end
        count1=0;count2=0;countq=0;scale_count=0;sat_count=0;clip_count=0;
    endtask
    task automatic launch(input bit second_layer);
        @(negedge clk);
        if(second_layer) begin require(ready2,"second ready");start2=1;end
        else begin require(ready1,"first ready");start1=1;end
        @(posedge clk);#1;@(negedge clk);start1=0;start2=0;
    endtask
    task automatic run_job(input integer test_mode,reset_phase);
        integer timeout,len;
        mode=test_mode;init_scoreboard();checking=1;begin_tick=ticks;dynamic_cycles=0;
        force_stall1=0;force_stall2=(reset_phase==6);launch(0);
        if(reset_phase==1) begin wait(first.core.state==first.core.RUN);reset_all();aborts++;return;end
        timeout=0;while(!done1) begin @(negedge clk);timeout++;require(timeout<200000,"layer1 watchdog");end
        require(count1==m*h,"all first output coordinates assembled before group read");
        dynamic_begin=ticks;
        for(integer r=0;r<m;r++) for(integer g=0;g<ng2;g++) begin
            active_row=r;active_group=g;len=(h-g*GROUP_SIZE<GROUP_SIZE)?h-g*GROUP_SIZE:GROUP_SIZE;
            @(negedge clk);require(cfg_ready,"dynamic next descriptor ready");cfg_valid=1;cfg_row=r;cfg_group=g;cfg_k=h;cfg_len=len;
            @(posedge clk);#1;require(d_busy && !d_done,"dynamic descriptor accepted");
            @(negedge clk);cfg_valid=0;d_ready=0;
            for(integer i=0;i<len;i++) begin
                adapter_addr=9'(r*h+g*GROUP_SIZE+i);adapter_rd=1;
                @(posedge clk);#1;@(negedge clk);adapter_rd=0;in_valid=1;
                if(mode==1 && i%3==0) begin in_pause=1;repeat(3) @(negedge clk);in_pause=0;end
                @(posedge clk);require(in_ready,"dynamic collect synchronized RAM word");
                @(negedge clk);in_valid=0;
                if(reset_phase==2 && r==0 && g==0 && i==0) begin reset_all();aborts++;return;end
            end
            if(reset_phase==3 && r==0 && g==0) begin wait(dynamic_quant.state==dynamic_quant.SCALE_DIV);repeat(9) @(negedge clk);reset_all();aborts++;return;end
            for(integer i=0;i<len;i++) begin
                active_index=i;timeout=0;
                while(!d_valid) begin @(negedge clk);timeout++;require(timeout<200,"dynamic output watchdog");end
                if(reset_phase==4 && r==0 && g==0 && i==0) begin repeat(10) @(negedge clk);reset_all();aborts++;return;end
                if(mode==1) repeat(7+i%4) @(negedge clk);
                d_ready=1;@(posedge clk);#1;require(d_done==(i==len-1),"dynamic completion fence");
                @(negedge clk);d_ready=0;
            end
        end
        dynamic_cycles=ticks-dynamic_begin;
        require(countq==m*h && scale_count==m*ng2,"all qx/sx initialized before second layer");
        launch(1);
        if(reset_phase==5) begin wait(second.core.state==second.core.RUN);reset_all();aborts++;return;end
        if(reset_phase==6) begin wait(v2);repeat(12) @(negedge clk);reset_all();aborts++;return;end
        timeout=0;while(!done2) begin @(negedge clk);timeout++;require(timeout<200000,"layer2 watchdog");end
        require(count2==m*n,"complete final output");checking=0;tasks++;
        $fwrite(csv,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",GROUP_SIZE,cid,mode,m,k,h,n,ticks-begin_tick,cycles1,dynamic_cycles,cycles2,count1,countq,count2,scale_count,clip_count,sat_count,wb1+wb2,ab1+ab2,sb1+sb2,beats1+beats2,4*m*h);
    endtask
    initial begin
        if($test$plusargs("FORCE_TIMEOUT")) begin #100000;$fatal(1,"CHAIN_TIMEOUT");end
        #20000000;$fatal(1,"CHAIN_TIMEOUT");
    end
    initial begin
        csv=$fopen("results.csv","w");$fwrite(csv,"group_size,case,mode,m,k,h,n,total_cycles,layer1_cycles,dynamic_cycles,layer2_cycles,y1,qx,y2,scales,clipped,saturated,weight_bytes,activation_bytes,scale_bytes,input_beats,adapter_write_bytes\n");
        reset_all();fd=$fopen("vectors.txt","r");scan=$fscanf(fd,"%d",ncases);require(scan==1,"chain case count");
        for(job=0;job<ncases;job++) begin
            scan=$fscanf(fd,"%d %d %d %d %d %d %d",cid,m,k,h,n,ng1,ng2);require(scan==7 && m*h<=512 && m<=64 && h<=64 && n<=64 && k<=4096,"bounded chain descriptor within preserved W4A8 capacities");cm=m;ck=k;ch=h;cn=n;
            for(integer i=0;i<m*k;i++) scan=$fscanf(fd,"%d",first.memory.a[i]);
            for(integer i=0;i<h*((k+1)/2);i++) scan=$fscanf(fd,"%d",first.memory.packed_w[i]);
            for(integer i=0;i<m*ng1;i++) scan=$fscanf(fd,"%d",first.memory.sx[i]);
            for(integer i=0;i<ng1*h;i++) scan=$fscanf(fd,"%d",first.memory.sw[i]);
            for(integer i=0;i<m*h;i++) scan=$fscanf(fd,"%d",y1[i]);
            for(integer i=0;i<m*ng1*h;i++) scan=$fscanf(fd,"%d",p1[i]);
            for(integer i=0;i<m*h;i++) scan=$fscanf(fd,"%d",qgold[i]);
            for(integer i=0;i<m*ng2;i++) scan=$fscanf(fd,"%d",sgold[i]);
            for(integer i=0;i<m*ng2;i++) scan=$fscanf(fd,"%d",clipgold[i]);
            for(integer i=0;i<m*h;i++) scan=$fscanf(fd,"%d",satgold[i]);
            for(integer i=0;i<m*ng2;i++) scan=$fscanf(fd,"%d",absmaxgold[i]);
            for(integer i=0;i<n*((h+1)/2);i++) scan=$fscanf(fd,"%d",second.memory.packed_w[i]);
            for(integer i=0;i<ng2*n;i++) scan=$fscanf(fd,"%d",second.memory.sw[i]);
            for(integer i=0;i<m*n;i++) scan=$fscanf(fd,"%d",y2[i]);
            for(integer i=0;i<m*ng2*n;i++) scan=$fscanf(fd,"%d",p2[i]);
            require(scan==1 && ng1==(k+FIRST_GROUP-1)/FIRST_GROUP && ng2==(h+GROUP_SIZE-1)/GROUP_SIZE,"complete chain vectors and independent group layouts");
            if($test$plusargs("CORRUPT_EXPECTED") && job==0) y2[0]++;
            for(md=0;md<2;md++) run_job(md,0);
            if(job==1) for(integer phase=1;phase<=6;phase++) begin run_job(1,phase);run_job(1,0);end
        end
        require(tasks==16 && aborts==6 && reordered>0 && psums1>0 && psums2>0 && scaled_checks>0,"chain coverage");
        $fclose(fd);$fclose(csv);
        $display("CHAIN_TESTS_PASS group_size=%0d tasks=%0d aborts=%0d y1=%0d qx=%0d y2=%0d checks=%0d p1=%0d p2=%0d scaled=%0d reordered=%0d adapter_reads=%0d",GROUP_SIZE,tasks,aborts,outputs1,qoutputs,outputs2,checks,psums1,psums2,scaled_checks,reordered,adapter_reads);
        $finish;
    end
endmodule
module tb_w4a8_two_layer;tb_chain_base #(.GROUP_SIZE(32)) test();endmodule
module tb_w4a8_two_layer12;tb_chain_base #(.GROUP_SIZE(12)) test();endmodule
