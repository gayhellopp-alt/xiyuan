// Independent TB-only byte-addressed AXI slave; narrow transfers do not touch padding.
module storage_axi_memory # (parameter integer SIZE=65536)(
    input logic clk,rst,random_stalls,hold_b,
    input integer fail_write,fail_read,
    input logic bad_bid,bad_rid,bad_rlast,
    input logic arvalid,output logic arready,input logic [31:0] araddr,
    input logic [3:0] arid,input logic [7:0] arlen,input logic [2:0] arsize,input logic [1:0] arburst,
    output logic rvalid,input logic rready,output logic [63:0] rdata,
    output logic [3:0] rid,output logic [1:0] rresp,output logic rlast,
    input logic awvalid,output logic awready,input logic [31:0] awaddr,
    input logic [3:0] awid,input logic [7:0] awlen,input logic [2:0] awsize,input logic [1:0] awburst,
    input logic wvalid,output logic wready,input logic [63:0] wdata,input logic [7:0] wstrb,input logic wlast,
    output logic bvalid,input logic bready,output logic [3:0] bid,output logic [1:0] bresp,
    output integer reads,writes,responses,aw_first,w_first
);
    logic [7:0] mem[0:SIZE-1];
    bit read_allowed[0:SIZE-1],write_allowed[0:SIZE-1];
    bit rp=0,ap=0,wp=0,bp=0,extra=0;
    integer ra,wa,rd_delay,bd_delay;
    logic [63:0] wd;logic [7:0] ws;
    bit re,be,ri,bi,rl;
    logic [31:0] rng=32'h975abcde;
    assign arready=!rst && !rp && !rvalid && (!random_stalls || rng[2:0]>1);
    assign awready=!rst && !ap && !bp && !bvalid && (!random_stalls || rng[6:4]>2);
    assign wready=!rst && !wp && !bp && !bvalid && (!random_stalls || rng[10:8]>3);
    always @(posedge clk) begin
        if(rst) begin
            rp=0;ap=0;wp=0;bp=0;extra=0;rvalid<=0;bvalid<=0;rdata<=0;rid<=0;rresp<=0;rlast<=1;bid<=0;bresp<=0;
            reads=0;writes=0;responses=0;aw_first=0;w_first=0;rng<=32'h975abcde;
        end else begin
            rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            if(rvalid && rready) begin
                rvalid<=0;
                if(extra) begin extra=0;rp=1;rd_delay=2;rl=0;end
            end
            if(bvalid && bready) begin bvalid<=0;responses++;end
            if(rp && !rvalid) begin
                if(rd_delay>0) rd_delay--;
                else begin rp=0;rvalid<=1;rdata<=64'(mem[ra]) << ((ra%8)*8);rid<=ri?1:0;rresp<=re?2:0;rlast<=!rl;extra=rl;end
            end
            if(bp && !bvalid && !hold_b) begin
                if(bd_delay>0) bd_delay--;
                else begin bp=0;bvalid<=1;bid<=bi?1:0;bresp<=be?2:0;end
            end
            if(arvalid && arready) begin
                if(arid!=0 || arlen!=0 || arsize!=0 || arburst!=1 || araddr>=SIZE || !read_allowed[araddr]) $fatal(1,"STORAGE_AXI_BAD_READ");
                ra=araddr;rp=1;rd_delay=random_stalls?integer'(rng[15:12]):1;
                re=reads==fail_read;ri=bad_rid;rl=bad_rlast;reads++;
            end
            if(awvalid && awready) begin
                if(awid!=0 || awlen!=0 || awsize!=0 || awburst!=1 || awaddr>=SIZE || !write_allowed[awaddr]) $fatal(1,"STORAGE_AXI_BAD_AW");
                if(!wp) aw_first++;wa=awaddr;ap=1;
            end
            if(wvalid && wready) begin
                if(!wlast) $fatal(1,"STORAGE_AXI_BAD_WLAST");
                if(!ap) w_first++;wd=wdata;ws=wstrb;wp=1;
            end
            if(ap && wp) begin
                if(ws!=(8'h01 << (wa%8))) $fatal(1,"STORAGE_AXI_BAD_WSTRB");
                mem[wa]=wd[(wa%8)*8 +:8];
                ap=0;wp=0;bp=1;bd_delay=random_stalls?integer'(rng[19:16]):2;
                be=writes==fail_write;bi=bad_bid;writes++;
            end
        end
    end
endmodule
