// Two finite 1R1W bank groups. Source memory has one synchronous read port.
// LOAD_GAP inserts independent loader idle cycles for reproducible stress tests.
module b_pingpong #(
    parameter integer COLS=4, TILE_K=8, MAX_N=16, MAX_K=32, LOAD_GAP=0,
    parameter integer KW=(TILE_K<=1)?1:$clog2(TILE_K),
    parameter integer CW=(COLS<=1)?1:$clog2(COLS),
    parameter integer BAW=(MAX_K*MAX_N<=1)?1:$clog2(MAX_K*MAX_N)
)(
    input logic clk,rst,enable,init,
    input logic [15:0] task_n,task_k,tile_n,consume_kt,
    output logic mem_rd_en,
    output logic [BAW-1:0] mem_rd_addr,
    input logic signed [7:0] mem_q,
    input logic take,release_tile,rd_en,
    input logic [KW-1:0] rd_k,
    output logic ready,
    output wire signed [7:0] data [0:COLS-1],
    output logic [15:0] read_lane,read_k_abs
);
    localparam logic [1:0] EMPTY=0,FILLING=1,READY=2,COMPUTING=3;
    localparam integer GW=(LOAD_GAP<1)?1:$clog2(LOAD_GAP+1);
    logic [1:0] bank_state [0:1];
    logic [15:0] bank_kt [0:1];
    logic producer_bank,consumer_bank,fill_bank,loading;
    logic [15:0] n_total,k_total,n_base,next_kt,fill_kt,fill_len,load_lane,load_k;
    logic [15:0] next_lane,next_k,request_kt,request_lane,request_k;
    logic [GW-1:0] gap_count;
    logic load_step,claim,last_write,tile_wr_en,request_valid,write_valid;
    wire signed [7:0] bank_data [0:1][0:COLS-1];
    logic signed [7:0] tile_wr_data;
    assign load_step=enable && gap_count==0 && !init;
    assign claim=!loading && next_kt<k_total && bank_state[producer_bank]==EMPTY;
    assign last_write=load_lane==COLS-1 && load_k==fill_len-1;
    assign tile_wr_en=load_step && loading;
    assign write_valid=n_base+load_lane<n_total;
    assign tile_wr_data=write_valid?mem_q:8'sd0;
    assign next_lane=(load_k==fill_len-1)?load_lane+1:load_lane;
    assign next_k=(load_k==fill_len-1)?0:load_k+1;
    assign request_kt=loading?fill_kt:next_kt;
    assign request_lane=loading?next_lane:0;
    assign request_k=loading?next_k:0;
    assign request_valid=n_base+request_lane<n_total && request_kt+request_k<k_total;
    assign mem_rd_en=load_step && request_valid &&
        ((loading && !last_write) || (!loading && claim));
    assign mem_rd_addr=(request_kt+request_k)*MAX_N+n_base+request_lane;
    assign read_lane=request_lane;
    assign read_k_abs=request_kt+request_k;
    assign ready=bank_state[consumer_bank]==READY && bank_kt[consumer_bank]==consume_kt;
    for(genvar bank=0;bank<2;bank=bank+1) begin: group
        tile_buffer #(.LANES(COLS),.TILE_K(TILE_K)) buffer (
            .clk(clk),.wr_en(tile_wr_en && fill_bank==bank),
            .wr_lane(load_lane[CW-1:0]),.wr_k(load_k[KW-1:0]),.wr_data(tile_wr_data),
            .rd_en(enable && rd_en && consumer_bank==bank && bank_state[bank]==COMPUTING && bank_kt[bank]==consume_kt),
            .rd_k(rd_k),.data(bank_data[bank]));
    end
    for(genvar c=0;c<COLS;c=c+1) begin: mux
        assign data[c]=bank_data[consumer_bank][c];
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            bank_state[0]<=EMPTY;bank_state[1]<=EMPTY;
            bank_kt[0]<=0;bank_kt[1]<=0;
            producer_bank<=0;consumer_bank<=0;fill_bank<=0;loading<=0;
            n_total<=0;k_total<=0;n_base<=0;next_kt<=0;fill_kt<=0;fill_len<=0;
            load_lane<=0;load_k<=0;gap_count<=0;
        end else if(enable) begin
            if(init) begin
                bank_state[0]<=EMPTY;bank_state[1]<=EMPTY;
                bank_kt[0]<=0;bank_kt[1]<=0;
                producer_bank<=0;consumer_bank<=0;fill_bank<=0;loading<=0;
                n_total<=task_n;k_total<=task_k;n_base<=tile_n;
                next_kt<=0;fill_kt<=0;fill_len<=0;load_lane<=0;load_k<=0;gap_count<=0;
            end else begin
                if(gap_count!=0) gap_count<=gap_count-1;
                if(take && ready) bank_state[consumer_bank]<=COMPUTING;
                if(release_tile && bank_state[consumer_bank]==COMPUTING) begin
                    bank_state[consumer_bank]<=EMPTY;
                    consumer_bank<=!consumer_bank;
                end
                if(load_step) begin
                    if(claim) begin
                        // This edge issues first source read; next write uses q.
                        loading<=1;fill_bank<=producer_bank;fill_kt<=next_kt;
                        fill_len<=((k_total-next_kt)<TILE_K)?k_total-next_kt:TILE_K;
                        load_lane<=0;load_k<=0;
                        bank_state[producer_bank]<=FILLING;bank_kt[producer_bank]<=next_kt;
                        producer_bank<=!producer_bank;next_kt<=next_kt+TILE_K;
                        gap_count<=LOAD_GAP;
                    end else if(loading) begin
                        gap_count<=LOAD_GAP;
                        if(last_write) begin
                            bank_state[fill_bank]<=READY;loading<=0;
                        end else begin load_lane<=next_lane;load_k<=next_k;end
                    end
                end
            end
        end
    end
endmodule
