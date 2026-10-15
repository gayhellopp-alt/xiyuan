// Storage-side contract v1; no dependency on the software/control task format.
package w4a8_memory_pkg;
    localparam logic [15:0] MEMORY_FORMAT_V1=16'h0001;
    localparam logic [3:0] MEM_OK=0, MEM_BAD_TASK=1, MEM_READ_ERROR=2,
        MEM_WRITE_ERROR=3, MEM_CORE_ERROR=4, MEM_PROTOCOL_ERROR=5;
    typedef struct packed {
        logic [31:0] task_id;
        logic [15:0] m,n,k,format_id,group_size;
        logic [31:0] a_base,w_base,sx_base,sw_base,y_base;
        logic [31:0] a_stride,w_stride,sx_stride,sw_stride,y_stride;
        logic [31:0] a_bytes,w_bytes,sx_bytes,sw_bytes,y_bytes;
    } memory_task_t;
    function automatic logic region_ok(input logic [31:0] base,bytes,
                                      input logic [63:0] extent);
        return bytes!=0 && extent<=64'(bytes) &&
            64'(base)+64'(bytes)<=64'h1_0000_0000;
    endfunction
    function automatic logic overlaps(input logic [31:0] b0,s0,b1,s1);
        return 64'(b0)<64'(b1)+64'(s1) && 64'(b1)<64'(b0)+64'(s0);
    endfunction
endpackage
