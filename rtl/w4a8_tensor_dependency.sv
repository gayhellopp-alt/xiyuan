// Storage-only handoff. Requant arithmetic and task scheduling remain external.
module w4a8_tensor_dependency # (parameter integer GROUP_SIZE=32)(
    input logic clk,rst,
    input logic plan_valid,output logic plan_ready,
    input w4a8_memory_pkg::memory_task_t plan_next_task,
    input logic [31:0] plan_producer_id,plan_requant_id,
    input logic [31:0] plan_source_base,plan_source_stride,plan_source_bytes,
    input logic producer_fence_valid,output logic producer_fence_ready,
    input logic [31:0] producer_fence_id,input logic [3:0] producer_fence_status,
    output logic requant_request_valid,input logic requant_request_ready,
    output logic [31:0] requant_id,source_base,source_stride,source_bytes,
    output logic [31:0] activation_base,activation_stride,activation_bytes,
    output logic [31:0] scale_base,scale_stride,scale_bytes,
    output logic [15:0] rows,dimensions,group_size,
    input logic requant_fence_valid,output logic requant_fence_ready,
    input logic [31:0] requant_fence_id,input logic [3:0] requant_fence_status,
    input logic [31:0] requant_activation_written,requant_scale_written,
    output logic next_task_valid,input logic next_task_ready,
    output w4a8_memory_pkg::memory_task_t next_task,
    input logic consumer_fence_valid,output logic consumer_fence_ready,
    input logic [31:0] consumer_fence_id,input logic [3:0] consumer_fence_status,
    output logic completion_valid,input logic completion_ready,
    output logic [31:0] completion_id,output logic [3:0] completion_status
);
    import w4a8_memory_pkg::*;
    initial if(GROUP_SIZE<1 || GROUP_SIZE>4096) $fatal(1,"Unsupported tensor handoff group size");
    typedef enum logic [2:0] {IDLE,CHECK,WAIT_PRODUCER,REQUEST_REQUANT,WAIT_REQUANT,ISSUE_NEXT,WAIT_CONSUMER,COMPLETE} state_t;
    state_t state;
    logic [31:0] producer_id;
    logic next_legal,legal;
    logic [63:0] extent;
    w4a8_memory_validate #(.GROUP_SIZE(GROUP_SIZE)) validate(.desc(next_task),.legal(next_legal));
    assign extent=(64'(next_task.m)-1)*64'(source_stride)+4*64'(next_task.k);
    assign legal=next_legal && source_base[1:0]==0 && source_stride[1:0]==0 &&
        64'(source_stride)>=4*64'(next_task.k) && region_ok(source_base,source_bytes,extent) &&
        producer_id!=requant_id && producer_id!=next_task.task_id && requant_id!=next_task.task_id &&
        !overlaps(source_base,source_bytes,next_task.a_base,next_task.a_bytes) &&
        !overlaps(source_base,source_bytes,next_task.sx_base,next_task.sx_bytes) &&
        !overlaps(next_task.a_base,next_task.a_bytes,next_task.sx_base,next_task.sx_bytes) &&
        !overlaps(next_task.a_base,next_task.a_bytes,next_task.w_base,next_task.w_bytes) &&
        !overlaps(next_task.a_base,next_task.a_bytes,next_task.sw_base,next_task.sw_bytes) &&
        !overlaps(next_task.sx_base,next_task.sx_bytes,next_task.w_base,next_task.w_bytes) &&
        !overlaps(next_task.sx_base,next_task.sx_bytes,next_task.sw_base,next_task.sw_bytes);
    assign plan_ready=state==IDLE && !rst;
    assign producer_fence_ready=state==WAIT_PRODUCER && !rst;
    assign requant_request_valid=state==REQUEST_REQUANT && !rst;
    assign requant_fence_ready=state==WAIT_REQUANT && !rst;
    assign next_task_valid=state==ISSUE_NEXT && !rst;
    assign consumer_fence_ready=state==WAIT_CONSUMER && !rst;
    assign completion_valid=state==COMPLETE && !rst;
    assign completion_id=next_task.task_id;
    assign activation_base=next_task.a_base;assign activation_stride=next_task.a_stride;assign activation_bytes=next_task.a_bytes;
    assign scale_base=next_task.sx_base;assign scale_stride=next_task.sx_stride;assign scale_bytes=next_task.sx_bytes;
    assign rows=next_task.m;assign dimensions=next_task.k;assign group_size=GROUP_SIZE;
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE;next_task<='0;producer_id<=0;requant_id<=0;
            source_base<=0;source_stride<=0;source_bytes<=0;completion_status<=MEM_OK;
        end else case(state)
            IDLE:if(plan_valid) begin
                next_task<=plan_next_task;producer_id<=plan_producer_id;requant_id<=plan_requant_id;
                source_base<=plan_source_base;source_stride<=plan_source_stride;source_bytes<=plan_source_bytes;
                completion_status<=MEM_OK;state<=CHECK;
            end
            CHECK:if(legal) state<=WAIT_PRODUCER;else begin completion_status<=MEM_BAD_TASK;state<=COMPLETE;end
            WAIT_PRODUCER:if(producer_fence_valid && producer_fence_id==producer_id) begin
                if(producer_fence_status!=MEM_OK) begin completion_status<=producer_fence_status;state<=COMPLETE;end
                else state<=REQUEST_REQUANT;
            end
            REQUEST_REQUANT:if(requant_request_ready) state<=WAIT_REQUANT;
            WAIT_REQUANT:if(requant_fence_valid && requant_fence_id==requant_id) begin
                if(requant_fence_status!=MEM_OK) begin completion_status<=requant_fence_status;state<=COMPLETE;end
                else if(requant_activation_written!=32'(rows)*32'(dimensions) ||
                    requant_scale_written!=2*32'(rows)*((32'(dimensions)+GROUP_SIZE-1)/GROUP_SIZE)) begin
                    completion_status<=MEM_PROTOCOL_ERROR;state<=COMPLETE;
                end else state<=ISSUE_NEXT;
            end
            // Hold the workspace lease until the next task drains all external accesses.
            ISSUE_NEXT:if(next_task_ready) state<=WAIT_CONSUMER;
            WAIT_CONSUMER:if(consumer_fence_valid && consumer_fence_id==next_task.task_id) begin
                completion_status<=consumer_fence_status;state<=COMPLETE;
            end
            COMPLETE:if(completion_ready) state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
