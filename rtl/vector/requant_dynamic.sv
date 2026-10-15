// Single synchronous group buffer; external-scale scalar baseline is unchanged.
module requant_dynamic #(
    parameter integer GROUP_SIZE=32, MAX_K=4096
)(
    input logic clk,rst,cfg_valid,
    output wire cfg_ready,
    input logic [15:0] cfg_row,cfg_group,cfg_k,cfg_len,
    input logic in_valid,in_pause,
    output wire in_ready,
    input logic signed [31:0] in_data,
    output wire out_valid,
    input logic out_ready,
    output wire signed [7:0] out_data,
    output wire [15:0] out_row,out_group,out_index,out_scale,
    output wire out_last,out_saturated,group_saturated,
    output logic scale_clipped,
    output logic [31:0] group_absmax,
    output wire busy,
    output logic done,
    output logic [1:0] error_code
);
    localparam integer AW=(GROUP_SIZE<=1)?1:$clog2(GROUP_SIZE);
    typedef enum logic [3:0] {IDLE,COLLECT,SCALE_DIV,SCALE_SET,QCFG,READ_REQ,READ_SEND,WAIT_OUT} state_t;
    state_t state;
    logic [15:0] row_tag,group_tag,k_tag,length,write_index,read_index,scale;
    logic [31:0] dividend,quotient;
    logic [11:0] remainder;
    logic [5:0] steps;
    logic accumulated_sat;
    wire signed [32:0] extended_input={in_data[31],in_data};
    wire [32:0] magnitude=in_data[31]?$unsigned(-extended_input):$unsigned(extended_input);
    wire [31:0] next_absmax=magnitude>group_absmax?magnitude[31:0]:group_absmax;
    wire [11:0] trial={remainder[10:0],dividend[31]};
    wire bit_taken=trial>=12'd2032;
    wire [32:0] ceiling_scale={1'b0,quotient}+33'(remainder!=0);
    wire [31:0] start_k=32'(cfg_group)*GROUP_SIZE;
    wire [31:0] remaining=32'(cfg_k)-start_k;
    wire illegal=cfg_k==0 || cfg_k>MAX_K || start_k>=32'(cfg_k) || cfg_len==0 ||
        32'(cfg_len)!=(remaining<GROUP_SIZE?remaining:GROUP_SIZE);
    wire wr_en=!rst && in_valid && in_ready;
    wire rd_en=!rst && state==READ_REQ;
    wire [31:0] buffer_q;
    sync_sdp_ram #(.WIDTH(32),.DEPTH(GROUP_SIZE),.STYLE("block")) group_buffer(
        .clk(clk),.wr_en(wr_en),.wr_addr(write_index[AW-1:0]),.wr_data(in_data),
        .rd_en(rd_en),.rd_addr(read_index[AW-1:0]),.rd_data(buffer_q));
    wire q_cfg_ready,q_in_ready,q_out_valid,q_done,q_busy;
    wire [1:0] q_error;
    requant_group #(.GROUP_SIZE(GROUP_SIZE),.MAX_K(MAX_K)) scalar(
        .clk(clk),.rst(rst),.cfg_valid(!rst && state==QCFG),.cfg_ready(q_cfg_ready),
        .cfg_row(row_tag),.cfg_group(group_tag),.cfg_k(k_tag),.cfg_len(length),.cfg_scale(scale),
        .in_valid(!rst && state==READ_SEND),.in_pause(1'b0),.in_ready(q_in_ready),.in_data($signed(buffer_q)),
        .out_valid(q_out_valid),.out_ready(out_ready && state==WAIT_OUT),.out_data(out_data),
        .out_row(out_row),.out_group(out_group),.out_index(out_index),.out_scale(out_scale),
        .out_last(out_last),.out_saturated(out_saturated),.group_saturated(),
        .busy(q_busy),.done(q_done),.error_code(q_error));
    assign cfg_ready=!rst && state==IDLE;
    assign busy=state!=IDLE;
    assign in_ready=!rst && !in_pause && state==COLLECT;
    assign out_valid=!rst && state==WAIT_OUT && q_out_valid;
    assign group_saturated=accumulated_sat || (out_valid && out_saturated);
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE;done<=0;error_code<=0;scale_clipped<=0;group_absmax<=0;accumulated_sat<=0;
            row_tag<=0;group_tag<=0;k_tag<=0;length<=0;write_index<=0;read_index<=0;scale<=0;
            dividend<=0;quotient<=0;remainder<=0;steps<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(cfg_valid && cfg_ready) begin
                    scale_clipped<=0;group_absmax<=0;error_code<=0;accumulated_sat<=0;
                    if(illegal) begin error_code<=2;done<=1;end
                    else begin
                        row_tag<=cfg_row;group_tag<=cfg_group;k_tag<=cfg_k;length<=cfg_len;
                        write_index<=0;read_index<=0;state<=COLLECT;
                    end
                end
                COLLECT: if(wr_en) begin
                    group_absmax<=next_absmax;
                    if(write_index+1==length) begin
                        dividend<=next_absmax;quotient<=0;remainder<=0;steps<=0;state<=SCALE_DIV;
                    end else write_index<=write_index+1;
                end
                SCALE_DIV: begin
                    dividend<={dividend[30:0],1'b0};quotient<={quotient[30:0],bit_taken};
                    remainder<=bit_taken?trial-12'd2032:trial;
                    if(steps==31) state<=SCALE_SET;else steps<=steps+1;
                end
                SCALE_SET: begin
                    scale_clipped<=ceiling_scale>33'd65535;
                    scale<=ceiling_scale>33'd65535 ? 16'hffff : (ceiling_scale==0 ? 16'd1 : ceiling_scale[15:0]);
                    state<=QCFG;
                end
                QCFG: if(q_cfg_ready) state<=READ_REQ;
                READ_REQ: state<=READ_SEND;
                READ_SEND: if(q_in_ready) state<=WAIT_OUT;
                WAIT_OUT: if(out_valid && out_ready) begin
                    accumulated_sat<=accumulated_sat || out_saturated;
                    if(out_last) begin state<=IDLE;done<=1;end
                    else begin read_index<=read_index+1;state<=READ_REQ;end
                end
                default: state<=IDLE;
            endcase
        end
    end
    // synthesis translate_off
    always @(posedge clk) if(!rst) begin
        if(wr_en && rd_en) $fatal(1,"DYNAMIC_BUFFER_OWNERSHIP");
        if(wr_en && write_index>=length) $fatal(1,"DYNAMIC_BUFFER_WRITE_OOB");
        if(rd_en && read_index>=length) $fatal(1,"DYNAMIC_BUFFER_READ_OOB");
        if(state==READ_REQ && q_error!=0) $fatal(1,"DYNAMIC_INTERNAL_DESCRIPTOR");
    end
    // synthesis translate_on
endmodule
