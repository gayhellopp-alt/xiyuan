// Bounded one-query attention: signed INT8 Q/K/V + per-group UQ4.12 scales.
// Reads only the committed prefix requested by tokens. Softmax is a documented
// deterministic LUT approximation, not floating point or a placeholder.
module attention_compute #(parameter integer GROUP_SIZE=32,MAX_DIM=64,MAX_TOKENS=16)(
    input logic clk,rst,query_valid,output logic query_ready,
    input attention_pkg::attention_task_t query_desc,
    input logic metadata_valid,input logic [15:0] committed_tokens,cache_dimension,
    input logic q_valid,output logic q_ready,input logic signed [7:0] q_data,
    input logic [15:0] q_scale,input logic q_last,
    output logic cmd_valid,input logic cmd_ready,output kv_cache_pkg::kv_command_t cmd_desc,
    input logic cache_valid,output logic cache_ready,input logic [7:0] cache_data,input logic cache_last,
    input logic cache_completion_valid,output logic cache_completion_ready,
    input logic [31:0] cache_completion_id,input logic [3:0] cache_completion_status,
    output logic out_valid,input logic out_ready,output logic signed [31:0] out_data,
    output logic [15:0] out_index,output logic out_last,
    output logic completion_valid,input logic completion_ready,output logic [7:0] completion_status
);
    import task_desc_pkg::*;import kv_cache_pkg::*;
    localparam integer MG=(MAX_DIM+GROUP_SIZE-1)/GROUP_SIZE;
    typedef enum logic [4:0] {IDLE,LOAD_Q,REQUEST,READ_BYTES,READ_FENCE,DOT,SCALE_Q,SCALE_K,ACCUM,
        SCORE_ROUND,SCORE_GAIN,SCORE_SAVE,EXP_START,EXP_READ,EXP_WAIT,PROB,DIVIDE,PROB_SAVE,
        VALUE,VALUE_WEIGHT,VALUE_ACCUM,OUTPUT_VALUE,COMPLETE} state_t;
    state_t state;
    attention_pkg::attention_task_t active;
    logic signed [7:0] q[0:MAX_DIM-1],keys[0:MAX_TOKENS*MAX_DIM-1],values[0:MAX_TOKENS*MAX_DIM-1];
    logic [15:0] qs[0:MG-1],ks[0:MAX_TOKENS*MG-1],vs[0:MAX_TOKENS*MG-1];
    logic signed [63:0] scores[0:MAX_TOKENS-1];
    logic [16:0] exps[0:MAX_TOKENS-1],probabilities[0:MAX_TOKENS-1];
    logic [15:0] qp,token_idx,dim_idx,group_idx,byte_pos,width,read_token,groups;
    logic [1:0] plane;
    logic signed [31:0] group_dot;
    logic signed [63:0] score_rounded,max_score;
    logic signed [63:0] product_q,product_k,score_sum,value_sum;
    logic signed [63:0] gained_score,product_v,weighted_value;
    logic [33:0] dividend,quotient;logic [32:0] remainder;logic [5:0] division_step;
    wire [32:0] trial={remainder[31:0],dividend[33]};
    logic [31:0] exp_sum;
    wire take_bit=trial>={1'b0,exp_sum};
    logic [8:0] exp_address;logic [16:0] exp_value;
    wire signed [31:0] next_dot=group_dot+32'($signed(q[dim_idx]))*32'($signed(keys[32'(token_idx)*MAX_DIM+dim_idx]));
    wire [64:0] difference=65'($signed(max_score))-65'($signed(scores[token_idx]));
    wire [64:0] exp_index=(difference+2048)>>12;
    initial if(MAX_DIM<1 || MAX_DIM>64 || MAX_TOKENS<1 || MAX_TOKENS>16 || GROUP_SIZE<1 || GROUP_SIZE>64)
        $fatal(1,"Unsupported bounded attention hardware parameters");
    function automatic logic signed [63:0] round_wide(input logic signed [63:0] v,input integer shift);
        logic signed [64:0] mag,res;
        mag=v<0?-65'(v):65'(v);mag=(mag+(65'd1<<(shift-1)))>>>shift;
        res=v<0?-mag:mag;return res[63:0];
    endfunction
    function automatic logic signed [31:0] rounded(input logic signed [63:0] v,input integer shift);
        logic signed [64:0] wide,mag,res;
        wide=65'(v);mag=wide<0?-wide:wide;mag=(mag+(65'd1<<(shift-1)))>>>shift;
        res=wide<0?-mag:mag;
        if(res>65'sd2147483647) return 32'sh7fffffff;
        if(res< -65'sd2147483648) return 32'sh80000000;
        return res[31:0];
    endfunction
    attention_exp_lut exponential(.clk(clk),.en(state==EXP_READ),.address(exp_address),.data(exp_value));
    assign query_ready=state==IDLE && !rst;
    assign q_ready=state==LOAD_Q && !rst;
    assign cmd_valid=state==REQUEST && !rst;
    assign cache_ready=state==READ_BYTES && !rst;
    assign cache_completion_ready=(state==READ_BYTES || state==READ_FENCE) && !rst;
    assign out_valid=state==OUTPUT_VALUE && !rst;
    assign out_data=rounded(value_sum,12);
    assign out_index=dim_idx;
    assign out_last=dim_idx+1==active.dimension;
    assign completion_valid=state==COMPLETE && !rst;
    always_comb begin
        cmd_desc='0;cmd_desc.task_id=active.task_id;cmd_desc.operation=KV_READ;cmd_desc.plane=plane;
        cmd_desc.layer=active.layer;cmd_desc.head=active.head;cmd_desc.count=active.tokens;
        cmd_desc.length=plane<2?active.dimension:2*groups;
        width=plane<2?active.dimension:2*groups;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE;active<='0;completion_status<=STATUS_OK;qp<=0;plane<=0;
            token_idx<=0;dim_idx<=0;group_idx<=0;byte_pos<=0;read_token<=0;groups<=0;
            group_dot<=0;product_q<=0;product_k<=0;score_sum<=0;score_rounded<=0;max_score<=64'sh8000000000000000;
            exp_sum<=0;exp_address<=0;value_sum<=0;
            gained_score<=0;product_v<=0;weighted_value<=0;dividend<=0;quotient<=0;remainder<=0;division_step<=0;
        end else case(state)
            IDLE:if(query_valid) begin
                active<=query_desc;completion_status<=STATUS_OK;qp<=0;plane<=0;byte_pos<=0;read_token<=0;
                groups<=(query_desc.dimension+GROUP_SIZE-1)/GROUP_SIZE;
                if(!metadata_valid || query_desc.tokens==0 || query_desc.tokens>committed_tokens ||
                    query_desc.tokens>MAX_TOKENS || query_desc.dimension==0 || query_desc.dimension>MAX_DIM ||
                    query_desc.dimension!=cache_dimension || query_desc.score_scale==0) begin
                    completion_status<=STATUS_BAD_DIM;state<=COMPLETE;
                end else state<=LOAD_Q;
            end
            LOAD_Q:if(q_valid) begin
                if(q_last!=(qp+1==active.dimension) || (qp%GROUP_SIZE!=0 && q_scale!=qs[qp/GROUP_SIZE])) begin
                    completion_status<=STATUS_MEMORY_PROTOCOL;state<=COMPLETE;
                end else begin
                    q[qp]<=q_data;if(qp%GROUP_SIZE==0) qs[qp/GROUP_SIZE]<=q_scale;
                    if(qp+1==active.dimension) state<=REQUEST;else qp<=qp+1;
                end
            end
            REQUEST:if(cmd_ready) state<=READ_BYTES;
            READ_BYTES:begin
                if(cache_valid) begin
                    if(cache_last!=(read_token+1==active.tokens && byte_pos+1==width)) begin
                        completion_status<=STATUS_MEMORY_PROTOCOL;
                        // Still consume the remainder and the KV fence before returning.
                    end
                    case(plane)
                        KV_K:keys[32'(read_token)*MAX_DIM+byte_pos]<=cache_data;
                        KV_V:values[32'(read_token)*MAX_DIM+byte_pos]<=cache_data;
                        KV_SK:ks[32'(read_token)*MG+byte_pos/2][byte_pos[0]*8 +:8]<=cache_data;
                        KV_SV:vs[32'(read_token)*MG+byte_pos/2][byte_pos[0]*8 +:8]<=cache_data;
                    endcase
                    if(byte_pos+1==width) begin
                        byte_pos<=0;
                        if(read_token+1==active.tokens) state<=READ_FENCE;
                        else read_token<=read_token+1;
                    end else byte_pos<=byte_pos+1;
                end
                if(cache_completion_valid) begin completion_status<=STATUS_READ_ERROR;state<=COMPLETE;end
            end
            READ_FENCE:if(cache_completion_valid) begin
                if(cache_completion_status!=0 || cache_completion_id!=active.task_id) begin completion_status<=STATUS_READ_ERROR;state<=COMPLETE;end
                else if(completion_status!=0) state<=COMPLETE;
                else if(plane!=KV_SV) begin plane<=plane+1;read_token<=0;byte_pos<=0;state<=REQUEST;end
                else begin token_idx<=0;dim_idx<=0;group_idx<=0;group_dot<=0;score_sum<=0;max_score<=64'sh8000000000000000;state<=DOT;end
            end
            DOT:begin
                group_dot<=next_dot;
                if((dim_idx+1)%GROUP_SIZE==0 || dim_idx+1==active.dimension) state<=SCALE_Q;
                else dim_idx<=dim_idx+1;
            end
            SCALE_Q:begin product_q<=64'($signed(group_dot))*64'($signed({1'b0,qs[group_idx]}));state<=SCALE_K;end
            SCALE_K:begin product_k<=product_q*64'($signed({1'b0,ks[32'(token_idx)*MG+group_idx]}));state<=ACCUM;end
            ACCUM:begin
                score_sum<=score_sum+product_k;group_dot<=0;
                if(dim_idx+1==active.dimension) state<=SCORE_ROUND;
                else begin dim_idx<=dim_idx+1;group_idx<=group_idx+1;state<=DOT;end
            end
            SCORE_ROUND:begin score_rounded<=round_wide(score_sum,8);state<=SCORE_GAIN;end
            SCORE_GAIN:begin
                gained_score<=score_rounded*64'($signed({1'b0,active.score_scale}));state<=SCORE_SAVE;
            end
            SCORE_SAVE:begin
                scores[token_idx]<=round_wide(gained_score,12);
                if(round_wide(gained_score,12)>max_score) max_score<=round_wide(gained_score,12);
                if(token_idx+1==active.tokens) begin token_idx<=0;exp_sum<=0;state<=EXP_START;end
                else begin token_idx<=token_idx+1;dim_idx<=0;group_idx<=0;score_sum<=0;state<=DOT;end
            end
            EXP_START:begin exp_address<=exp_index>256?9'd256:exp_index[8:0];state<=EXP_READ;end
            EXP_READ:state<=EXP_WAIT;
            EXP_WAIT:begin
                exps[token_idx]<=exp_value;exp_sum<=exp_sum+32'(exp_value);
                if(token_idx+1==active.tokens) begin token_idx<=0;state<=PROB;end
                else begin token_idx<=token_idx+1;state<=EXP_START;end
            end
            PROB:begin
                dividend<=34'((64'(exps[token_idx])<<16)+64'(exp_sum/2));
                quotient<=0;remainder<=0;division_step<=0;state<=DIVIDE;
            end
            DIVIDE:begin
                dividend<={dividend[32:0],1'b0};quotient<={quotient[32:0],take_bit};
                remainder<=take_bit?trial-{1'b0,exp_sum}:trial;
                if(division_step==33) state<=PROB_SAVE;else division_step<=division_step+1;
            end
            PROB_SAVE:begin
                probabilities[token_idx]<=quotient[16:0];
                if(token_idx+1==active.tokens) begin token_idx<=0;dim_idx<=0;value_sum<=0;state<=VALUE;end
                else begin token_idx<=token_idx+1;state<=PROB;end
            end
            VALUE:begin
                product_v<=64'($signed(values[32'(token_idx)*MAX_DIM+dim_idx]))*
                    64'($signed({1'b0,vs[32'(token_idx)*MG+dim_idx/GROUP_SIZE]}));state<=VALUE_WEIGHT;
            end
            VALUE_WEIGHT:begin weighted_value<=product_v*64'($signed({1'b0,probabilities[token_idx]}));state<=VALUE_ACCUM;end
            VALUE_ACCUM:begin
                value_sum<=value_sum+weighted_value;
                if(token_idx+1==active.tokens) state<=OUTPUT_VALUE;
                else begin token_idx<=token_idx+1;state<=VALUE;end
            end
            OUTPUT_VALUE:if(out_ready) begin
                if(out_last) state<=COMPLETE;
                else begin dim_idx<=dim_idx+1;token_idx<=0;value_sum<=0;state<=VALUE;end
            end
            COMPLETE:if(completion_ready) state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
