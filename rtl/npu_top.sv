// Ordered NPU command front end; resident A/B buffers are immutable until drained.
module npu_top #(
    parameter integer ROWS=4, COLS=4, TILE_K=8,
    parameter integer MAX_M=16, MAX_N=16, MAX_K=32,
    parameter integer QUEUE_DEPTH=4
)(
    input logic clk, rst, pause,
    input logic wr_valid, wr_matrix,
    output logic wr_ready,
    input logic [15:0] wr_row, wr_col,
    input logic signed [7:0] wr_data,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [7:0] cmd_opcode,
    input logic [15:0] cmd_tag, cmd_m, cmd_n, cmd_k,
    output logic completion_valid,
    input logic completion_ready,
    output logic [15:0] completion_tag, completion_m, completion_n, completion_k,
    output logic [7:0] completion_status,
    output logic [31:0] completion_cycles, completion_active_cycles,
    input logic rd_req,
    output logic rd_ready,
    input logic [15:0] rd_row, rd_col,
    output wire rd_valid,
    output wire signed [31:0] rd_data,
    output logic busy, buffers_locked, result_available,
    output logic [$clog2(QUEUE_DEPTH+1)-1:0] queued_count
);
    localparam integer PW=(QUEUE_DEPTH<=1)?1:$clog2(QUEUE_DEPTH);
    typedef enum logic [1:0] {IDLE,LAUNCH,RUN,COMPLETE} state_t;
    state_t state;
    // A small, explicit register FIFO: one enqueue and one dequeue per clock.
    // Non-power-of-two depths are supported. No arbitrary multi-port RAM.
    (* ram_style="registers" *) logic [71:0] descriptors [0:QUEUE_DEPTH-1];
    logic [PW-1:0] write_ptr, read_ptr;
    logic push, pop, load_allowed, core_wr_ready, core_rd_ready;
    logic core_start_ready, core_busy, core_done, core_error, core_result;
    logic [31:0] core_cycles,core_active_cycles;
    wire [71:0] head = descriptors[read_ptr];
    assign cmd_ready = !rst && !pause && queued_count<QUEUE_DEPTH;
    assign push = cmd_valid && cmd_ready;
    assign pop = !rst && !pause && state==IDLE && queued_count!=0;
    assign busy = state==LAUNCH || state==RUN;
    assign buffers_locked = state!=IDLE || queued_count!=0;
    // A descriptor wins over an input write on the same edge.
    assign load_allowed = !buffers_locked && !cmd_valid;
    assign wr_ready = load_allowed && core_wr_ready;
    assign result_available = state==COMPLETE && completion_status==0 && core_result;
    assign completion_valid = !rst && state==COMPLETE;
    // Completion acknowledgement wins over a new result read. A response from
    // a read already accepted is still forwarded; host must finish reads first.
    assign rd_ready = result_available && !completion_ready && core_rd_ready;

    matmul_top #(.ROWS(ROWS),.COLS(COLS),.TILE_K(TILE_K),
        .MAX_M(MAX_M),.MAX_N(MAX_N),.MAX_K(MAX_K),
        .OPTIMIZED(1),.DOUBLE_BUFFER(1),.B_LOAD_GAP(0)) engine (
        .clk(clk),.rst(rst),.pause(pause),
        .wr_valid(wr_valid && load_allowed),.wr_ready(core_wr_ready),
        .wr_matrix(wr_matrix),.wr_row(wr_row),.wr_col(wr_col),.wr_data(wr_data),
        .cfg_m(completion_m),.cfg_n(completion_n),.cfg_k(completion_k),
        .start(state==LAUNCH && !pause && !rst),.start_ready(core_start_ready),
        .busy(core_busy),.done(core_done),.error(core_error),.result_available(core_result),
        .rd_req(rd_req && result_available && !completion_ready),.rd_ready(core_rd_ready),
        .rd_row(rd_row),.rd_col(rd_col),.rd_valid(rd_valid),.rd_data(rd_data),
        .cycle_count(core_cycles),.active_cycles(core_active_cycles));

    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE;read_ptr<=0;write_ptr<=0;queued_count<=0;
            completion_tag<=0;completion_m<=0;completion_n<=0;completion_k<=0;
            completion_status<=0;completion_cycles<=0;completion_active_cycles<=0;
        end else begin
            if(push) begin
                descriptors[write_ptr]<={cmd_opcode,cmd_tag,cmd_m,cmd_n,cmd_k};
                write_ptr<=(write_ptr==QUEUE_DEPTH-1)?0:write_ptr+1'b1;
            end
            if(pop) read_ptr<=(read_ptr==QUEUE_DEPTH-1)?0:read_ptr+1'b1;
            case({push,pop})
                2'b10: queued_count<=queued_count+1'b1;
                2'b01: queued_count<=queued_count-1'b1;
                default: queued_count<=queued_count;
            endcase
            case(state)
                IDLE: if(pop) begin
                    {completion_tag,completion_m,completion_n,completion_k}<=head[63:0];
                    completion_cycles<=0;completion_active_cycles<=0;
                    if(head[71:64]!=8'd1) begin // opcode 1: signed INT8 GEMM (M=1 is GEMV)
                        completion_status<=8'd2;state<=COMPLETE;
                    end else if(head[47:32]==0 || head[31:16]==0 || head[15:0]==0 ||
                                head[47:32]>MAX_M || head[31:16]>MAX_N || head[15:0]>MAX_K) begin
                        completion_status<=8'd1;state<=COMPLETE;
                    end else begin completion_status<=0;state<=LAUNCH;end
                end
                LAUNCH: if(!pause && core_start_ready) state<=RUN;
                // Capture the one-cycle core event even if pause is asserted
                // after the final active edge. Never lose a completion pulse.
                RUN: if(core_done || core_error) begin
                    completion_status<=core_error?8'd3:8'd0;
                    completion_cycles<=core_cycles;completion_active_cycles<=core_active_cycles;
                    state<=COMPLETE;
                end
                // Completion draining is allowed during pause; new dispatch
                // stays paused. All completion payload registers remain stable.
                COMPLETE: if(completion_ready) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
