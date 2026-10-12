`timescale 1ns/1ps
module tb_systolic_array;
    parameter integer ROWS=4,COLS=4;
    localparam integer D=ROWS+COLS-2,RC=ROWS*COLS;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,clear=0,advance=0,inject_valid=0;
    logic [15:0] valid_rows=ROWS,valid_cols=COLS;
    logic signed [7:0] a[0:ROWS-1],b[0:COLS-1];
    wire signed [31:0] acc[0:RC-1];
    wire [RC-1:0] pe_fire;
    systolic_array #(.ROWS(ROWS),.COLS(COLS)) dut(.*);
    integer history_a[0:2047][0:ROWS-1],history_b[0:2047][0:COLS-1];
    integer history_rows[0:2047],history_cols[0:2047];
    bit history_valid[0:2047];
    integer golden[0:RC-1];
    logic [49:0] before_link[0:RC-1];
    logic [8:0] before_a[0:ROWS-1],before_b[0:COLS-1];
    integer step=0,checks=0,macs=0,held=0,groups=0,resets=0;
    task automatic require(input bit ok,input string message);
        checks++;if(!ok)$fatal(1,"SYSTOLIC_UNIT_FAILED: %s",message);
    endtask
    always @(posedge clk) begin
        for(integer r=0;r<ROWS;r++) begin
            before_a[r]={dut.a_path[r][0],dut.a_vpath[r][0]};
            for(integer c=0;c<COLS;c++)
                before_link[r*COLS+c]={dut.a_path[r][c+1],dut.b_path[r+1][c],
                    dut.a_vpath[r][c+1],dut.b_vpath[r+1][c],acc[r*COLS+c]};
        end
        for(integer c=0;c<COLS;c++) before_b[c]={dut.b_path[0][c],dut.b_vpath[0][c]};
        if(rst || clear) begin
            step=0;macs=0;
            for(integer p=0;p<RC;p++) golden[p]=0;
            require(pe_fire==0,"clear/reset suppress MAC");
        end else if(advance) begin
            require(step<2048,"history capacity");
            history_valid[step]=inject_valid;
            history_rows[step]=valid_rows;history_cols[step]=valid_cols;
            for(integer r=0;r<ROWS;r++) history_a[step][r]=$signed(a[r]);
            for(integer c=0;c<COLS;c++) history_b[step][c]=$signed(b[c]);
            for(integer r=0;r<ROWS;r++) for(integer c=0;c<COLS;c++) begin
                integer idx;bit expected;
                idx=step-r-c;
                expected=0;
                if(idx>=0) expected=history_valid[idx] && r<history_rows[idx] && c<history_cols[idx];
                require(pe_fire[r*COLS+c]===expected,"wavefront valid and K alignment");
                if(expected) begin
                    golden[r*COLS+c]=golden[r*COLS+c]+history_a[idx][r]*history_b[idx][c];
                    macs++;
                end
            end
            step++;
        end else require(pe_fire==0,"pause suppresses MAC");
        #1;
        for(integer p=0;p<RC;p++) require(acc[p]===golden[p],"each PE matches per-advance reference");
        if(!rst && !clear && !advance) begin
            held++;
            for(integer r=0;r<ROWS;r++) begin
                if(r!=0) require({dut.a_path[r][0],dut.a_vpath[r][0]}===before_a[r],"A skew stable during pause");
                for(integer c=0;c<COLS;c++)
                    require({dut.a_path[r][c+1],dut.b_path[r+1][c],
                        dut.a_vpath[r][c+1],dut.b_vpath[r+1][c],acc[r*COLS+c]}===before_link[r*COLS+c],"PE forwarding stable during pause");
            end
            for(integer c=1;c<COLS;c++) require({dut.b_path[0][c],dut.b_vpath[0][c]}===before_b[c],"B skew stable during pause");
        end
    end
    task automatic cycle(input integer token,input bit valid,go,zero_data);
        @(negedge clk);advance=go;inject_valid=valid;
        for(integer r=0;r<ROWS;r++) a[r]=zero_data?0:8'((token*37+r*11)%256-128);
        for(integer c=0;c<COLS;c++) b[c]=zero_data?0:8'((token*3+c*5)%16-8);
        @(posedge clk);#2;
    endtask
    task automatic clear_group;
        @(negedge clk);clear=1;advance=0;inject_valid=0;
        @(posedge clk);#2;
        @(negedge clk);clear=0;
    endtask
    task automatic drain;
        for(integer q=0;q<D+2;q++) cycle(q,0,1,0);
    endtask
    initial begin
        for(integer r=0;r<ROWS;r++) a[r]=0;
        for(integer c=0;c<COLS;c++) b[c]=0;
        repeat(3)@(posedge clk);@(negedge clk);rst=0;
        clear_group();cycle(0,1,1,0);drain();
        require(macs==RC,"K1 reaches every PE");groups++;
        clear_group();
        for(integer q=0;q<32;q++) begin
            if(q%5==2) begin cycle(1000+q,1,0,0);cycle(-1000-q,0,0,0);end
            cycle(q,1,1,0);
        end
        drain();require(macs==32*RC,"all tokens survive pause");groups++;
        clear_group();valid_rows=ROWS-1;valid_cols=COLS-1;
        for(integer q=0;q<5;q++) cycle(q,1,1,0);
        drain();
        repeat(4)cycle(777,0,0,0);
        for(integer q=5;q<13;q++) cycle(q,1,1,0);
        drain();require(macs==13*(ROWS-1)*(COLS-1),"tail mask and cross-tile accumulation");groups++;
        clear_group();valid_rows=ROWS;valid_cols=COLS;
        for(integer q=0;q<8;q++)cycle(q,1,1,1);
        drain();require(macs==8*RC,"zero matrices still count valid MACs");groups++;
        clear_group();
        for(integer q=0;q<3;q++)cycle(q,1,1,0);
        @(negedge clk);rst=1;
        repeat(2)@(posedge clk);@(negedge clk);rst=0;advance=0;inject_valid=0;resets++;
        drain();require(macs==0,"in-flight reset cancels tokens");
        for(integer q=0;q<7;q++)cycle(q+50,1,1,0);
        drain();require(macs==7*RC,"recovery after reset");groups++;
        require(held>0 && resets==1,"pause and reset coverage");
        $display("SYSTOLIC_UNIT_PASS rows=%0d cols=%0d groups=%0d checks=%0d held=%0d resets=%0d",ROWS,COLS,groups,checks,held,resets);
        $finish;
    end
    initial begin #1000000;$fatal(1,"SYSTOLIC_UNIT_TIMEOUT");end
endmodule
module tb_systolic_array8;tb_systolic_array #(.ROWS(8),.COLS(8)) test();endmodule
