`timescale 1ns/1ps
module tb_swiglu_element;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,iv=0,ready=0;
    logic signed [31:0] gate=0,up=0;
    logic [15:0] row=0,col=0;
    wire ir,ov,sat;
    wire signed [31:0] silu,data;
    wire [15:0] orow,ocol;
    swiglu_element dut(.clk(clk),.rst(rst),.in_valid(iv),.in_ready(ir),.in_gate(gate),.in_up(up),
        .in_row(row),.in_col(col),.out_valid(ov),.out_ready(ready),.out_silu(silu),.out_data(data),
        .out_saturated(sat),.out_row(orow),.out_col(ocol));
    integer checks=0,outputs=0,aborts=0,held_cycles=0,fd,scan,ncases,gs,gp,gf;
    bit held=0;
    logic [96:0] previous;
    wire [96:0] payload={orow,ocol,silu,data,sat};
    task automatic require(input bit ok,input string msg);
        checks++;if(!ok)$fatal(1,"SWIGLU_CHECK_FAILED: %s",msg);
    endtask
    always @(posedge clk) begin
        if(rst) held=0;
        else begin
            if(held) begin require(ov && payload===previous,"output holds under backpressure");held_cycles++;end
            held=ov && !ready;previous=payload;
        end
    end
    task automatic reset;
        @(negedge clk);rst=1;iv=0;ready=0;
        @(posedge clk);#1;require(!ov && !ir,"reset cancels pipeline");
        @(negedge clk);rst=0;
    endtask
    task automatic run(input integer id,mode);
        integer timeout;
        @(negedge clk);require(ir,"next scalar ready");row=16'(id/64);col=16'(id%64);iv=1;
        @(posedge clk);#1;@(negedge clk);iv=0;
        timeout=0;while(!ov) begin @(negedge clk);timeout++;require(timeout<12,"scalar watchdog");end
        require(timeout==6,"six clocks from accepted input to valid output");
        require(silu===gs && data===gp && sat==gf && orow==row && ocol==col,"bit exact result and tags");
        if(mode==1) begin
            repeat(4+id%7) begin @(negedge clk);require(ov && !ready,"deliberate output stall");end
        end
        ready=1;@(posedge clk);#1;require(!ov,"single output acceptance");outputs++;
        @(negedge clk);ready=0;
    endtask
    initial begin
        if($test$plusargs("FORCE_TIMEOUT"))begin #100000;$fatal(1,"SWIGLU_TIMEOUT");end
        #20000000;$fatal(1,"SWIGLU_TIMEOUT");
    end
    initial begin
        reset();fd=$fopen("vectors.txt","r");scan=$fscanf(fd,"%d",ncases);require(scan==1,"unit header");
        for(integer i=0;i<ncases;i++)begin
            scan=$fscanf(fd,"%d %d %d %d %d",gate,up,gs,gp,gf);require(scan==5,"complete unit vector");
            if($test$plusargs("CORRUPT_EXPECTED") && i==0)gp++;
            run(i,0);run(i,1);
        end
        gate=65536;up=65536;gs=47911;gp=47911;gf=0;
        // Use file-derived golden, never a different formula inside RTL tests.
        $fclose(fd);fd=$fopen("vectors.txt","r");scan=$fscanf(fd,"%d",ncases);
        scan=$fscanf(fd,"%d %d %d %d %d",gate,up,gs,gp,gf);
        for(integer phase=1;phase<=7;phase++)begin
            @(negedge clk);iv=1;@(posedge clk);#1;@(negedge clk);iv=0;
            wait(dut.state==phase);reset();aborts++;run(phase,1);
        end
        $display("SWIGLU_COVERAGE cases=%0d outputs=%0d aborts=%0d held=%0d",ncases,outputs,aborts,held_cycles);
        require(outputs==2*ncases+7 && aborts==7 && held_cycles>500,"scalar coverage");
        $display("SWIGLU_TESTS_PASS cases=%0d outputs=%0d aborts=%0d held=%0d checks=%0d",ncases,outputs,aborts,held_cycles,checks);
        $finish;
    end
endmodule
