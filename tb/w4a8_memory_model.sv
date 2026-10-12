// Simulation-only deterministic external byte source. No real DDR timing claim.
module w4a8_memory_model #(
    parameter integer GROUP_SIZE=32,MAX_DATA=8192,
    parameter integer FIRST_DELAY=5,BURST_BYTES=8,BURST_GAP=4,REQUEST_PERIOD=5,
    parameter logic [31:0] RANDOM_SEED=32'h20261012
)(
    input logic clk,rst,task_start,
    input integer mode,m,n,k,ng,
    input logic req_valid,
    output logic req_ready,
    input logic [15:0] req_m,req_n,req_k,req_ml,req_nl,req_kl,req_group,
    output logic in_valid,
    input logic in_ready,
    output logic [7:0] in_data
);
    integer a[0:MAX_DATA-1],packed_w[0:MAX_DATA-1],sx[0:MAX_DATA-1],sw[0:MAX_DATA-1];
    integer rm,rn,rk,rml,rnl,rkl,rg,wspan,wb,ab,sxb,swb,length,position,cooldown;
    integer ticks=0,requests=0,accepted=0;
    bit active=0;
    logic [31:0] rng=RANDOM_SEED;
    assign req_ready=!rst && !active && (mode!=2 || ticks%REQUEST_PERIOD!=0);
    function automatic [7:0] byte_at(input integer index);
        integer p,lane,pos,address,value;
        begin
            if(index<wb) begin
                lane=index/wspan;pos=index%wspan;
                address=(rn+lane)*((k+1)/2)+rk/2+pos;
                if(rn+lane>=n || rk/2+pos>=(k+1)/2) $fatal(1,"MEMORY_WEIGHT_OOB");
                byte_at=packed_w[address];
            end else if(index<wb+ab) begin
                p=index-wb;lane=p/rkl;pos=p%rkl;
                address=(rm+lane)*k+rk+pos;
                if(rm+lane>=m || rk+pos>=k) $fatal(1,"MEMORY_ACTIVATION_OOB");
                byte_at=a[address];
            end else if(index<wb+ab+sxb) begin
                p=index-wb-ab;lane=p/2;pos=p%2;
                address=(rm+lane)*ng+rg;
                if(rm+lane>=m || rg>=ng) $fatal(1,"MEMORY_SX_OOB");
                value=sx[address];byte_at=pos?(value>>8):(value&255);
            end else begin
                p=index-wb-ab-sxb;lane=p/2;pos=p%2;
                address=rg*n+rn+lane;
                if(rg>=ng || rn+lane>=n) $fatal(1,"MEMORY_SW_OOB");
                value=sw[address];byte_at=pos?(value>>8):(value&255);
            end
        end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            active<=0;in_valid<=0;in_data<=0;position<=0;cooldown<=0;ticks<=0;
            requests<=0;accepted<=0;rng<=RANDOM_SEED;
        end else begin
            ticks<=ticks+1;
            if(task_start) begin requests<=0;accepted<=0;rng<=RANDOM_SEED;end
            if(req_valid && req_ready) begin
                if(req_ml==0 || req_nl==0 || req_kl==0 || req_m+req_ml>m || req_n+req_nl>n ||
                   req_k+req_kl>k || req_k/GROUP_SIZE!=req_group ||
                   (req_k+req_kl-1)/GROUP_SIZE!=req_group) $fatal(1,"MEMORY_BAD_REQUEST");
                rm=req_m;rn=req_n;rk=req_k;rml=req_ml;rnl=req_nl;rkl=req_kl;rg=req_group;
                wspan=(rk%2+rkl+1)/2;wb=rnl*wspan;ab=rml*rkl;sxb=2*rml;swb=2*rnl;
                length=wb+ab+sxb+swb;position<=0;active<=1;requests<=requests+1;
                cooldown<=(mode==0)?0:FIRST_DELAY;
            end
            if(in_valid && in_ready) begin
                in_valid<=0;accepted<=accepted+1;
                if(position+1==length) begin active<=0;position<=0;end
                else begin
                    position<=position+1;
                    if(mode==1 && (position+1)%BURST_BYTES==0) cooldown<=BURST_GAP;
                end
            end
        end
    end
    // A held valid byte is never changed. Inputs are driven away from sample edge.
    always @(negedge clk) begin
        if(!rst && active) begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            if(!in_valid) begin
                if(cooldown>0) cooldown=cooldown-1;
                else if(mode!=2 || rng[1:0]!=0) begin
                    in_data=byte_at(position);in_valid=1;
                end
            end
        end
    end
endmodule
