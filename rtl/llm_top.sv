// One host submission and one AXI owner across linear, FFN, KV and attention.
module llm_top #(parameter integer ADDR_WIDTH=64,GROUP_SIZE=32,ROWS=4,COLS=4,TILE_K=8,
    MAX_M=64,MAX_N=64,MAX_K=4096,MAX_H=64,CAPACITY=512,MAX_DIM=64,MAX_TOKENS=16)(
    input logic clk,rst,job_valid,output logic job_ready,input logic [7:0] job_opcode,
    input accelerator_pkg::bounded_task_t linear_task,input accelerator_pkg::ffn_plan_t ffn_plan,
    input kv_cache_pkg::kv_config_t kv_config,input kv_cache_pkg::kv_command_t kv_command,
    input attention_pkg::attention_task_t attention_task,
    input logic append_valid,output logic append_ready,input logic [7:0] append_data,input logic append_last,
    output logic read_valid,input logic read_ready,output logic [7:0] read_data,output logic read_last,
    input logic q_valid,output logic q_ready,input logic signed [7:0] q_data,input logic [15:0] q_scale,input logic q_last,
    input logic load_pause,post_pause,array_pause,
    output logic completion_valid,input logic completion_ready,output logic [31:0] completion_task_id,
    output logic [7:0] completion_status,output logic result_available,output logic configured,output logic [3:0] stage,
    output logic [31:0] elapsed_cycles,activation_written,scale_written,

    output logic arvalid,input logic arready,output logic [ADDR_WIDTH-1:0] araddr,
    output logic [3:0] arid,output logic [7:0] arlen,output logic [2:0] arsize,output logic [1:0] arburst,
    input logic rvalid,output logic rready,input logic [63:0] rdata,
    input logic [3:0] rid,input logic [1:0] rresp,input logic rlast,
    output logic awvalid,input logic awready,output logic [ADDR_WIDTH-1:0] awaddr,
    output logic [3:0] awid,output logic [7:0] awlen,output logic [2:0] awsize,output logic [1:0] awburst,
    output logic wvalid,input logic wready,output logic [63:0] wdata,output logic [7:0] wstrb,output logic wlast,
    input logic bvalid,output logic bready,input logic [3:0] bid,input logic [1:0] bresp
);
    import accelerator_pkg::*;import task_desc_pkg::*;
    typedef enum logic [1:0] {IDLE,ISSUE,RUN,REJECT} state_t;
    state_t state;logic [7:0] opcode;
    bounded_task_t saved_linear;ffn_plan_t saved_ffn;kv_cache_pkg::kv_config_t saved_cfg;
    kv_cache_pkg::kv_command_t saved_cmd;attention_pkg::attention_task_t saved_attention;
    logic linear_ready,linear_done,kv_cfg_ready,kv_cmd_ready,query_ready,attention_done;
    logic [31:0] linear_id,attention_id,reject_id;logic [7:0] linear_status,attention_status;
    logic [3:0] linear_stage;
    logic [31:0] linear_elapsed,linear_activation_written,linear_scale_written;
    wire attention_owner=opcode>=OP_ATTENTION;
    assign job_ready=state==IDLE && !rst;
    assign completion_valid=!rst && (state==REJECT || (state==RUN && (attention_owner?attention_done:linear_done)));
    assign completion_task_id=state==REJECT?reject_id:attention_owner?attention_id:linear_id;
    assign completion_status=state==REJECT?STATUS_BAD_FLAGS:attention_owner?attention_status:linear_status;
    assign result_available=completion_valid && completion_status==STATUS_OK;
    assign activation_written=attention_owner?0:linear_activation_written;
    assign scale_written=attention_owner?0:linear_scale_written;
    assign stage=state==IDLE?0:!attention_owner?linear_stage:opcode==OP_ATTENTION?5:opcode==OP_KV_CONFIG?6:7;
    always_ff @(posedge clk) begin
        if(rst) begin state<=IDLE;opcode<=0;saved_linear<='0;saved_ffn<='0;saved_cfg<='0;saved_cmd<='0;saved_attention<='0;reject_id<=0;elapsed_cycles<=0;end
        else begin
        if((state==ISSUE || state==RUN) && !completion_valid) elapsed_cycles<=elapsed_cycles+1;
        case(state)
            IDLE:if(job_valid) begin
                saved_linear<=linear_task;saved_ffn<=ffn_plan;saved_cfg<=kv_config;saved_cmd<=kv_command;saved_attention<=attention_task;
                opcode<=job_opcode;
                reject_id<=job_opcode==OP_KV_CONFIG?kv_config.config_id:job_opcode==OP_KV_COMMAND?kv_command.task_id:
                    job_opcode==OP_LINEAR?linear_task.desc.task_id:job_opcode==OP_FFN?ffn_plan.task_id:attention_task.task_id;
                elapsed_cycles<=0;
                if(job_opcode>OP_KV_COMMAND || (job_opcode==OP_KV_CONFIG && configured) || (job_opcode==OP_KV_COMMAND && !configured)) state<=REJECT;
                else state<=ISSUE;
            end
            ISSUE:if((opcode<=OP_FFN && linear_ready) || (opcode==OP_ATTENTION && query_ready) ||
                (opcode==OP_KV_CONFIG && kv_cfg_ready) || (opcode==OP_KV_COMMAND && kv_cmd_ready)) state<=RUN;
            RUN:if(completion_valid && completion_ready) state<=IDLE;
            REJECT:if(completion_ready) state<=IDLE;
        endcase
        end
    end
    wire arvalid_l,arvalid_a;
    assign arvalid=attention_owner?arvalid_a:arvalid_l;
    wire [ADDR_WIDTH-1:0] araddr_l,araddr_a;
    assign araddr=attention_owner?araddr_a:araddr_l;
    wire [4-1:0] arid_l,arid_a;
    assign arid=attention_owner?arid_a:arid_l;
    wire [8-1:0] arlen_l,arlen_a;
    assign arlen=attention_owner?arlen_a:arlen_l;
    wire [3-1:0] arsize_l,arsize_a;
    assign arsize=attention_owner?arsize_a:arsize_l;
    wire [2-1:0] arburst_l,arburst_a;
    assign arburst=attention_owner?arburst_a:arburst_l;
    wire rready_l,rready_a;
    assign rready=attention_owner?rready_a:rready_l;
    wire awvalid_l,awvalid_a;
    assign awvalid=attention_owner?awvalid_a:awvalid_l;
    wire [ADDR_WIDTH-1:0] awaddr_l,awaddr_a;
    assign awaddr=attention_owner?awaddr_a:awaddr_l;
    wire [4-1:0] awid_l,awid_a;
    assign awid=attention_owner?awid_a:awid_l;
    wire [8-1:0] awlen_l,awlen_a;
    assign awlen=attention_owner?awlen_a:awlen_l;
    wire [3-1:0] awsize_l,awsize_a;
    assign awsize=attention_owner?awsize_a:awsize_l;
    wire [2-1:0] awburst_l,awburst_a;
    assign awburst=attention_owner?awburst_a:awburst_l;
    wire wvalid_l,wvalid_a;
    assign wvalid=attention_owner?wvalid_a:wvalid_l;
    wire [64-1:0] wdata_l,wdata_a;
    assign wdata=attention_owner?wdata_a:wdata_l;
    wire [8-1:0] wstrb_l,wstrb_a;
    assign wstrb=attention_owner?wstrb_a:wstrb_l;
    wire wlast_l,wlast_a;
    assign wlast=attention_owner?wlast_a:wlast_l;
    wire bready_l,bready_a;
    assign bready=attention_owner?bready_a:bready_l;
    accelerator_top #(.ADDR_WIDTH(ADDR_WIDTH),.GROUP_SIZE(GROUP_SIZE),.ROWS(ROWS),.COLS(COLS),.TILE_K(TILE_K),
        .MAX_M(MAX_M),.MAX_N(MAX_N),.MAX_K(MAX_K),.MAX_H(MAX_H),.CAPACITY(CAPACITY)) linear_ffn(
        .clk(clk),.rst(rst),.job_valid(state==ISSUE && opcode<=OP_FFN),.job_ready(linear_ready),.job_opcode(opcode),
        .linear_task(saved_linear),.ffn_plan(saved_ffn),.load_pause(load_pause),.post_pause(post_pause),.array_pause(array_pause),
        .completion_valid(linear_done),.completion_ready(state==RUN && !attention_owner && completion_ready),
        .completion_task_id(linear_id),.completion_status(linear_status),.result_available(),.stage(linear_stage),
        .elapsed_cycles(linear_elapsed),.activation_written(linear_activation_written),.scale_written(linear_scale_written),
        .arvalid(arvalid_l),
        .araddr(araddr_l),
        .arid(arid_l),
        .arlen(arlen_l),
        .arsize(arsize_l),
        .arburst(arburst_l),
        .rready(rready_l),
        .awvalid(awvalid_l),
        .awaddr(awaddr_l),
        .awid(awid_l),
        .awlen(awlen_l),
        .awsize(awsize_l),
        .awburst(awburst_l),
        .wvalid(wvalid_l),
        .wdata(wdata_l),
        .wstrb(wstrb_l),
        .wlast(wlast_l),
        .bready(bready_l),
        .arready(arready && !attention_owner),
        .rvalid(rvalid && !attention_owner),
        .rdata(rdata),
        .rid(rid),
        .rresp(rresp),
        .rlast(rlast),
        .awready(awready && !attention_owner),
        .wready(wready && !attention_owner),
        .bvalid(bvalid && !attention_owner),
        .bid(bid),
        .bresp(bresp));
    attention_kv_top #(.ADDR_WIDTH(ADDR_WIDTH),.GROUP_SIZE(GROUP_SIZE),.MAX_DIM(MAX_DIM),.MAX_TOKENS(MAX_TOKENS)) attention(
        .clk(clk),.rst(rst),.cfg_valid(state==ISSUE && opcode==OP_KV_CONFIG),.cfg_ready(kv_cfg_ready),.cfg_desc(saved_cfg),
        .cmd_valid(state==ISSUE && opcode==OP_KV_COMMAND),.cmd_ready(kv_cmd_ready),.cmd_desc(saved_cmd),
        .query_valid(state==ISSUE && opcode==OP_ATTENTION),.query_ready(query_ready),.query_desc(saved_attention),
        .append_valid(append_valid && state==RUN),.append_ready(append_ready),.append_data(append_data),.append_last(append_last),
        .read_valid(read_valid),.read_ready(read_ready),.read_data(read_data),.read_last(read_last),
        .q_valid(q_valid && state==RUN),.q_ready(q_ready),.q_data(q_data),.q_scale(q_scale),.q_last(q_last),
        .completion_valid(attention_done),.completion_ready(state==RUN && attention_owner && completion_ready),
        .completion_task_id(attention_id),.completion_status(attention_status),.result_available(),.configured(configured),
        .arvalid(arvalid_a),
        .araddr(araddr_a),
        .arid(arid_a),
        .arlen(arlen_a),
        .arsize(arsize_a),
        .arburst(arburst_a),
        .rready(rready_a),
        .awvalid(awvalid_a),
        .awaddr(awaddr_a),
        .awid(awid_a),
        .awlen(awlen_a),
        .awsize(awsize_a),
        .awburst(awburst_a),
        .wvalid(wvalid_a),
        .wdata(wdata_a),
        .wstrb(wstrb_a),
        .wlast(wlast_a),
        .bready(bready_a),
        .arready(arready && attention_owner),
        .rvalid(rvalid && attention_owner),
        .rdata(rdata),
        .rid(rid),
        .rresp(rresp),
        .rlast(rlast),
        .awready(awready && attention_owner),
        .wready(wready && attention_owner),
        .bvalid(bvalid && attention_owner),
        .bid(bid),
        .bresp(bresp));
endmodule
