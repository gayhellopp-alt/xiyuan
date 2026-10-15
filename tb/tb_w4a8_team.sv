`timescale 1ns/1ps
module tb_w4a8_team #(parameter integer GROUP_SIZE=32,ROWS=4,COLS=4,TILE_K=8);
    import task_desc_pkg::*;
    import w4a8_memory_pkg::*;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,task_valid=0,task_ready,completion_valid,completion_ready=0,result_available;
    task_desc_t task_desc;
    memory_task_t loaded_desc;
    logic [31:0] a_bytes,w_bytes,sx_bytes,sw_bytes,y_bytes,completion_task_id,elapsed_cycles;
    logic [7:0] completion_status;
    logic load_pause=0,post_pause=0,array_pause=0;
    logic arvalid,arready,rvalid,rready,rlast,awvalid,awready,wvalid,wready,wlast,bvalid,bready;
    logic [31:0] araddr,awaddr;logic [3:0] arid,rid,awid,bid;
    logic [7:0] arlen,awlen,wstrb;logic [2:0] arsize,awsize;logic [1:0] arburst,awburst,rresp,bresp;
    logic [63:0] rdata,wdata;
    logic setup=0,random_stalls=1,hold_b=0,inject_r=0,inject_b=0,inject_rlast=0,inject_rid=0,inject_bid=0;
    integer reads,writes,b_count,checks=0,completions=0,outputs=0,ticks=0;
    integer golden[0:4095];logic [7:0] original[0:65535];
    w4a8_team_top #(.GROUP_SIZE(GROUP_SIZE),.ROWS(ROWS),.COLS(COLS),.TILE_K(TILE_K)) dut(.*);
    w4a8_axi_memory memory(.desc(loaded_desc),.*);
    task automatic require(input bit condition,input string message);
        checks++;if(!condition) $fatal(1,"TEAM_CHECK_FAILED %s time=%0t",message,$time);
    endtask
    always @(negedge clk) begin
        ticks++;
        post_pause=!rst && ticks%17==2;
        array_pause=!rst && ticks%13==3;
    end
    always @(posedge clk) if(!rst && completion_valid && result_available)
        require(b_count==loaded_desc.m*loaded_desc.n,"success requires every AXI B response");
    task automatic reset_all;
        @(negedge clk);rst=1;task_valid=0;completion_ready=0;load_pause=0;hold_b=0;
        inject_r=0;inject_b=0;inject_rlast=0;inject_rid=0;inject_bid=0;
        repeat(4) @(negedge clk);rst=0;repeat(2) @(negedge clk);
        require(!completion_valid && !result_available,"reset clears completion");
    endtask
    task automatic load_job(input integer job);
        integer f,rc,v;
        f=$fopen($sformatf("g%0d_job%0d.txt",GROUP_SIZE,job),"r");require(f!=0,"vector opened");
        rc=$fscanf(f,"%d %d %d %d %d %d",loaded_desc.task_id,loaded_desc.m,loaded_desc.n,
            loaded_desc.k,loaded_desc.format_id,loaded_desc.group_size);require(rc==6,"shape read");
        rc=$fscanf(f,"%d %d %d %d %d",loaded_desc.a_base,loaded_desc.w_base,loaded_desc.sx_base,
            loaded_desc.sw_base,loaded_desc.y_base);require(rc==5,"bases read");
        rc=$fscanf(f,"%d %d %d %d %d",loaded_desc.a_stride,loaded_desc.w_stride,loaded_desc.sx_stride,
            loaded_desc.sw_stride,loaded_desc.y_stride);require(rc==5,"strides read");
        rc=$fscanf(f,"%d %d %d %d %d",loaded_desc.a_bytes,loaded_desc.w_bytes,loaded_desc.sx_bytes,
            loaded_desc.sw_bytes,loaded_desc.y_bytes);require(rc==5,"capacities read");
        for(integer i=0;i<loaded_desc.m*loaded_desc.n;i++) begin
            rc=$fscanf(f,"%d",v);require(rc==1,"golden read");golden[i]=v;
        end
        $fclose(f);
        if($test$plusargs("corrupt_expected")) golden[0]++;
        $readmemh($sformatf("g%0d_job%0d.hex",GROUP_SIZE,job),memory.mem);
        for(integer i=0;i<65536;i++) original[i]=memory.mem[i];
        task_desc='0;task_desc.task_id=loaded_desc.task_id;
        task_desc.m=loaded_desc.m;task_desc.n=loaded_desc.n;task_desc.k=loaded_desc.k;
        task_desc.a_addr=64'(loaded_desc.a_base);task_desc.w_addr=64'(loaded_desc.w_base);
        task_desc.sx_addr=64'(loaded_desc.sx_base);task_desc.sw_addr=64'(loaded_desc.sw_base);
        task_desc.y_addr=64'(loaded_desc.y_base);
        task_desc.a_stride=loaded_desc.a_stride;task_desc.w_stride=loaded_desc.w_stride;
        task_desc.sx_stride=loaded_desc.sx_stride;task_desc.sw_stride=loaded_desc.sw_stride;
        task_desc.y_stride=loaded_desc.y_stride;
        task_desc.activation_format=FORMAT_INT8;task_desc.weight_format=FORMAT_SINT4_PACKED;
        task_desc.scale_format=FORMAT_UQ4_12;task_desc.output_format=FORMAT_Q16_16;
        task_desc.group_size=GROUP_SIZE;
        a_bytes=loaded_desc.a_bytes;w_bytes=loaded_desc.w_bytes;sx_bytes=loaded_desc.sx_bytes;
        sw_bytes=loaded_desc.sw_bytes;y_bytes=loaded_desc.y_bytes;
        @(negedge clk);setup=1;@(negedge clk);setup=0;
    endtask
    task automatic submit;
        integer wd;
        wd=0;while(!task_ready) begin @(negedge clk);wd++;require(wd<100,"admission watchdog");end
        task_valid=1;@(negedge clk);task_valid=0;
    endtask
    task automatic finish_task(input logic [7:0] expected);
        integer wd;
        wd=0;while(!completion_valid) begin @(negedge clk);wd++;require(wd<300000,"completion watchdog");end
        require(completion_task_id==loaded_desc.task_id && completion_status==expected,"completion ID/status");
        require(result_available==(expected==STATUS_OK),"result visibility");
        repeat(9) begin
            @(negedge clk);require(completion_valid && completion_task_id==loaded_desc.task_id &&
                completion_status==expected && !task_ready,"completion held under backpressure");
        end
        completion_ready=1;@(negedge clk);completion_ready=0;completions++;
    endtask
    task automatic compare_memory;
        integer addr,v;bit destination;
        for(integer r=0;r<loaded_desc.m;r++) for(integer c=0;c<loaded_desc.n;c++) begin
            addr=loaded_desc.y_base+r*loaded_desc.y_stride+4*c;
            v={memory.mem[addr+3],memory.mem[addr+2],memory.mem[addr+1],memory.mem[addr]};
            require(v===golden[r*loaded_desc.n+c],"external Y bit exact");outputs++;
        end
        for(integer i=0;i<65536;i++) begin
            destination=i>=loaded_desc.y_base && i<loaded_desc.y_base+loaded_desc.y_bytes &&
                (i-loaded_desc.y_base)%loaded_desc.y_stride<4*loaded_desc.n;
            if(!destination) require(memory.mem[i]===original[i],"input, padding and guards unchanged");
        end
    endtask
    task automatic invalid_case(input integer kind,input logic [7:0] expected);
        load_job(0);
        case(kind)
            0:task_desc.m=0;
            1:task_desc.weight_format=9;
            2:task_desc.group_size=GROUP_SIZE+1;
            3:task_desc.flags=1;
            4:task_desc.a_addr=64'h1_0000_0ffd;
            5:task_desc.y_addr=64'hffff_fffc;
            6:task_desc.a_stride=1;
            7:task_desc.sx_stride=task_desc.sx_stride+1;
            8:a_bytes=a_bytes-1;
            9:task_desc.y_addr=task_desc.sx_addr;
            10:task_desc.y_addr=task_desc.y_addr+2;
            11:y_bytes=0;
            12:task_desc.sw_stride=task_desc.sw_stride+1;
        endcase
        submit();finish_task(expected);
        require(reads==0 && writes==0,"rejected descriptors cause no AXI access");
    endtask
    initial begin
        reset_all();
        for(integer job=0;job<2;job++) begin
            load_job(job);submit();
            // Caller may immediately change every submitted sideband after acceptance.
            task_desc='0;a_bytes=0;w_bytes=0;sx_bytes=0;sw_bytes=0;y_bytes=0;
            finish_task(STATUS_OK);compare_memory();
        end
        invalid_case(0,STATUS_BAD_DIM);invalid_case(1,STATUS_BAD_FORMAT);
        invalid_case(2,STATUS_BAD_GROUP);invalid_case(3,STATUS_BAD_FLAGS);
        invalid_case(4,STATUS_BAD_ADDRESS);invalid_case(5,STATUS_BAD_ADDRESS);
        invalid_case(6,STATUS_BAD_STRIDE);invalid_case(7,STATUS_BAD_STRIDE);
        invalid_case(8,STATUS_BAD_REGION);invalid_case(9,STATUS_BAD_REGION);
        invalid_case(10,STATUS_BAD_ADDRESS);invalid_case(11,STATUS_BAD_REGION);
        invalid_case(12,STATUS_BAD_STRIDE);
        load_job(0);hold_b=1;submit();
        wait(writes>0);repeat(80) @(negedge clk);
        require(!completion_valid && !result_available && !task_ready,"pending B blocks completion and reuse");
        hold_b=0;finish_task(STATUS_OK);compare_memory();
        load_job(0);inject_r=1;submit();finish_task(STATUS_READ_ERROR);inject_r=0;
        load_job(0);inject_b=1;submit();finish_task(STATUS_WRITE_ERROR);inject_b=0;
        load_job(1);submit();finish_task(STATUS_OK);compare_memory();
        load_job(0);hold_b=1;submit();wait(writes>0);reset_all();
        load_job(0);submit();finish_task(STATUS_OK);compare_memory();
        $display("W4A8_TEAM_TESTS_PASS group=%0d rows=%0d completions=%0d outputs=%0d checks=%0d",
            GROUP_SIZE,ROWS,completions,outputs,checks);
        $finish;
    end
    initial begin #150000000;$fatal(1,"TEAM_GLOBAL_TIMEOUT");end
    initial begin if($test$plusargs("timeout_probe")) begin #10000;$fatal(1,"TEAM_FORCED_TIMEOUT");end end
endmodule
module tb_w4a8_team12;tb_w4a8_team #(.GROUP_SIZE(12),.ROWS(2),.COLS(3),.TILE_K(5)) test();endmodule
module tb_w4a8_team8;tb_w4a8_team #(.ROWS(8),.COLS(8)) test();endmodule
