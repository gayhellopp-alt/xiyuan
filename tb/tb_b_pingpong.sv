`timescale 1ns/1ps
module tb_b_pingpong;
    logic clk=0;
    always #5 clk=~clk;
    logic rst=1,enable=1,init=0,take=0,release_tile=0,rd_en=0;
    logic [15:0] task_n=1,task_k=9,tile_n=0,consume_kt=0,read_lane,read_k_abs;
    logic [1:0] rd_k=0;
    logic mem_rd_en,ready,wr_en=0;
    logic [5:0] mem_rd_addr,wr_addr=0;
    logic signed [7:0] mem_q,wr_data=0;
    wire signed [7:0] data [0:1];
    integer checks=0,comparisons=0,source_reads=0,i,q,tile,limit,reads_before;
    logic signed [7:0] held0,held1;
    b_pingpong #(.COLS(2),.TILE_K(4),.MAX_N(4),.MAX_K(16)) dut (.*);
    sync_sdp_ram #(.WIDTH(8),.DEPTH(64)) source_memory (
        .clk(clk),.wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_data),
        .rd_en(mem_rd_en),.rd_addr(mem_rd_addr),.rd_data(mem_q));
    task automatic require(input bit cond,input string message);
        if(!cond) $fatal(1,"PINGPONG_UNIT_FAILED: %s time=%0t",message,$time);
        checks=checks+1;
    endtask
    function automatic integer value(input integer row,col);
        return ((row*11+col*7)%255)-128;
    endfunction
    task automatic wait_ready;
        limit=0;
        while(!ready) begin
            @(negedge clk);limit=limit+1;
            require(limit<200,"ready timeout");
        end
    endtask
    always @(posedge clk) if(!rst && mem_rd_en) begin
        require(mem_rd_addr<64 && read_k_abs<9 && read_lane<1,"source bounds");
        source_reads=source_reads+1;
    end
    initial begin #20000;$fatal(1,"PINGPONG_UNIT_TIMEOUT");end
    initial begin
        repeat(3) @(posedge clk);
        @(negedge clk);rst=0;
        for(i=0;i<64;i=i+1) begin
            wr_en=1;wr_addr=i;wr_data=value(i/4,i%4);
            @(posedge clk);
            @(negedge clk);
        end
        wr_en=0;init=1;
        @(posedge clk);
        @(negedge clk);init=0;
        wait_ready();
        while(dut.bank_state[1]!=2) @(negedge clk);
        reads_before=source_reads;
        repeat(8) @(posedge clk);
        #1;
        require(!dut.loading && !mem_rd_en && source_reads==reads_before,"two occupied groups stop producer");
        @(negedge clk);consume_kt=4;take=1;rd_en=1;
        #1;require(!ready,"wrong K refuses READY");
        @(posedge clk);#1;
        require(dut.bank_state[0]==2,"wrong K cannot take");
        @(negedge clk);consume_kt=0;take=0;rd_en=0;
        for(tile=0;tile<3;tile=tile+1) begin
            consume_kt=tile*4;
            wait_ready();
            take=1;
            @(posedge clk);#1;
            require(dut.bank_state[dut.consumer_bank]==3,"correct K takes ownership");
            @(negedge clk);take=0;
            if(tile==1) begin
                require(dut.loading,"tail fill concurrent with consumer");
                enable=0;reads_before=source_reads;
                repeat(3) @(posedge clk);
                #1;
                require(dut.loading && dut.bank_state[dut.consumer_bank]==3 &&
                        source_reads==reads_before && !mem_rd_en,"pause freezes both owners");
                @(negedge clk);enable=1;
            end
            for(q=0;q<((tile==2)?1:4);q=q+1) begin
                rd_en=1;rd_k=q;
                @(posedge clk);#1;
                require(data[0]===value(tile*4+q,0),"valid lane data");
                require(data[1]===8'sd0,"tail column zero");
                comparisons=comparisons+2;
                @(negedge clk);
                if(tile==0 && q==0) begin
                    held0=data[0];held1=data[1];consume_kt=4;rd_k=1;
                    @(posedge clk);#1;
                    require(data[0]===held0 && data[1]===held1,"wrong K suppresses synchronous bank read");
                    @(negedge clk);consume_kt=0;
                end
            end
            rd_en=0;release_tile=1;
            @(posedge clk);#1;
            require(dut.bank_state[!dut.consumer_bank]==0,"release frees old group");
            @(negedge clk);release_tile=0;
        end
        require(source_reads==9,"exact valid source reads");
        require(dut.bank_state[0]==0 && dut.bank_state[1]==0 && !dut.loading,"all groups released");
        $display("PINGPONG_UNIT_PASS tiles=3 comparisons=%0d checks=%0d",comparisons,checks);
        $finish;
    end
endmodule
