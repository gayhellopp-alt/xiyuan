// Streaming grouped W4A8 linear layer. Reuses validated INT8 MAC array.
module w4a8_stream #(
    parameter integer ROWS=4,COLS=4,TILE_K=8,GROUP_SIZE=32,
    parameter integer MAX_M=64,MAX_N=64,MAX_K=4096,
    parameter bit DOUBLE_BUFFER=1,
    parameter integer BUS_BYTES=8,
    parameter bit SCALE_ONCE=1
)(
    input logic clk,rst,load_pause,
    input logic start,
    output logic start_ready,busy,done,error,
    input logic [15:0] cfg_m,cfg_n,cfg_k,
    output logic req_valid,
    input logic req_ready,
    output logic [15:0] req_m,req_n,req_k,req_ml,req_nl,req_kl,req_group,
    input logic in_valid,
    output logic in_ready,
    input logic [BUS_BYTES*8-1:0] in_data,
    input logic [BUS_BYTES-1:0] in_keep,
    output logic req_scale,
    output logic out_valid,
    input logic out_ready,
    output logic [15:0] out_m,out_n,
    output logic out_last,
    output logic signed [31:0] out_data,
    output logic [31:0] total_cycles,weight_bytes,activation_bytes,scale_bytes,
    output logic [31:0] valid_macs,compute_cycles,input_wait_cycles,output_wait_cycles,overlap_cycles,
    output logic [31:0] input_beats,padding_bytes
);
    localparam integer BANKS=DOUBLE_BUFFER?2:1, RC=ROWS*COLS;
    localparam integer KW=(TILE_K<=1)?1:$clog2(TILE_K);
    localparam integer WDEPTH=(TILE_K+2)/2;
    localparam integer WW=(WDEPTH<=1)?1:$clog2(WDEPTH);
    localparam integer AD=(TILE_K+BUS_BYTES-1)/BUS_BYTES;
    localparam integer WD=(WDEPTH+BUS_BYTES-1)/BUS_BYTES;
    localparam integer AW=(AD<=1)?1:$clog2(AD), WAW=(WD<=1)?1:$clog2(WD);
    localparam integer SELW=(BUS_BYTES<=1)?1:$clog2(BUS_BYTES);
    localparam integer PW=(RC<=1)?1:$clog2(RC);
    typedef enum logic [3:0] {IDLE,INIT_Y,WAIT_TILE,CLEAR_PE,PRIME,RUN,SAVE_G,
        SCALE_REQ,SCALE_MUL,SCALE_ADD,OUT_REQ,OUT_LATCH,OUT_SEND,FINISH} state_t;
    typedef enum logic [1:0] {FREE,LOADING,READY,COMPUTING} bank_state_t;
    typedef enum logic [1:0] {WEIGHTS,ACTIVATIONS,SX,SW} phase_t;
    state_t state;
    bank_state_t bank_state[0:BANKS-1];
    phase_t phase;
    logic [15:0] m,n,k,pm,pn,pk,mt,nt,ck;
    logic producer_bank,consumer_bank,load_bank,loading,producer_done,load_scale;
    logic [15:0] bank_m[0:BANKS-1],bank_n[0:BANKS-1],bank_k[0:BANKS-1];
    logic [15:0] bank_ml[0:BANKS-1],bank_nl[0:BANKS-1],bank_kl[0:BANKS-1],bank_wbytes[0:BANKS-1];
    logic [15:0] sx[0:BANKS-1][0:ROWS-1],sw[0:BANKS-1][0:COLS-1];
    logic [15:0] load_lane,load_pos,clen,run_k,slot,cm_len,cn_len;
    logic accept_input,read_tile,read_high;
    logic [KW-1:0] read_k;
    logic [WW-1:0] read_wp;
    wire [BUS_BYTES*8-1:0] aq_word[0:BANKS-1][0:ROWS-1];
    wire signed [7:0] aq[0:BANKS-1][0:ROWS-1];
    wire [BUS_BYTES*8-1:0] wq_word[0:BANKS-1][0:COLS-1];
    wire [7:0] wq[0:BANKS-1][0:COLS-1];
    logic [SELW-1:0] a_sel,w_sel;
    logic [15:0] beat_count;
    always_comb begin
        beat_count=0;
        for(integer j=0;j<BUS_BYTES;j=j+1) beat_count=beat_count+in_keep[j];
    end
    wire signed [7:0] unpacked[0:BANKS-1][0:COLS-1];
    wire signed [7:0] av[0:ROWS-1],bv[0:COLS-1];
    wire signed [31:0] acc[0:RC-1];
    logic slot_valid;
    wire signed [31:0] psum_q;
    wire signed [63:0] y_q;
    logic [31:0] factor;
    (* use_dsp="yes" *) wire signed [64:0] full_scaled=$signed(psum_q)*$signed({1'b0,factor});
    logic signed [63:0] scaled;
    wire signed [63:0] y_write=(state==INIT_Y)?64'sd0:(y_q+scaled);

    assign busy=state!=IDLE;
    assign start_ready=!rst && !busy;
    assign req_m=pm;assign req_n=pn;assign req_k=pk;
    assign req_ml=(m-pm<ROWS)?m-pm:ROWS;
    assign req_nl=(n-pn<COLS)?n-pn:COLS;
    always_comb begin
        req_kl=TILE_K;
        if(k-pk<req_kl) req_kl=k-pk;
        if(GROUP_SIZE-pk%GROUP_SIZE<req_kl) req_kl=GROUP_SIZE-pk%GROUP_SIZE;
    end
    assign req_group=pk/GROUP_SIZE;
    assign req_scale=!SCALE_ONCE || pk+req_kl==k || (pk+req_kl)%GROUP_SIZE==0;
    assign req_valid=busy && !rst && !loading && !producer_done && bank_state[producer_bank]==FREE;
    assign in_ready=busy && !rst && loading && !load_pause;
    assign accept_input=in_ready && in_valid;
    assign cm_len=(m-mt<ROWS)?m-mt:ROWS;
    assign cn_len=(n-nt<COLS)?n-nt:COLS;
    assign slot_valid=slot/COLS<cm_len && slot%COLS<cn_len;
    assign read_tile=!rst && (state==PRIME || (state==RUN && run_k+1<clen));
    assign read_k=(state==PRIME)?0:run_k+1;
    assign read_wp=({15'd0,ck[0]}+read_k)>>1;
    assign out_valid=!rst && state==OUT_SEND;
    assign out_m=mt+slot/COLS;assign out_n=nt+slot%COLS;
    assign out_last=out_m==m-1 && out_n==n-1;

    for(genvar b=0;b<BANKS;b=b+1) begin: buffers
        for(genvar r=0;r<ROWS;r=r+1) begin: a_bank
            sync_sdp_ram #(.WIDTH(BUS_BYTES*8),.DEPTH(AD),.STYLE("distributed")) ram(
                .clk(clk),.wr_en(accept_input && load_bank==b && phase==ACTIVATIONS && load_lane==r),
                .wr_addr(AW'(load_pos/BUS_BYTES)),.wr_data(in_data),
                .rd_en(read_tile && consumer_bank==b),.rd_addr(AW'(read_k/BUS_BYTES)),.rd_data(aq_word[b][r]));
            assign aq[b][r]=aq_word[b][r][a_sel*8 +:8];
        end
        for(genvar c=0;c<COLS;c=c+1) begin: w_bank
            sync_sdp_ram #(.WIDTH(BUS_BYTES*8),.DEPTH(WD),.STYLE("distributed")) ram(
                .clk(clk),.wr_en(accept_input && load_bank==b && phase==WEIGHTS && load_lane==c),
                .wr_addr(WAW'(load_pos/BUS_BYTES)),.wr_data(in_data),
                .rd_en(read_tile && consumer_bank==b),.rd_addr(WAW'(read_wp/BUS_BYTES)),.rd_data(wq_word[b][c]));
            assign wq[b][c]=wq_word[b][c][w_sel*8 +:8];
            w4_unpack unpack(.packed_byte(wq[b][c]),.high(read_high),.value(unpacked[b][c]));
        end
    end
    for(genvar r=0;r<ROWS;r=r+1) assign av[r]=(r<cm_len)?aq[consumer_bank][r]:8'sd0;
    for(genvar c=0;c<COLS;c=c+1) assign bv[c]=(c<cn_len)?unpacked[consumer_bank][c]:8'sd0;
    mac_array #(.ROWS(ROWS),.COLS(COLS)) array_core(.clk(clk),.rst(rst),
        .clear(state==CLEAR_PE),.en(state==RUN && !rst),.a(av),.b(bv),.acc(acc));
    sync_sdp_ram #(.WIDTH(32),.DEPTH(RC)) group_psum(
        .clk(clk),.wr_en(!rst && state==SAVE_G),.wr_addr(slot[PW-1:0]),.wr_data(acc[slot]),
        .rd_en(!rst && state==SCALE_REQ),.rd_addr(slot[PW-1:0]),.rd_data(psum_q));
    sync_sdp_ram #(.WIDTH(64),.DEPTH(RC)) output_accumulator(
        .clk(clk),.wr_en(!rst && (state==INIT_Y || state==SCALE_ADD)),
        .wr_addr(slot[PW-1:0]),.wr_data(y_write),
        .rd_en(!rst && (state==SCALE_REQ || state==OUT_REQ)),.rd_addr(slot[PW-1:0]),.rd_data(y_q));

    function automatic signed [31:0] round_output(input logic signed [63:0] value);
        logic [63:0] magnitude,rounded;
        begin
            magnitude=value[63]?$unsigned(-value):$unsigned(value);
            rounded=(magnitude+64'd128)>>8;
            if(!value[63]) round_output=(rounded>64'd2147483647)?32'sh7fffffff:$signed(rounded[31:0]);
            else round_output=(rounded>64'd2147483648)?32'sh80000000:-$signed(rounded[31:0]);
        end
    endfunction
    task automatic next_output;
        begin
            if(slot==RC-1) begin
                slot<=0;ck<=0;
                if(nt+COLS>=n) begin
                    nt<=0;
                    if(mt+ROWS>=m) state<=FINISH;
                    else begin mt<=mt+ROWS;state<=INIT_Y;end
                end else begin nt<=nt+COLS;state<=INIT_Y;end
            end else begin slot<=slot+1;state<=OUT_REQ;end
        end
    endtask

    task automatic finish_packet;
        begin
            loading<=0;bank_state[load_bank]<=READY;
            producer_bank<=DOUBLE_BUFFER?~producer_bank:1'b0;
            if(pk+bank_kl[load_bank]<k) pk<=pk+bank_kl[load_bank];
            else begin
                pk<=0;
                if(pn+COLS<n) pn<=pn+COLS;
                else begin
                    pn<=0;
                    if(pm+ROWS<m) pm<=pm+ROWS;else producer_done<=1;
                end
            end
        end
    endtask
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE;done<=0;error<=0;m<=0;n<=0;k<=0;
            pm<=0;pn<=0;pk<=0;mt<=0;nt<=0;ck<=0;
            producer_bank<=0;consumer_bank<=0;load_bank<=0;loading<=0;producer_done<=0;
            phase<=WEIGHTS;load_lane<=0;load_pos<=0;clen<=0;run_k<=0;slot<=0;
            read_high<=0;a_sel<=0;w_sel<=0;load_scale<=0;factor<=0;scaled<=0;out_data<=0;
            input_beats<=0;padding_bytes<=0;
            total_cycles<=0;weight_bytes<=0;activation_bytes<=0;scale_bytes<=0;
            valid_macs<=0;compute_cycles<=0;input_wait_cycles<=0;output_wait_cycles<=0;overlap_cycles<=0;
            for(integer b=0;b<BANKS;b=b+1) begin
                bank_state[b]<=FREE;bank_m[b]<=0;bank_n[b]<=0;bank_k[b]<=0;
                bank_ml[b]<=0;bank_nl[b]<=0;bank_kl[b]<=0;bank_wbytes[b]<=0;
            end
        end else begin
            done<=0;error<=0;
            if(start && start_ready) begin
                if(cfg_m==0 || cfg_n==0 || cfg_k==0 || cfg_m>MAX_M || cfg_n>MAX_N || cfg_k>MAX_K) error<=1;
                else begin
                    m<=cfg_m;n<=cfg_n;k<=cfg_k;state<=INIT_Y;
                    input_beats<=0;padding_bytes<=0;
                    pm<=0;pn<=0;pk<=0;mt<=0;nt<=0;ck<=0;slot<=0;
                    producer_bank<=0;consumer_bank<=0;loading<=0;producer_done<=0;
                    for(integer b=0;b<BANKS;b=b+1) bank_state[b]<=FREE;
                    total_cycles<=0;weight_bytes<=0;activation_bytes<=0;scale_bytes<=0;
                    valid_macs<=0;compute_cycles<=0;input_wait_cycles<=0;output_wait_cycles<=0;overlap_cycles<=0;
                end
            end else if(busy) begin
                total_cycles<=total_cycles+1;
                if(state==RUN) begin
                    compute_cycles<=compute_cycles+1;
                    valid_macs<=valid_macs+cm_len*cn_len;
                    if(accept_input) overlap_cycles<=overlap_cycles+1;
                end
                if(state==WAIT_TILE && bank_state[consumer_bank]!=READY) input_wait_cycles<=input_wait_cycles+1;
                if(state==OUT_SEND && !out_ready) output_wait_cycles<=output_wait_cycles+1;
                if(read_tile) begin
                    read_high<=(ck[0]+read_k)&1;a_sel<=read_k%BUS_BYTES;w_sel<=read_wp%BUS_BYTES;
                end
                // Producer: one request outstanding, word writes with finite bank ports.
                if(req_valid && req_ready) begin
                    load_bank<=producer_bank;loading<=1;load_scale<=req_scale;
                    bank_state[producer_bank]<=LOADING;
                    bank_m[producer_bank]<=pm;bank_n[producer_bank]<=pn;bank_k[producer_bank]<=pk;
                    bank_ml[producer_bank]<=req_ml;bank_nl[producer_bank]<=req_nl;
                    bank_kl[producer_bank]<=req_kl;bank_wbytes[producer_bank]<=(pk[0]+req_kl+1)>>1;
                    phase<=WEIGHTS;load_lane<=0;load_pos<=0;
                end
                if(accept_input) begin
                    input_beats<=input_beats+1;padding_bytes<=padding_bytes+BUS_BYTES-beat_count;
                    case(phase)
                        WEIGHTS: begin
                            weight_bytes<=weight_bytes+beat_count;
                            if(load_pos+BUS_BYTES<bank_wbytes[load_bank]) load_pos<=load_pos+BUS_BYTES;
                            else begin
                                load_pos<=0;
                                if(load_lane+1<bank_nl[load_bank]) load_lane<=load_lane+1;
                                else begin load_lane<=0;phase<=ACTIVATIONS;end
                            end
                        end
                        ACTIVATIONS: begin
                            activation_bytes<=activation_bytes+beat_count;
                            if(load_pos+BUS_BYTES<bank_kl[load_bank]) load_pos<=load_pos+BUS_BYTES;
                            else begin
                                load_pos<=0;
                                if(load_lane+1<bank_ml[load_bank]) load_lane<=load_lane+1;
                                else if(load_scale) begin load_lane<=0;phase<=SX;end
                                else finish_packet();
                            end
                        end
                        SX: begin
                            scale_bytes<=scale_bytes+beat_count;
                            for(integer j=0;j<BUS_BYTES;j=j+1)
                                if(in_keep[j] && load_pos+j<2*bank_ml[load_bank])
                                    sx[load_bank][(load_pos+j)/2][((load_pos+j)%2)*8 +:8]<=in_data[j*8 +:8];
                            if(load_pos+BUS_BYTES<2*bank_ml[load_bank]) load_pos<=load_pos+BUS_BYTES;
                            else begin load_pos<=0;phase<=SW;end
                        end
                        SW: begin
                            scale_bytes<=scale_bytes+beat_count;
                            for(integer j=0;j<BUS_BYTES;j=j+1)
                                if(in_keep[j] && load_pos+j<2*bank_nl[load_bank])
                                    sw[load_bank][(load_pos+j)/2][((load_pos+j)%2)*8 +:8]<=in_data[j*8 +:8];
                            if(load_pos+BUS_BYTES<2*bank_nl[load_bank]) load_pos<=load_pos+BUS_BYTES;
                            else finish_packet();
                        end
                    endcase
                end
                // Consumer: PE keeps one group's integer sum across K tiles.
                case(state)
                    INIT_Y: if(slot==RC-1) begin slot<=0;state<=WAIT_TILE;end else slot<=slot+1;
                    WAIT_TILE: if(bank_state[consumer_bank]==READY && bank_m[consumer_bank]==mt &&
                                  bank_n[consumer_bank]==nt && bank_k[consumer_bank]==ck) begin
                        bank_state[consumer_bank]<=COMPUTING;clen<=bank_kl[consumer_bank];run_k<=0;
                        state<=(ck%GROUP_SIZE==0)?CLEAR_PE:PRIME;
                    end
                    CLEAR_PE: state<=PRIME;
                    PRIME: state<=RUN;
                    RUN: if(run_k+1<clen) run_k<=run_k+1;
                        else if(ck+clen==k || (ck+clen)%GROUP_SIZE==0) begin slot<=0;state<=SAVE_G;end
                        else begin
                            bank_state[consumer_bank]<=FREE;consumer_bank<=DOUBLE_BUFFER?~consumer_bank:1'b0;
                            ck<=ck+clen;state<=WAIT_TILE;
                        end
                    SAVE_G: if(slot==RC-1) begin slot<=0;state<=SCALE_REQ;end else slot<=slot+1;
                    SCALE_REQ: begin
                        factor<=slot_valid?(sx[consumer_bank][slot/COLS]*sw[consumer_bank][slot%COLS]):32'd0;
                        state<=SCALE_MUL;
                    end
                    SCALE_MUL: begin scaled<=full_scaled[63:0];state<=SCALE_ADD;end
                    SCALE_ADD: if(slot==RC-1) begin
                        bank_state[consumer_bank]<=FREE;consumer_bank<=DOUBLE_BUFFER?~consumer_bank:1'b0;
                        slot<=0;
                        if(ck+clen==k) state<=OUT_REQ;
                        else begin ck<=ck+clen;state<=WAIT_TILE;end
                    end else begin slot<=slot+1;state<=SCALE_REQ;end
                    OUT_REQ: if(slot_valid) state<=OUT_LATCH;else next_output();
                    OUT_LATCH: begin out_data<=round_output(y_q);state<=OUT_SEND;end
                    OUT_SEND: if(out_ready) next_output();
                    FINISH: begin state<=IDLE;done<=1;end
                    default: begin state<=IDLE;error<=1;end
                endcase
            end
        end
    end
endmodule
