`timescale 1ns/1ps
// Three preserved W4A8 cores and finite TB packet sources; the bridge is RTL.
module tb_ffn_base #(parameter integer GROUP_SIZE=32);
    localparam integer FIRST_GROUP=GROUP_SIZE==32?12:32;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,sgate=0,sup=0,sdown=0,bcfg=0;
    logic [15:0] cm=0,ck=0,ch=0,cn=0;
    integer m=0,k=0,h=0,n=0,ng1=0,ng2=0,mode=0,ticks=0;
    wire rg,ru,rd,bg,bu,bd,dg,du,dd,eg,eu,ed,vg,vu,vd,lg,lu,ld;
    wire [15:0] gr,gc,ur,uc,dr,dc;
    wire signed [31:0] gy,uy,dy;
    wire [31:0] cg,cu,cd,wbg,wbu,wbd,abg,abu,abd,sbg,sbu,sbd,ibg,ibu,ibd;
    wire bridge_ready,collect_ready,qv,ql,qtlast,qs,qgs,qclip,qbusy,qdone,nsat;
    wire [1:0] qerror;
    wire signed [7:0] qdata;
    wire [15:0] qr,qg,qi,qscale;
    wire [31:0] qabsmax;
    logic force_quant=0,force_down=0;
    wire gate_ready=collect_ready && (mode==0 || ticks%9>=2);
    wire up_ready=collect_ready && (mode==0 || ticks%7>=2);
    wire down_ready=!force_down && (mode==0 || ticks%11>=3);
    wire quant_ready=!force_quant && (mode==0 || ticks%13>=5);
    // Pause output producers by suppressing their valid on the bridge port too.
    wire b_input_valid=(vg && gate_ready)||(vu && up_ready);
    chain_layer #(.GROUP_SIZE(FIRST_GROUP)) gate_layer(
        .clk(clk),.rst(rst),.start(sgate),.cfg_m(cm),.cfg_n(ch),.cfg_k(ck),.mode(mode),.m(m),.n(h),.k(k),.ng(ng1),
        .out_ready(gate_ready),.start_ready(rg),.busy(bg),.done(dg),.error(eg),.out_valid(vg),.out_last(lg),
        .out_m(gr),.out_n(gc),.out_data(gy),.total_cycles(cg),.weight_bytes(wbg),.activation_bytes(abg),.scale_bytes(sbg),.input_beats(ibg));
    chain_layer #(.GROUP_SIZE(FIRST_GROUP)) up_layer(
        .clk(clk),.rst(rst),.start(sup),.cfg_m(cm),.cfg_n(ch),.cfg_k(ck),.mode(mode),.m(m),.n(h),.k(k),.ng(ng1),
        .out_ready(up_ready),.start_ready(ru),.busy(bu),.done(du),.error(eu),.out_valid(vu),.out_last(lu),
        .out_m(ur),.out_n(uc),.out_data(uy),.total_cycles(cu),.weight_bytes(wbu),.activation_bytes(abu),.scale_bytes(sbu),.input_beats(ibu));
    chain_layer #(.GROUP_SIZE(GROUP_SIZE)) down_layer(
        .clk(clk),.rst(rst),.start(sdown),.cfg_m(cm),.cfg_n(cn),.cfg_k(ch),.mode(mode),.m(m),.n(n),.k(h),.ng(ng2),
        .out_ready(down_ready),.start_ready(rd),.busy(bd),.done(dd),.error(ed),.out_valid(vd),.out_last(ld),
        .out_m(dr),.out_n(dc),.out_data(dy),.total_cycles(cd),.weight_bytes(wbd),.activation_bytes(abd),.scale_bytes(sbd),.input_beats(ibd));
    ffn_bridge #(.GROUP_SIZE(GROUP_SIZE)) bridge(
        .clk(clk),.rst(rst),.cfg_valid(bcfg),.cfg_ready(bridge_ready),.cfg_m(cm),.cfg_h(ch),
        .in_valid(b_input_valid),.in_ready(collect_ready),.in_branch(vu && up_ready),
        .in_row(vu && up_ready?ur:gr),.in_col(vu && up_ready?uc:gc),.in_data(vu && up_ready?uy:gy),
        .out_valid(qv),.out_ready(quant_ready),.out_data(qdata),.out_row(qr),.out_group(qg),.out_index(qi),.out_scale(qscale),
        .out_last(ql),.out_task_last(qtlast),.out_saturated(qs),.group_saturated(qgs),.scale_clipped(qclip),
        .group_absmax(qabsmax),.nonlinear_saturated(nsat),.busy(qbusy),.done(qdone),.error_code(qerror));
    integer gate[0:511],up[0:511],pg[0:4095],pu[0:4095],gsilu[0:511],prod[0:511],esat[0:511];
    integer qgold[0:511],scales[0:511],clips[0:511],sats[0:511],ygold[0:511],pd[0:4095];
    logic [31:0] absmax[0:511];
    bit seen_gate[0:511],seen_up[0:511],seen_prod[0:511],seen_q[0:511],seen_down[0:511],seen_s[0:511];
    integer countg=0,countu=0,countp=0,countq=0,countd=0,counts=0,checks=0,tasks=0,aborts=0;
    integer totalg=0,totalu=0,totalp=0,totalq=0,totald=0,psum_checks=0,scaled_checks=0,reordered=0,held_cycles=0;
    integer fd,csv,scan,ncases,cid,job,begin_tick,up_tick,bridge_tick,down_tick;
    integer ep_sats=0,clip_count=0,q_sats=0;
    bit checking=0,hg=0,hu=0,hd=0,hq=0;
    logic [64:0] oldg,oldu,oldd;
    logic [108:0] oldq;
    wire [108:0] qpayload={qr,qg,qi,qscale,qdata,ql,qtlast,qs,qgs,qclip,qabsmax};
    task automatic require(input bit ok,input string msg);
        checks++;if(!ok)$fatal(1,"FFN_CHECK_FAILED case=%0d tick=%0d: %s",cid,ticks,msg);
    endtask
    always @(posedge clk)begin
        ticks++;
        if(rst)begin hg=0;hu=0;hd=0;hq=0;end
        else begin
            if(hg)require(vg && {gr,gc,lg,gy}===oldg,"gate holds");
            if(hu)require(vu && {ur,uc,lu,uy}===oldu,"up holds");
            if(hd)require(vd && {dr,dc,ld,dy}===oldd,"down holds");
            if(hq)begin require(qv && qpayload===oldq,"bridge output holds");held_cycles++;end
            hg=vg && !gate_ready;hu=vu && !up_ready;hd=vd && !down_ready;hq=qv && !quant_ready;
            oldg={gr,gc,lg,gy};oldu={ur,uc,lu,uy};oldd={dr,dc,ld,dy};oldq=qpayload;
            if(checking)begin
                require(!eg && !eu && !ed && qerror==0,"no stage errors");
                require(!(vg && gate_ready && vu && up_ready),"single bridge write port");
                if(vg && gate_ready)begin
                    integer idx;idx=gr*h+gc;
                    require(gr<m && gc<h && !seen_gate[idx] && gy===gate[idx],"gate coordinate/value exact");
                    require(lg==(gr==m-1 && gc==h-1),"gate last");
                    if(idx!=countg)reordered++;
                    seen_gate[idx]=1;countg++;totalg++;
                end
                if(vu && up_ready)begin
                    integer idx;idx=ur*h+uc;
                    require(ur<m && uc<h && !seen_up[idx] && uy===up[idx],"up coordinate/value exact");
                    require(lu==(ur==m-1 && uc==h-1),"up last");seen_up[idx]=1;countu++;totalu++;
                end
                if(bridge.e_valid && bridge.q_in_ready && bridge.state==bridge.PAIR_WAIT)begin
                    integer idx;idx=bridge.e_row*h+bridge.e_col;
                    require(seen_gate[idx] && seen_up[idx] && !seen_prod[idx],"paired initialized coordinates once");
                    require(bridge.e_silu===gsilu[idx] && bridge.e_product===prod[idx] && bridge.e_sat==esat[idx],"SiLU/product/saturation exact");
                    seen_prod[idx]=1;countp++;totalp++;ep_sats+=bridge.e_sat;
                end
                if(qv && quant_ready)begin
                    integer idx,si,len;idx=qr*h+qg*GROUP_SIZE+qi;si=qr*ng2+qg;
                    len=(h-qg*GROUP_SIZE)<GROUP_SIZE?(h-qg*GROUP_SIZE):GROUP_SIZE;
                    require(qr<m && qg<ng2 && qi<len && idx==countq && seen_prod[idx] && !seen_q[idx],"row/group reordered stream");
                    require($signed(qdata)==qgold[idx] && qscale==scales[si] && qclip==clips[si] && qabsmax==absmax[si] && qs==sats[idx],"dynamic qx/sx/status exact");
                    require(ql==(qi==len-1) && qtlast==(idx==m*h-1),"group and task last distinct");
                    down_layer.memory.a[idx]=$signed(qdata);seen_q[idx]=1;countq++;totalq++;q_sats+=qs;
                    if(qi==0)begin require(!seen_s[si],"sx once");seen_s[si]=1;counts++;clip_count+=qclip;down_layer.memory.sx[si]=qscale;end
                end
                if(vd && down_ready)begin
                    integer idx;idx=dr*n+dc;
                    require(dr<m && dc<n && !seen_down[idx] && dy===ygold[idx],"down output exact");
                    require(ld==(dr==m-1 && dc==n-1),"down last");seen_down[idx]=1;countd++;totald++;
                end
                if(gate_layer.core.psum_write && gate_layer.core.slot_valid)begin
                    integer r,c,i;r=gate_layer.core.mt+gate_layer.core.slot/4;c=gate_layer.core.nt+gate_layer.core.slot%4;
                    i=(r*ng1+gate_layer.core.ck/FIRST_GROUP)*h+c;
                    require(gate_layer.core.acc[gate_layer.core.slot]===pg[i],"gate group psum");psum_checks++;
                end
                if(up_layer.core.psum_write && up_layer.core.slot_valid)begin
                    integer r,c,i;r=up_layer.core.mt+up_layer.core.slot/4;c=up_layer.core.nt+up_layer.core.slot%4;
                    i=(r*ng1+up_layer.core.ck/FIRST_GROUP)*h+c;
                    require(up_layer.core.acc[up_layer.core.slot]===pu[i],"up group psum");psum_checks++;
                end
                if(down_layer.core.psum_write && down_layer.core.slot_valid)begin
                    integer r,c,i;r=down_layer.core.mt+down_layer.core.slot/4;c=down_layer.core.nt+down_layer.core.slot%4;
                    i=(r*ng2+down_layer.core.ck/GROUP_SIZE)*n+c;
                    require(down_layer.core.acc[down_layer.core.slot]===pd[i],"down group psum");psum_checks++;
                end
                if(gate_layer.core.p_retire)begin
                    integer r,c,g,i;r=gate_layer.core.psum_m[gate_layer.core.psum_cons]+gate_layer.core.tag1/4;
                    c=gate_layer.core.psum_n[gate_layer.core.psum_cons]+gate_layer.core.tag1%4;g=gate_layer.core.psum_group[gate_layer.core.psum_cons];i=(r*ng1+g)*h+c;
                    if(r<m && c<h)begin require(gate_layer.core.scaled==$signed(pg[i])*$signed({1'b0,gate_layer.memory.sx[r*ng1+g][15:0]})*$signed({1'b0,gate_layer.memory.sw[g*h+c][15:0]}),"gate scale products");scaled_checks++;end
                end
                if(up_layer.core.p_retire)begin
                    integer r,c,g,i;r=up_layer.core.psum_m[up_layer.core.psum_cons]+up_layer.core.tag1/4;
                    c=up_layer.core.psum_n[up_layer.core.psum_cons]+up_layer.core.tag1%4;g=up_layer.core.psum_group[up_layer.core.psum_cons];i=(r*ng1+g)*h+c;
                    if(r<m && c<h)begin require(up_layer.core.scaled==$signed(pu[i])*$signed({1'b0,up_layer.memory.sx[r*ng1+g][15:0]})*$signed({1'b0,up_layer.memory.sw[g*h+c][15:0]}),"up scale products");scaled_checks++;end
                end
                if(down_layer.core.p_retire)begin
                    integer r,c,g,i;r=down_layer.core.psum_m[down_layer.core.psum_cons]+down_layer.core.tag1/4;
                    c=down_layer.core.psum_n[down_layer.core.psum_cons]+down_layer.core.tag1%4;g=down_layer.core.psum_group[down_layer.core.psum_cons];i=(r*ng2+g)*n+c;
                    if(r<m && c<n)begin require(down_layer.core.scaled==$signed(pd[i])*$signed({1'b0,down_layer.memory.sx[r*ng2+g][15:0]})*$signed({1'b0,down_layer.memory.sw[g*n+c][15:0]}),"down independent scales");scaled_checks++;end
                end
            end
        end
    end
    task automatic reset_all;
        @(negedge clk);rst=1;sgate=0;sup=0;sdown=0;bcfg=0;checking=0;force_quant=0;force_down=0;
        @(posedge clk);#1;require(!bg && !bu && !bd && !qbusy && !vg && !vu && !vd && !qv,"reset cancels all stages");
        @(negedge clk);rst=0;repeat(3)@(negedge clk);
    endtask
    task automatic launch(input integer stage);
        @(negedge clk);
        case(stage)
            0:begin require(rg,"gate ready");sgate=1;end
            1:begin require(ru,"up ready");sup=1;end
            2:begin require(rd,"down ready");sdown=1;end
        endcase
        @(posedge clk);#1;@(negedge clk);sgate=0;sup=0;sdown=0;
    endtask
    task automatic run_job(input integer md,phase);
        integer timeout;
        mode=md;countg=0;countu=0;countp=0;countq=0;countd=0;counts=0;ep_sats=0;clip_count=0;q_sats=0;
        for(integer i=0;i<512;i++)begin seen_gate[i]=0;seen_up[i]=0;seen_prod[i]=0;seen_q[i]=0;seen_down[i]=0;seen_s[i]=0;end
        force_quant=phase==6;force_down=phase==8;checking=1;begin_tick=ticks;
        @(negedge clk);require(bridge_ready,"bridge descriptor ready");bcfg=1;
        @(posedge clk);#1;require(qbusy && qerror==0,"bridge descriptor accepted");@(negedge clk);bcfg=0;
        launch(0);
        if(phase==1)begin wait(gate_layer.core.state==gate_layer.core.RUN);reset_all();aborts++;return;end
        timeout=0;while(!dg)begin @(negedge clk);timeout++;require(timeout<100000,"gate watchdog");end
        require(countg==m*h && countu==0,"gate collected before up");up_tick=ticks;launch(1);
        if(phase==2)begin wait(up_layer.core.state==up_layer.core.RUN);reset_all();aborts++;return;end
        timeout=0;while(!du)begin @(negedge clk);timeout++;require(timeout<100000,"up watchdog");end
        require(countu==m*h,"both tensors collected");bridge_tick=ticks;
        if(phase==3)begin wait(bridge.nonlinear.state==bridge.nonlinear.MUL_UP);reset_all();aborts++;return;end
        if(phase==4)begin wait(bridge.quantizer.state==bridge.quantizer.COLLECT);repeat(3)@(negedge clk);reset_all();aborts++;return;end
        if(phase==5)begin wait(bridge.quantizer.state==bridge.quantizer.SCALE_DIV);repeat(9)@(negedge clk);reset_all();aborts++;return;end
        if(phase==6)begin wait(qv);repeat(14)@(negedge clk);reset_all();aborts++;return;end
        timeout=0;while(!qdone)begin @(negedge clk);timeout++;require(timeout<100000,"bridge watchdog");end
        require(countp==m*h && countq==m*h && counts==m*ng2 && nsat==(ep_sats!=0),"complete initialized down tensor and aggregate status");
        down_tick=ticks;launch(2);
        if(phase==7)begin wait(down_layer.core.state==down_layer.core.RUN);reset_all();aborts++;return;end
        if(phase==8)begin wait(vd);repeat(14)@(negedge clk);reset_all();aborts++;return;end
        timeout=0;while(!dd)begin @(negedge clk);timeout++;require(timeout<100000,"down watchdog");end
        require(countd==m*n,"FFN complete");checking=0;tasks++;
        $fwrite(csv,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",GROUP_SIZE,cid,mode,m,k,h,n,ticks-begin_tick,cg,cu,down_tick-bridge_tick,cd,countg,countu,countp,countq,countd,counts,ep_sats,clip_count,q_sats,wbg+wbu+wbd);
    endtask
    initial begin
        if($test$plusargs("FORCE_TIMEOUT"))begin #100000;$fatal(1,"FFN_TIMEOUT");end
        #30000000;$fatal(1,"FFN_TIMEOUT");
    end
    initial begin
        csv=$fopen("results.csv","w");$fwrite(csv,"group_size,case,mode,m,k,h,n,total_cycles,gate_cycles,up_cycles,bridge_cycles,down_cycles,gate,up,product,qx,y,scales,nonlinear_saturated,scale_clipped,quant_saturated,weight_bytes\n");
        reset_all();
        // Descriptor rejection must not accept producer data.
        cm=0;ch=1;@(negedge clk);bcfg=1;@(posedge clk);#1;require(qdone && qerror==1 && !qbusy && !collect_ready,"invalid descriptor rejected");
        @(negedge clk);bcfg=0;reset_all();
        fd=$fopen("vectors.txt","r");scan=$fscanf(fd,"%d",ncases);require(scan==1,"FFN case count");
        for(job=0;job<ncases;job++)begin
            scan=$fscanf(fd,"%d %d %d %d %d %d %d",cid,m,k,h,n,ng1,ng2);
            require(scan==7 && m*h<=512 && h<=64 && m<=64 && n<=64,"bounded FFN dimensions");cm=m;ck=k;ch=h;cn=n;
            for(integer i=0;i<m*k;i++)begin scan=$fscanf(fd,"%d",gate_layer.memory.a[i]);up_layer.memory.a[i]=gate_layer.memory.a[i];end
            for(integer i=0;i<h*((k+1)/2);i++)scan=$fscanf(fd,"%d",gate_layer.memory.packed_w[i]);
            for(integer i=0;i<h*((k+1)/2);i++)scan=$fscanf(fd,"%d",up_layer.memory.packed_w[i]);
            for(integer i=0;i<m*ng1;i++)begin scan=$fscanf(fd,"%d",gate_layer.memory.sx[i]);up_layer.memory.sx[i]=gate_layer.memory.sx[i];end
            for(integer i=0;i<ng1*h;i++)scan=$fscanf(fd,"%d",gate_layer.memory.sw[i]);
            for(integer i=0;i<ng1*h;i++)scan=$fscanf(fd,"%d",up_layer.memory.sw[i]);
            for(integer i=0;i<m*h;i++)scan=$fscanf(fd,"%d",gate[i]);
            for(integer i=0;i<m*h;i++)scan=$fscanf(fd,"%d",up[i]);
            for(integer i=0;i<m*ng1*h;i++)scan=$fscanf(fd,"%d",pg[i]);
            for(integer i=0;i<m*ng1*h;i++)scan=$fscanf(fd,"%d",pu[i]);
            for(integer i=0;i<m*h;i++)scan=$fscanf(fd,"%d",gsilu[i]);
            for(integer i=0;i<m*h;i++)scan=$fscanf(fd,"%d",prod[i]);
            for(integer i=0;i<m*h;i++)scan=$fscanf(fd,"%d",esat[i]);
            for(integer i=0;i<m*h;i++)scan=$fscanf(fd,"%d",qgold[i]);
            for(integer i=0;i<m*ng2;i++)scan=$fscanf(fd,"%d",scales[i]);
            for(integer i=0;i<m*ng2;i++)scan=$fscanf(fd,"%d",clips[i]);
            for(integer i=0;i<m*h;i++)scan=$fscanf(fd,"%d",sats[i]);
            for(integer i=0;i<m*ng2;i++)scan=$fscanf(fd,"%d",absmax[i]);
            for(integer i=0;i<n*((h+1)/2);i++)scan=$fscanf(fd,"%d",down_layer.memory.packed_w[i]);
            for(integer i=0;i<ng2*n;i++)scan=$fscanf(fd,"%d",down_layer.memory.sw[i]);
            for(integer i=0;i<m*n;i++)scan=$fscanf(fd,"%d",ygold[i]);
            for(integer i=0;i<m*ng2*n;i++)scan=$fscanf(fd,"%d",pd[i]);
            require(scan==1 && ng1==(k+FIRST_GROUP-1)/FIRST_GROUP && ng2==(h+GROUP_SIZE-1)/GROUP_SIZE,"complete vectors and group namespaces");
            if($test$plusargs("CORRUPT_EXPECTED") && job==0)ygold[0]++;
            run_job(0,0);run_job(1,0);
            if(job==1)for(integer phase=1;phase<=8;phase++)begin run_job(1,phase);run_job(1,0);end
        end
        require(tasks==18 && aborts==8 && reordered>0 && held_cycles>0 && psum_checks>0 && scaled_checks>0,"FFN coverage");
        $fclose(fd);$fclose(csv);
        $display("FFN_TESTS_PASS group=%0d tasks=%0d aborts=%0d gate=%0d up=%0d product=%0d qx=%0d y=%0d psums=%0d scaled=%0d held=%0d checks=%0d",GROUP_SIZE,tasks,aborts,totalg,totalu,totalp,totalq,totald,psum_checks,scaled_checks,held_cycles,checks);
        $finish;
    end
endmodule
module tb_w4a8_ffn;tb_ffn_base #(.GROUP_SIZE(32)) test();endmodule
module tb_w4a8_ffn12;tb_ffn_base #(.GROUP_SIZE(12)) test();endmodule
