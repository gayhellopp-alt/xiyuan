`timescale 1ns/1ps
module tb_ffn_protocol;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,cv=0,iv=0,branch=0,ready=0;
    logic [15:0] m=0,h=0,row=0,col=0;
    wire cr,ir,ov,last,task_last,busy,done,nsat,os,gs,clip;
    wire [1:0] error_code;
    wire signed [7:0] data;
    wire [15:0] orow,og,oi,scale;
    wire [31:0] absmax;
    ffn_bridge #(.GROUP_SIZE(12),.CAPACITY(8)) dut(
        .clk(clk),.rst(rst),.cfg_valid(cv),.cfg_ready(cr),.cfg_m(m),.cfg_h(h),
        .in_valid(iv),.in_branch(branch),.in_ready(ir),.in_row(row),.in_col(col),.in_data(32'sd0),
        .out_valid(ov),.out_ready(ready),.out_data(data),.out_row(orow),.out_group(og),.out_index(oi),
        .out_scale(scale),.out_last(last),.out_task_last(task_last),.out_saturated(os),.group_saturated(gs),
        .scale_clipped(clip),.group_absmax(absmax),.nonlinear_saturated(nsat),.busy(busy),.done(done),.error_code(error_code));
    integer checks=0,rejected=0,outputs=0;
    task automatic require(input bit ok,input string msg);
        checks++;if(!ok)$fatal(1,"FFN_PROTOCOL_CHECK_FAILED: %s",msg);
    endtask
    task automatic configure(input integer mm,hh,expected);
        @(negedge clk);require(cr,"descriptor ready");m=mm;h=hh;cv=1;
        @(posedge clk);#1;
        if(expected==0) require(busy && ir && !done && error_code==0,"valid descriptor accepted");
        else begin require(!busy && done && !ir && error_code==expected,"descriptor rejected");rejected++;end
        @(negedge clk);cv=0;
    endtask
    task automatic send(input integer rr,cc,bb,expected);
        @(negedge clk);require(ir,"collect ready");row=rr;col=cc;branch=bb;iv=1;
        @(posedge clk);#1;
        if(expected!=0)begin require(done && !busy && error_code==expected,"bad coordinate rejected");rejected++;end
        @(negedge clk);iv=0;
    endtask
    initial begin #2000000;$fatal(1,"FFN_PROTOCOL_TIMEOUT");end
    initial begin
        repeat(3) @(negedge clk);rst=0;
        configure(0,1,1);configure(1,0,1);configure(1,65,1);configure(2,5,1);
        configure(1,2,0);send(0,0,0,0);send(0,0,0,2);
        configure(1,2,0);send(0,2,1,2);
        // Both branches interleaved, reverse coordinates, exactly capacity.
        for(integer job=0;job<2;job++)begin
            configure(job==0?1:2,job==0?8:4,0);
            for(integer idx=7;idx>=0;idx--)begin send(idx/h,idx%h,idx%2,0);send(idx/h,idx%h,1-idx%2,0);end
            wait(ov);repeat(100) begin @(negedge clk);require(ov && !cr && !ir,"long backpressure owns both buffers");end
            ready=1;
            for(integer idx=0;idx<8;idx++)begin
                integer timeout;timeout=0;
                // A new row/group first collects up to 12 scalar pairs, then computes scale.
                while(!ov)begin @(negedge clk);timeout++;require(timeout<250,"protocol watchdog");end
                require(data==0 && scale==1 && absmax==0 && !clip && !os && !gs && !nsat,"zero group contract");
                require(orow==idx/h && og==0 && oi==idx%h && last==(idx%h==h-1) && task_last==(idx==7),"row/group/tail metadata");
                @(posedge clk);#1;require(done==(idx==7),"completion only on final accepted output");outputs++;
                @(negedge clk);
            end
            ready=0;require(cr && !busy,"ownership released");
        end
        require(rejected==6 && outputs==16,"protocol coverage");
        $display("FFN_PROTOCOL_TESTS_PASS rejected=%0d outputs=%0d checks=%0d",rejected,outputs,checks);$finish;
    end
endmodule
