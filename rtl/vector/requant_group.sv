// Q16.16 -> signed INT8, externally supplied UQ4.12 scale.
// One descriptor and one scalar in flight. See docs/requant_interface.md.
module requant_group #(
    parameter integer GROUP_SIZE=32,
    parameter integer MAX_K=4096
)(
    input logic clk, rst,
    input logic cfg_valid,
    output wire cfg_ready,
    input logic [15:0] cfg_row, cfg_group, cfg_k, cfg_len, cfg_scale,
    input logic in_valid, in_pause,
    output wire in_ready,
    input logic signed [31:0] in_data,
    output wire out_valid,
    input logic out_ready,
    output logic signed [7:0] out_data,
    output logic out_saturated,
    output wire [15:0] out_row, out_group, out_index, out_scale,
    output wire out_last,
    output wire busy,
    output logic done,
    output logic [1:0] error_code,
    output logic group_saturated
);
    typedef enum logic [2:0] {IDLE, INPUT_DATA, DIVIDE, ROUND, OUTPUT_DATA} state_t;
    state_t state;
    logic [15:0] row_tag, group_tag, length, index_tag, scale_tag;
    logic [19:0] divisor;
    logic negative;
    logic [31:0] dividend, quotient;
    logic [20:0] remainder;
    logic [5:0] steps;
    // Explicit 33-bit negation is safe for INT32_MIN.
    wire signed [32:0] extended_input={in_data[31],in_data};
    wire [32:0] magnitude=in_data[31] ? $unsigned(-extended_input) : $unsigned(extended_input);
    wire [20:0] trial={remainder[19:0],dividend[31]};
    wire take_bit=trial>={1'b0,divisor};
    wire [32:0] rounded={1'b0,quotient}+33'(({remainder,1'b0}>={2'b0,divisor}));
    wire saturation=negative ? rounded>33'd128 : rounded>33'd127;
    // Constant GROUP_SIZE multiply, widened before arithmetic. No runtime divider.
    wire [31:0] group_start=32'(cfg_group)*GROUP_SIZE;
    wire [31:0] remaining=32'(cfg_k)-group_start;
    wire [31:0] expected_len=remaining<GROUP_SIZE ? remaining : GROUP_SIZE;
    wire illegal_group=cfg_k==0 || cfg_k>MAX_K || group_start>=32'(cfg_k) ||
        cfg_len==0 || 32'(cfg_len)!=expected_len;
    assign cfg_ready=!rst && state==IDLE;
    assign busy=state!=IDLE;
    assign in_ready=!rst && !in_pause && state==INPUT_DATA;
    assign out_valid=!rst && state==OUTPUT_DATA;
    assign out_row=row_tag;
    assign out_group=group_tag;
    assign out_index=index_tag;
    assign out_scale=scale_tag;
    assign out_last=index_tag+16'd1==length;

    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE; done<=0; error_code<=0; group_saturated<=0;
            row_tag<=0; group_tag<=0; length<=0; index_tag<=0; scale_tag<=0;
            divisor<=0; negative<=0; dividend<=0; quotient<=0; remainder<=0; steps<=0;
            out_data<=0; out_saturated<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(cfg_valid && cfg_ready) begin
                    group_saturated<=0;
                    // Descriptor rejection consumes no data. Group error has priority.
                    if(illegal_group) begin error_code<=2; done<=1; end
                    else if(cfg_scale==0) begin error_code<=1; done<=1; end
                    else begin
                        error_code<=0; row_tag<=cfg_row; group_tag<=cfg_group;
                        length<=cfg_len; index_tag<=0; scale_tag<=cfg_scale;
                        divisor<={cfg_scale,4'b0}; state<=INPUT_DATA;
                    end
                end
                INPUT_DATA: if(in_valid && in_ready) begin
                    negative<=in_data[31]; dividend<=magnitude[31:0];
                    quotient<=0; remainder<=0; steps<=0; state<=DIVIDE;
                end
                DIVIDE: begin
                    dividend<={dividend[30:0],1'b0};
                    quotient<={quotient[30:0],take_bit};
                    remainder<=take_bit ? trial-{1'b0,divisor} : trial;
                    if(steps==31) state<=ROUND;
                    else steps<=steps+1;
                end
                ROUND: begin
                    out_saturated<=saturation;
                    group_saturated<=group_saturated || saturation;
                    if(saturation) out_data<=negative ? 8'sh80 : 8'sh7f;
                    else out_data<=negative ? -$signed(rounded[7:0]) : $signed(rounded[7:0]);
                    state<=OUTPUT_DATA;
                end
                OUTPUT_DATA: if(out_ready) begin
                    if(out_last) begin state<=IDLE; done<=1; end
                    else begin index_tag<=index_tag+1; state<=INPUT_DATA; end
                end
                default: state<=IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial begin
        if(GROUP_SIZE<1 || GROUP_SIZE>4096 || MAX_K<1 || MAX_K>65535)
            $fatal(1,"REQUANT_BAD_PARAMETER");
    end
    // synthesis translate_on
endmodule
