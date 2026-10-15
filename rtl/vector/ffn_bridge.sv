// Bounded coordinate assembly -> scalar SwiGLU -> row/group dynamic quantization.
// One task, one accepted gate/up element per clock, sequential stages, no DMA.
module ffn_bridge #(
    parameter integer GROUP_SIZE=32,MAX_M=64,MAX_H=64,CAPACITY=512,
    parameter integer AW=(CAPACITY<=1)?1:$clog2(CAPACITY)
)(
    input logic clk,rst,cfg_valid,
    output wire cfg_ready,
    input logic [15:0] cfg_m,cfg_h,
    input logic in_valid,in_branch,
    output wire in_ready,
    input logic [15:0] in_row,in_col,
    input logic signed [31:0] in_data,
    output wire out_valid,
    input logic out_ready,
    output wire signed [7:0] out_data,
    output wire [15:0] out_row,out_group,out_index,out_scale,
    output wire out_last,out_task_last,out_saturated,group_saturated,scale_clipped,
    output wire [31:0] group_absmax,
    output logic nonlinear_saturated,
    output wire busy,
    output logic done,
    output logic [1:0] error_code
);
    typedef enum logic [3:0] {IDLE,COLLECT,QCFG,PAIR_REQ,PAIR_SEND,PAIR_WAIT,QWAIT} state_t;
    state_t state;
    logic [15:0] m,h,row,col,group_tag,index,length;
    logic [31:0] gate_count,up_count;
    logic [CAPACITY-1:0] gate_seen,up_seen;
    wire [31:0] total=32'(m)*32'(h);
    wire [31:0] incoming_address=32'(in_row)*32'(h)+32'(in_col);
    wire [31:0] read_address=32'(row)*32'(h)+32'(col);
    wire bad_input=in_row>=m || in_col>=h || incoming_address>=CAPACITY ||
        (in_branch?up_seen[incoming_address[AW-1:0]]:gate_seen[incoming_address[AW-1:0]]);
    wire accept=in_valid && in_ready;
    wire write_ok=accept && !bad_input;
    wire read_enable=!rst && state==PAIR_REQ;
    wire [31:0] gate_q,up_q;
    sync_sdp_ram #(.WIDTH(32),.DEPTH(CAPACITY)) gates(
        .clk(clk),.wr_en(write_ok && !in_branch),.wr_addr(incoming_address[AW-1:0]),.wr_data(in_data),
        .rd_en(read_enable),.rd_addr(read_address[AW-1:0]),.rd_data(gate_q));
    sync_sdp_ram #(.WIDTH(32),.DEPTH(CAPACITY)) ups(
        .clk(clk),.wr_en(write_ok && in_branch),.wr_addr(incoming_address[AW-1:0]),.wr_data(in_data),
        .rd_en(read_enable),.rd_addr(read_address[AW-1:0]),.rd_data(up_q));
    wire e_ready,e_valid,e_sat,q_ready,q_in_ready,q_valid,q_done;
    wire signed [31:0] e_silu,e_product;
    wire [15:0] e_row,e_col;
    wire [1:0] q_error;
    swiglu_element nonlinear(
        .clk(clk),.rst(rst),.in_valid(!rst && state==PAIR_SEND),.in_ready(e_ready),
        .in_gate($signed(gate_q)),.in_up($signed(up_q)),.in_row(row),.in_col(col),
        .out_valid(e_valid),.out_ready(state==PAIR_WAIT && q_in_ready),
        .out_silu(e_silu),.out_data(e_product),.out_saturated(e_sat),.out_row(e_row),.out_col(e_col));
    requant_dynamic #(.GROUP_SIZE(GROUP_SIZE),.MAX_K(MAX_H)) quantizer(
        .clk(clk),.rst(rst),.cfg_valid(!rst && state==QCFG),.cfg_ready(q_ready),
        .cfg_row(row),.cfg_group(group_tag),.cfg_k(h),.cfg_len(length),
        .in_valid(!rst && state==PAIR_WAIT && e_valid),.in_pause(1'b0),.in_ready(q_in_ready),.in_data(e_product),
        .out_valid(q_valid),.out_ready(state==QWAIT && out_ready),.out_data(out_data),
        .out_row(out_row),.out_group(out_group),.out_index(out_index),.out_scale(out_scale),
        .out_last(out_last),.out_saturated(out_saturated),.group_saturated(group_saturated),
        .scale_clipped(scale_clipped),.group_absmax(group_absmax),.busy(),.done(q_done),.error_code(q_error));
    assign cfg_ready=!rst && state==IDLE;
    assign in_ready=!rst && state==COLLECT;
    assign out_valid=!rst && state==QWAIT && q_valid;
    assign out_task_last=out_last && row+1==m && col+1==h;
    assign busy=state!=IDLE;
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE;done<=0;error_code<=0;nonlinear_saturated<=0;
            m<=0;h<=0;row<=0;col<=0;group_tag<=0;index<=0;length<=0;
            gate_count<=0;up_count<=0;gate_seen<='0;up_seen<='0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(cfg_valid && cfg_ready) begin
                    error_code<=0;nonlinear_saturated<=0;gate_count<=0;up_count<=0;
                    gate_seen<='0;up_seen<='0;
                    if(cfg_m==0 || cfg_m>MAX_M || cfg_h==0 || cfg_h>MAX_H ||
                       32'(cfg_m)*32'(cfg_h)>CAPACITY) begin error_code<=1;done<=1;end
                    else begin m<=cfg_m;h<=cfg_h;state<=COLLECT;end
                end
                COLLECT: if(accept) begin
                    if(bad_input) begin error_code<=2;done<=1;state<=IDLE;end
                    else begin
                        if(in_branch) begin up_seen[incoming_address[AW-1:0]]<=1;up_count<=up_count+1;end
                        else begin gate_seen[incoming_address[AW-1:0]]<=1;gate_count<=gate_count+1;end
                        if(gate_count+32'(!in_branch)==total && up_count+32'(in_branch)==total) begin
                            row<=0;col<=0;group_tag<=0;index<=0;
                            length<=h<GROUP_SIZE?h:16'(GROUP_SIZE);state<=QCFG;
                        end
                    end
                end
                QCFG: if(q_ready) state<=PAIR_REQ;
                PAIR_REQ: state<=PAIR_SEND;
                PAIR_SEND: if(e_ready) state<=PAIR_WAIT;
                PAIR_WAIT: if(e_valid && q_in_ready) begin
                    nonlinear_saturated<=nonlinear_saturated || e_sat;
                    if(index+1==length) state<=QWAIT;
                    else begin index<=index+1;col<=col+1;state<=PAIR_REQ;end
                end
                QWAIT: if(out_valid && out_ready && out_last) begin
                    if(row+1==m && col+1==h) begin state<=IDLE;done<=1;end
                    else begin
                        if(col+1==h) begin
                            row<=row+1;col<=0;group_tag<=0;length<=h<GROUP_SIZE?h:16'(GROUP_SIZE);
                        end else begin
                            col<=col+1;group_tag<=group_tag+1;
                            length<=(h-col-1)<GROUP_SIZE?(h-col-1):16'(GROUP_SIZE);
                        end
                        index<=0;state<=QCFG;
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
    // synthesis translate_off
    always @(posedge clk) if(!rst) begin
        if(read_enable && (!gate_seen[read_address[AW-1:0]] || !up_seen[read_address[AW-1:0]] || read_address>=CAPACITY))
            $fatal(1,"FFN_UNINITIALIZED_PAIR");
        if(write_ok && read_enable) $fatal(1,"FFN_BUFFER_OWNERSHIP");
        if(state!=IDLE && q_error!=0) $fatal(1,"FFN_INTERNAL_DESCRIPTOR");
    end
    // synthesis translate_on
endmodule
