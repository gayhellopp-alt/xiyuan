`timescale 1ns/1ps
module tb_kv_cache #(parameter integer GROUP_SIZE=4);
    import kv_cache_pkg::*;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,cfg_valid=0,cfg_ready,cmd_valid=0,cmd_ready;
    kv_config_t cfg_desc,saved_cfg;kv_command_t cmd_desc;
    logic append_valid=0,append_ready,append_last=0;logic [7:0] append_data=0;
    logic read_valid,read_ready=1,read_last;logic [7:0] read_data;
    logic completion_valid,completion_ready=0,configured;logic [31:0] completion_id;logic [3:0] completion_status;
    logic [15:0] query_layer=0,query_head=0,query_length;logic query_valid;
    logic arvalid,arready,rvalid,rready,rlast,awvalid,awready,wvalid,wready,wlast,bvalid,bready;
    logic [31:0] araddr,awaddr;logic [3:0] arid,rid,awid,bid;logic [7:0] arlen,awlen,wstrb;
    logic [2:0] arsize,awsize;logic [1:0] arburst,awburst,rresp,bresp;logic [63:0] rdata,wdata;
    logic [31:0] cycles,accepted_bytes,acknowledged_bytes,returned_bytes,read_wait,write_wait;
    logic random_stalls=1,hold_b=0,bad_bid=0,bad_rid=0,bad_rlast=0,force_read_stall=0;
    integer fail_write=-1,fail_read=-1,reads,writes,responses,aw_first,w_first;
    kv_cache #(.GROUP_SIZE(GROUP_SIZE),.MAX_LAYERS(2),.MAX_HEADS(2),.MAX_TOKENS(4),.MAX_DIM(8)) dut(.*);
    storage_axi_memory memory(.*);
    integer oracle_addr[0:287],oracle_data[0:287];
    integer addr_layer[0:65535],addr_head[0:65535],addr_token[0:65535];
    logic [7:0] shadow_mem[0:65535];
    integer shadow_length[0:1][0:1];
    integer queue_addr[0:255],queue_data[0:255];
    integer qsize=0,aw_seen=0,w_seen=0,ar_seen=0,read_seen=0,checks=0,commands=0,next_id=101,current_id=0,report;
    bit checking=0,append_checking=0,held_aw=0,held_ar=0,held_w=0,held_read=0,held_completion=0,held_append=0;
    logic [31:0] old_aw,old_ar;logic [71:0] old_w;logic [8:0] old_read;logic [35:0] old_completion;
    logic [8:0] old_append;integer append_stalls=0,read_stalls=0;
    logic [31:0] rng=32'hbd578acd;
    task automatic require(input bit ok,input string message);
        checks++;if(!ok) $fatal(1,"KV_CHECK_FAILED %s time=%0t",message,$time);
    endtask
    function automatic integer plane_start(input integer p);
        case(p) 0:return 0;1:return 5;2:return 10;default:return 14;endcase
    endfunction
    function automatic integer plane_size(input integer p);
        return p<2?5:4;
    endfunction
    function automatic integer oracle_index(input integer l,h,t,p,b);
        return ((l*2+h)*4+t)*18+plane_start(p)+b;
    endfunction
    task automatic configure_fields;
        cfg_desc='0;cfg_desc.config_id=90;cfg_desc.layers=2;cfg_desc.heads=2;cfg_desc.capacity=4;
        cfg_desc.dimension=5;cfg_desc.group_size=GROUP_SIZE;cfg_desc.format_id=KV_INT8_UQ412_V1;
        cfg_desc.base[0]=4093;cfg_desc.base[1]=10001;cfg_desc.base[2]=16000;cfg_desc.base[3]=20000;
        cfg_desc.token_stride[0]=8;cfg_desc.token_stride[1]=10;cfg_desc.token_stride[2]=6;cfg_desc.token_stride[3]=8;
        cfg_desc.head_stride[0]=40;cfg_desc.head_stride[1]=50;cfg_desc.head_stride[2]=32;cfg_desc.head_stride[3]=40;
        cfg_desc.layer_stride[0]=96;cfg_desc.layer_stride[1]=112;cfg_desc.layer_stride[2]=80;cfg_desc.layer_stride[3]=96;
        cfg_desc.bytes[0]=165;cfg_desc.bytes[1]=197;cfg_desc.bytes[2]=134;cfg_desc.bytes[3]=164;saved_cfg=cfg_desc;
    endtask
    task automatic reset_all;
        @(negedge clk);checking=0;rst=1;cfg_valid=0;cmd_valid=0;append_valid=0;hold_b=0;completion_ready=0;
        fail_write=-1;fail_read=-1;bad_bid=0;bad_rid=0;bad_rlast=0;force_read_stall=0;
        for(integer l=0;l<2;l++) for(integer h=0;h<2;h++) shadow_length[l][h]=0;
        repeat(4) @(negedge clk);rst=0;require(!configured && !query_valid,"reset invalidates metadata");
    endtask
    task automatic finish(input logic [3:0] expected_status);
        integer timeout_count=0;
        while(!completion_valid) begin @(negedge clk);timeout_count++;require(timeout_count<20000,"command watchdog");end
        require(completion_id==current_id && completion_status==expected_status,"completion ID/status");
        require(dut.rd_idle && dut.wr_idle,"completion after all transactions drained");
        $fdisplay(report,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",current_id,completion_status,cycles,accepted_bytes,acknowledged_bytes,returned_bytes,read_wait,write_wait);
        repeat(5) begin @(negedge clk);require(completion_valid && !cmd_ready && !cfg_ready && completion_id==current_id && completion_status==expected_status,"completion hold");end
        completion_ready=1;@(negedge clk);completion_ready=0;commands++;checking=0;append_checking=0;
    endtask
    task automatic configure(input logic [3:0] expected_status);
        @(negedge clk);require(cfg_ready,"config accepted idle");current_id=cfg_desc.config_id;cfg_valid=1;
        @(negedge clk);cfg_valid=0;cfg_desc='0;finish(expected_status);
        require(configured==(expected_status==KV_OK),"configuration validity");
    endtask
    task automatic send_command(input integer op,l,h,t,count,p,offset,length);
        @(negedge clk);require(cmd_ready,"command ready");
        cmd_desc='0;cmd_desc.task_id=next_id;current_id=next_id;next_id++;
        cmd_desc.operation=2'(op);cmd_desc.layer=16'(l);cmd_desc.head=16'(h);cmd_desc.token=16'(t);cmd_desc.count=16'(count);
        cmd_desc.plane=2'(p);cmd_desc.offset=16'(offset);cmd_desc.length=16'(length);
        cmd_valid=1;@(negedge clk);cmd_valid=0;cmd_desc='0;
    endtask
    task automatic query_check(input integer l,h,expected);
        @(negedge clk);query_layer=16'(l);query_head=16'(h);#1;
        require(query_valid && query_length==expected,"committed length per layer/head");
    endtask
    task automatic append_job(input integer l,h,t,count,fault_at,input bit delay_last,input integer stream_fault,input bit id_error);
        integer old_length,old_writes,old_responses,idx,timeout_count;
        bit stop_stream;
        old_length=shadow_length[l][h];old_writes=writes;old_responses=responses;
        aw_seen=0;w_seen=0;ar_seen=0;read_seen=0;qsize=0;
        for(integer tok=t;tok<t+count;tok++) for(integer p=0;p<4;p++) for(integer b=0;b<plane_size(p);b++) begin
            idx=oracle_index(l,h,tok,p,b);queue_addr[qsize]=oracle_addr[idx];queue_data[qsize]=oracle_data[idx];qsize++;
        end
        checking=1;append_checking=1;if(fault_at>=0) fail_write=writes+fault_at;bad_bid=id_error;
        query_layer=16'(l);query_head=16'(h);
        send_command(KV_APPEND,l,h,t,count,0,0,0);
        stop_stream=0;
        for(integer j=0;j<qsize;j++) begin
            @(negedge clk);timeout_count=0;
            if(completion_valid) begin stop_stream=1;break;end
            append_data=8'(queue_data[j]);append_last=j==qsize-1;
            if(stream_fault==1 && j==0) append_last=1;
            if(stream_fault==2 && j==qsize-1) append_last=0;
            append_valid=1;
            while(!append_ready && !completion_valid) begin @(negedge clk);timeout_count++;require(timeout_count<20000,"append ready watchdog");end
            if(completion_valid) begin append_valid=0;stop_stream=1;break;end
            if(delay_last && j==qsize-1) hold_b=1;
            @(negedge clk);append_valid=0;
            if(stream_fault==1) break;
        end
        if(delay_last) begin
            timeout_count=0;while(writes-old_writes<qsize) begin @(negedge clk);timeout_count++;require(timeout_count<1000,"last write submitted");end
            repeat(100) begin @(negedge clk);require(query_length==old_length && !completion_valid,"length and completion fenced by final B");end
            require(responses-old_responses==qsize-1,"all but last B confirmed");
            if(!$test$plusargs("timeout_probe")) hold_b=0;
        end
        if(stream_fault!=0) finish(KV_STREAM_ERROR);
        else if(fault_at>=0 || id_error) finish(KV_WRITE_ERROR);
        else finish(KV_OK);
        require(w_seen==aw_seen && writes-old_writes==w_seen,"no lost or duplicate writes");
        if(fault_at<0 && !id_error && stream_fault==0) begin
            require(w_seen==qsize && acknowledged_bytes==qsize,"all append bytes confirmed");shadow_length[l][h]=t+count;
        end
        query_check(l,h,shadow_length[l][h]);fail_write=-1;bad_bid=0;
    endtask
    task automatic read_job(input integer l,h,t,count,p,offset,length,input integer fault_kind);
        integer idx,old_reads;
        qsize=0;ar_seen=0;read_seen=0;aw_seen=0;w_seen=0;old_reads=reads;
        for(integer tok=t;tok<t+count;tok++) for(integer b=offset;b<offset+length;b++) begin
            idx=oracle_index(l,h,tok,p,b);queue_addr[qsize]=oracle_addr[idx];queue_data[qsize]=oracle_data[idx];qsize++;
        end
        if($test$plusargs("corrupt_expected")) queue_data[0]=queue_data[0]^1;
        if(fault_kind==1) fail_read=reads;
        bad_rid=fault_kind==2;bad_rlast=fault_kind==3;checking=1;
        send_command(KV_READ,l,h,t,count,p,offset,length);
        finish(fault_kind==0?KV_OK:KV_READ_ERROR);
        if(fault_kind==0) require(ar_seen==qsize && read_seen==qsize && reads-old_reads==qsize && returned_bytes==qsize,"read scoreboard drained");
        else require(read_seen==0,"failed read byte never exposed");
        fail_read=-1;bad_rid=0;bad_rlast=0;
    endtask
    task automatic reject_command(input integer op,l,h,t,count,p,offset,length);
        integer old_reads=reads,old_writes=writes;
        checking=0;send_command(op,l,h,t,count,p,offset,length);finish(KV_BAD_COMMAND);
        require(reads==old_reads && writes==old_writes,"rejected command performs no AXI access");
    endtask
    always @(negedge clk) begin
        if(!rst) begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            read_ready=!force_read_stall && (!random_stalls || rng[2:0]>2);
        end
    end
    always @(posedge clk) begin
        if(rst) begin held_aw=0;held_ar=0;held_w=0;held_read=0;held_completion=0;held_append=0;end
        else begin
            if(completion_valid && completion_status!=KV_OK) held_append=0;
            if(held_append) require(append_valid && {append_last,append_data}===old_append,"append source held during backpressure");
            if(held_aw) require(awvalid && awaddr===old_aw,"AW stable");
            if(held_ar) require(arvalid && araddr===old_ar,"AR stable");
            if(held_w) require(wvalid && {wstrb,wdata}===old_w,"W stable");
            if(held_read) require(read_valid && {read_last,read_data}===old_read,"read output stable");
            if(held_completion) require(completion_valid && {completion_id,completion_status}===old_completion,"completion stable");
            held_aw=awvalid && !awready;old_aw=awaddr;held_ar=arvalid && !arready;old_ar=araddr;
            held_w=wvalid && !wready;old_w={wstrb,wdata};held_read=read_valid && !read_ready;old_read={read_last,read_data};
            held_completion=completion_valid && !completion_ready;old_completion={completion_id,completion_status};
            held_append=append_valid && !append_ready && !completion_valid;old_append={append_last,append_data};
            if(append_valid && !append_ready && !completion_valid) append_stalls++;
            if(read_valid && !read_ready) read_stalls++;
            if(checking) begin
                if(append_checking && !completion_valid)
                    require(query_length==shadow_length[query_layer][query_head],"whole append batch remains uncommitted until every B succeeds");
                if(awvalid && awready) begin require(aw_seen<qsize && awaddr==queue_addr[aw_seen],"write address exact sequence");aw_seen++;end
                if(wvalid && wready) begin
                    require(w_seen<qsize && wstrb==(8'h01 << (queue_addr[w_seen]%8)) &&
                        wdata[(queue_addr[w_seen]%8)*8 +:8]==queue_data[w_seen],"write data/strobe exact sequence");
                    shadow_mem[queue_addr[w_seen]]=8'(queue_data[w_seen]);w_seen++;
                end
                if(arvalid && arready) begin
                    require(ar_seen<qsize && araddr==queue_addr[ar_seen],"read address exact sequence");
                    require(addr_token[araddr]<shadow_length[addr_layer[araddr]][addr_head[araddr]],"no read of uncommitted token");ar_seen++;
                end
                if(read_valid && read_ready) begin
                    require(read_seen<qsize && read_data==queue_data[read_seen] && read_last==(read_seen+1==qsize),"read data/last exact");read_seen++;
                end
            end
        end
    end
    initial begin: tests
        integer f,rc,idx,timeout_count,old_reads,old_writes;
        report=$fopen("kv_results.csv","w");require(report!=0,"CSV opened");
        $fdisplay(report,"task_id,status,cycles,accepted_bytes,acknowledged_bytes,returned_bytes,read_wait,write_wait");
        for(integer i=0;i<65536;i++) begin memory.mem[i]=8'hcd;shadow_mem[i]=8'hcd;memory.read_allowed[i]=0;memory.write_allowed[i]=0;end
        f=$fopen("kv_vectors.txt","r");require(f!=0,"oracle opened");
        for(integer l=0;l<2;l++) for(integer h=0;h<2;h++) for(integer t=0;t<4;t++) for(integer p=0;p<4;p++) for(integer b=0;b<plane_size(p);b++) begin
            idx=oracle_index(l,h,t,p,b);rc=$fscanf(f,"%d %d",oracle_addr[idx],oracle_data[idx]);require(rc==2,"oracle parsed");
            memory.read_allowed[oracle_addr[idx]]=1;memory.write_allowed[oracle_addr[idx]]=1;
            addr_layer[oracle_addr[idx]]=l;addr_head[oracle_addr[idx]]=h;addr_token[oracle_addr[idx]]=t;
        end
        $fclose(f);reset_all();
        for(integer bad=0;bad<12;bad++) begin
            configure_fields();
            case(bad)
                0:cfg_desc.group_size=GROUP_SIZE+1;1:cfg_desc.format_id=2;2:cfg_desc.token_stride[0]=4;
                3:cfg_desc.head_stride[1]=1;4:cfg_desc.layer_stride[0]=1;5:cfg_desc.base[0]=32'hfffffffd;
                6:cfg_desc.base[1]=cfg_desc.base[0];7:cfg_desc.base[2]=cfg_desc.base[2]+1;
                8:cfg_desc.bytes[0]=1;9:cfg_desc.dimension=9;10:cfg_desc.layers=3;11:cfg_desc.capacity=5;
            endcase
            configure(KV_BAD_CONFIG);require(reads==0 && writes==0,"invalid config no access");
        end
        configure_fields();configure(KV_OK);require(!cfg_ready,"live config cannot be replaced");
        reject_command(KV_READ,0,0,0,1,0,0,5);
        append_job(0,0,0,1,-1,1,0,0);
        for(integer p=0;p<4;p++) read_job(0,0,0,1,p,0,plane_size(p),0);
        append_job(0,0,1,2,-1,0,0,0);read_job(0,0,0,3,0,1,3,0);
        query_check(0,1,0);query_check(1,0,0);
        append_job(1,1,0,2,-1,0,0,0);read_job(1,1,0,2,3,0,4,0);
        append_job(0,1,0,1,-1,0,0,0);
        // Failure on the final byte must not commit the token, despite all memory writes occurring.
        append_job(0,0,3,1,17,0,0,0);reject_command(KV_READ,0,0,3,1,0,0,5);
        read_job(0,0,0,3,1,0,5,0);append_job(0,0,3,1,-1,0,0,0);query_check(0,0,4);
        reject_command(KV_APPEND,0,0,4,1,0,0,0);reject_command(KV_APPEND,0,0,1,1,0,0,0);
        reject_command(KV_READ,0,0,4,1,0,0,5);reject_command(KV_READ,0,0,0,1,0,4,2);
        reject_command(KV_READ,0,0,0,0,0,0,5);reject_command(KV_READ,2,0,0,1,0,0,5);
        reject_command(KV_READ,0,2,0,1,0,0,5);reject_command(3,0,0,0,1,0,0,5);
        reject_command(KV_READ,0,0,65535,65535,0,0,5);
        append_job(1,0,0,2,35,0,0,0);query_check(1,0,0);
        reject_command(KV_READ,1,0,0,1,0,0,5);reject_command(KV_READ,1,0,1,1,0,0,5);
        append_job(1,0,0,2,3,0,0,0);query_check(1,0,0);reject_command(KV_READ,1,0,0,1,1,0,5);
        append_job(1,0,0,1,-1,0,0,1);append_job(1,0,0,1,-1,0,1,0);
        append_job(1,0,0,1,-1,0,2,0);append_job(1,0,0,1,-1,0,0,0);
        for(integer fault=1;fault<=3;fault++) begin read_job(1,0,0,1,0,0,5,fault);query_check(1,0,1);end
        read_job(1,0,0,1,2,0,4,0);
        send_command(KV_CLEAR,0,0,0,0,0,0,0);finish(KV_OK);shadow_length[0][0]=0;query_check(0,0,0);
        reject_command(KV_READ,0,0,0,1,0,0,5);append_job(0,0,0,1,-1,0,0,0);
        // Joint reset with a write response pending; no metadata survives.
        checking=0;send_command(KV_APPEND,0,0,1,1,0,0,0);hold_b=1;
        timeout_count=0;while(!append_ready) begin @(negedge clk);timeout_count++;require(timeout_count<100,"reset append ready");end
        append_data=8'h55;append_last=0;append_valid=1;@(negedge clk);append_valid=0;
        timeout_count=0;old_writes=writes;while(writes==old_writes) begin @(negedge clk);timeout_count++;require(timeout_count<1000,"reset write pending");end
        // This deliberate aborted write physically modifies the next token only.
        shadow_mem[oracle_addr[oracle_index(0,0,1,0,0)]]=8'h55;
        reset_all();configure_fields();configure(KV_OK);reject_command(KV_READ,0,0,0,1,0,0,5);
        append_job(1,1,0,1,-1,0,0,0);
        // Joint reset while a read result is retained under consumer backpressure.
        checking=0;force_read_stall=1;send_command(KV_READ,1,1,0,1,0,0,5);
        timeout_count=0;while(!read_valid) begin @(negedge clk);timeout_count++;require(timeout_count<1000,"reset read pending");end
        reset_all();configure_fields();configure(KV_OK);query_check(1,1,0);
        append_job(0,0,0,1,-1,0,0,0);read_job(0,0,0,1,0,0,5,0);
        for(integer i=0;i<65536;i++) require(memory.mem[i]===shadow_mem[i],"whole memory, guards and padding protected");
        require(aw_first>0 && w_first>0,"independent AW/W ordering covered");
        require(append_stalls>0 && read_stalls>0,"append and read backpressure exercised");
        $fclose(report);$display("KV_CACHE_TESTS_PASS group=%0d commands=%0d checks=%0d append_stalls=%0d read_stalls=%0d",GROUP_SIZE,commands,checks,append_stalls,read_stalls);$finish;
    end
    initial begin #20000000;$fatal(1,"KV_GLOBAL_TIMEOUT");end
endmodule
module tb_kv_cache_group3;tb_kv_cache #(.GROUP_SIZE(3)) test();endmodule
