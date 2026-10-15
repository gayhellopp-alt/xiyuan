// Sequential scalar Q16.16 SwiGLU, nearest/ties-away rounding at both products.
module swiglu_element(
    input logic clk,rst,in_valid,
    output wire in_ready,
    input logic signed [31:0] in_gate,in_up,
    input logic [15:0] in_row,in_col,
    output wire out_valid,
    input logic out_ready,
    output logic signed [31:0] out_silu,out_data,
    output logic out_saturated,
    output logic [15:0] out_row,out_col
);
    typedef enum logic [3:0] {IDLE,LOOKUP,INTERP,MUL_GATE,ROUND_GATE,MUL_UP,ROUND_UP,HOLD} state_t;
    state_t state;
    logic signed [31:0] gate,up;
    wire signed [32:0] extended={gate[31],gate};
    wire [32:0] magnitude=gate[31]?$unsigned(-extended):$unsigned(extended);
    wire tail=magnitude>=33'd524288;
    wire [33:0] samples;
    silu_sigmoid_lut table_rom(.clk(clk),.en(!rst && state==LOOKUP && !tail),
        .address(magnitude[18:12]),.data(samples));
    wire [16:0] lo=samples[16:0],hi=samples[33:17];
    wire [28:0] delta_product=(hi-lo)*magnitude[11:0];
    wire [16:0] interpolated=lo+17'((delta_product+29'd2048)>>12);
    logic [16:0] sigmoid;
    logic signed [63:0] product;
    wire signed [64:0] product_extended={product[63],product};
    wire [64:0] product_abs=product[63]?$unsigned(-product_extended):$unsigned(product_extended);
    wire [64:0] rounded_abs=(product_abs+65'd32768)>>16;
    wire sat=product[63]?rounded_abs>65'd2147483648:rounded_abs>65'd2147483647;
    wire signed [31:0] rounded_data=sat?(product[63]?32'sh80000000:32'sh7fffffff):
        (product[63]?-$signed(rounded_abs[31:0]):$signed(rounded_abs[31:0]));
    assign in_ready=!rst && state==IDLE;
    assign out_valid=!rst && state==HOLD;
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE;gate<=0;up<=0;sigmoid<=0;product<=0;
            out_silu<=0;out_data<=0;out_saturated<=0;out_row<=0;out_col<=0;
        end else case(state)
            IDLE: if(in_valid && in_ready) begin
                gate<=in_gate;up<=in_up;out_row<=in_row;out_col<=in_col;
                out_saturated<=0;state<=LOOKUP;
            end
            LOOKUP: state<=INTERP;
            INTERP: begin
                sigmoid<=tail?(gate[31]?17'd0:17'd65536):
                    (gate[31]?17'd65536-interpolated:interpolated);
                state<=MUL_GATE;
            end
            MUL_GATE: begin product<=$signed(gate)*$signed({1'b0,sigmoid});state<=ROUND_GATE;end
            ROUND_GATE: begin out_silu<=rounded_data;out_saturated<=sat;state<=MUL_UP;end
            MUL_UP: begin product<=$signed(out_silu)*$signed(up);state<=ROUND_UP;end
            ROUND_UP: begin out_data<=rounded_data;out_saturated<=out_saturated || sat;state<=HOLD;end
            HOLD: if(out_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
