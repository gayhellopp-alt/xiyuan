package attention_pkg;
    typedef struct packed {
        logic [31:0] task_id;
        logic [15:0] layer,head,tokens,dimension,score_scale;
        logic [63:0] y_addr;
        logic [31:0] y_bytes;
    } attention_task_t;
endpackage
