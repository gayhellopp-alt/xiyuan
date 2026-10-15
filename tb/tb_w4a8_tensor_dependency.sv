`timescale 1ns/1ps
module tb_w4a8_tensor_dependency;
    import w4a8_memory_pkg::*;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,plan_valid=0,plan_ready;
    memory_task_t plan_next_task,next_task;
    logic [31:0] plan_producer_id=10,plan_requant_id=20,plan_source_base=4096,plan_source_stride=24,plan_source_bytes=44;
    logic producer_fence_valid=0,producer_fence_ready,requant_request_valid,requant_request_ready=0;
    logic [31:0] producer_fence_id=0;logic [3:0] producer_fence_status=0;
    logic [31:0] requant_id,source_base,source_stride,source_bytes,activation_base,activation_stride,activation_bytes,scale_base,scale_stride,scale_bytes;
    logic [15:0] rows,dimensions,group_size;
    logic requant_fence_valid=0,requant_fence_ready;logic [31:0] requant_fence_id=0,requant_activation_written=0,requant_scale_written=0;
    logic [3:0] requant_fence_status=0;
    logic next_task_valid,next_task_ready=0,completion_valid,completion_ready=0;
    logic consumer_fence_valid=0,consumer_fence_ready;
    logic [31:0] consumer_fence_id=0;logic [3:0] consumer_fence_status=0;
    logic [31:0] completion_id;logic [3:0] completion_status;
    integer checks=0,handoffs=0;
    memory_task_t expected;
    w4a8_tensor_dependency #(.GROUP_SIZE(4)) dut(.*);
    task automatic require(input bit ok,input string message);
        checks++;if(!ok) $fatal(1,"TENSOR_DEPENDENCY_CHECK_FAILED %s",message);
    endtask
    task automatic consumer(input integer id,input logic [3:0] status);
        @(negedge clk);consumer_fence_id=id;consumer_fence_status=status;consumer_fence_valid=1;
        require(consumer_fence_ready,"consumer notification ready");@(negedge clk);consumer_fence_valid=0;
    endtask
    task automatic setup_plan;
        plan_next_task='0;plan_next_task.task_id=30;plan_next_task.m=2;plan_next_task.n=3;plan_next_task.k=5;
        plan_next_task.format_id=1;plan_next_task.group_size=4;
        plan_next_task.a_base=1001;plan_next_task.a_stride=8;plan_next_task.a_bytes=13;
        plan_next_task.w_base=2001;plan_next_task.w_stride=5;plan_next_task.w_bytes=13;
        plan_next_task.sx_base=3000;plan_next_task.sx_stride=8;plan_next_task.sx_bytes=12;
        plan_next_task.sw_base=4000;plan_next_task.sw_stride=8;plan_next_task.sw_bytes=14;
        plan_next_task.y_base=5000;plan_next_task.y_stride=16;plan_next_task.y_bytes=28;
        plan_source_bytes=44;expected=plan_next_task;
    endtask
    task automatic submit;
        @(negedge clk);require(plan_ready,"plan accepted idle");plan_valid=1;
        @(negedge clk);plan_valid=0;plan_next_task='0;
    endtask
    task automatic producer(input integer id,input logic [3:0] status);
        @(negedge clk);producer_fence_id=id;producer_fence_status=status;producer_fence_valid=1;
        require(producer_fence_ready,"producer notification ready");@(negedge clk);producer_fence_valid=0;
    endtask
    task automatic requant(input integer id,input logic [3:0] status,input integer a_bytes,s_bytes);
        @(negedge clk);requant_fence_id=id;requant_fence_status=status;requant_activation_written=a_bytes;requant_scale_written=s_bytes;requant_fence_valid=1;
        require(requant_fence_ready,"requant notification ready");@(negedge clk);requant_fence_valid=0;
    endtask
    task automatic finish(input logic [3:0] status);
        integer timeout_count=0;
        while(!completion_valid) begin @(negedge clk);timeout_count++;require(timeout_count<100,"completion watchdog");end
        require(completion_status==status && completion_id==30,"completion ID/status");
        repeat(5) begin @(negedge clk);require(completion_valid && !plan_ready && completion_status==status,"completion hold");end
        completion_ready=1;@(negedge clk);completion_ready=0;
    endtask
    task automatic start_requant;
        producer(10,MEM_OK);repeat(5) begin @(negedge clk);
            require(requant_request_valid && !next_task_valid && requant_id==20 && source_base==4096 && source_stride==24 && source_bytes==44 &&
                activation_base==1001 && scale_base==3000 && rows==2 && dimensions==5 && group_size==4,"requant request held with addresses");
        end
        requant_request_ready=1;@(negedge clk);requant_request_ready=0;
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        setup_plan();submit();repeat(10) begin @(negedge clk);require(!requant_request_valid && !next_task_valid,"no early dependency release");end
        producer(999,MEM_OK);repeat(3) @(negedge clk);require(!requant_request_valid,"wrong producer ID ignored");
        start_requant();requant(999,MEM_OK,10,8);repeat(3) @(negedge clk);require(!next_task_valid,"wrong requant ID ignored");
        requant(20,MEM_OK,10,8);
        repeat(10) begin @(negedge clk);require(next_task_valid && next_task===expected && !completion_valid,"next descriptor held after both fences");end
        next_task_ready=1;@(negedge clk);next_task_ready=0;handoffs++;
        repeat(10) begin @(negedge clk);require(!plan_ready && !completion_valid,"workspace retained during consumer reads");end
        consumer(999,MEM_OK);require(!plan_ready && !completion_valid,"wrong consumer ID cannot release workspace");
        consumer(30,MEM_OK);finish(MEM_OK);
        setup_plan();submit();repeat(2) @(negedge clk);producer(10,MEM_WRITE_ERROR);finish(MEM_WRITE_ERROR);require(!next_task_valid,"producer error blocks next layer");
        setup_plan();submit();repeat(2) @(negedge clk);start_requant();requant(20,MEM_WRITE_ERROR,10,8);finish(MEM_WRITE_ERROR);
        setup_plan();submit();repeat(2) @(negedge clk);start_requant();requant(20,MEM_OK,10,7);finish(MEM_PROTOCOL_ERROR);
        setup_plan();plan_source_bytes=1;submit();finish(MEM_BAD_TASK);
        setup_plan();plan_next_task.a_base=3000;submit();finish(MEM_BAD_TASK);
        setup_plan();submit();repeat(2) @(negedge clk);start_requant();@(negedge clk);rst=1;repeat(3) @(negedge clk);rst=0;
        #1;require(plan_ready && !next_task_valid && !requant_request_valid,"reset removes pending handoff");
        setup_plan();submit();repeat(2) @(negedge clk);start_requant();requant(20,MEM_OK,10,8);
        @(negedge clk);next_task_ready=1;@(negedge clk);next_task_ready=0;handoffs++;consumer(30,MEM_OK);finish(MEM_OK);
        setup_plan();submit();repeat(2) @(negedge clk);start_requant();requant(20,MEM_OK,10,8);
        @(negedge clk);next_task_ready=1;@(negedge clk);next_task_ready=0;handoffs++;consumer(30,MEM_WRITE_ERROR);finish(MEM_WRITE_ERROR);
        require(handoffs==3,"three handoffs, including consumer failure");
        $display("TENSOR_DEPENDENCY_TESTS_PASS checks=%0d handoffs=%0d",checks,handoffs);$finish;
    end
    initial begin #100000;$fatal(1,"TENSOR_DEPENDENCY_GLOBAL_TIMEOUT");end
endmodule
