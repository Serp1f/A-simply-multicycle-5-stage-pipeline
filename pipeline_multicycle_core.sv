module pipeline_multicycle_core #(
    parameter   DEPTH = 32,
    parameter   DWIDTH = 16
) (
    input       clk,
    input       rstn,

    input   i_valid,     // 操作使能，
    output  i_ready,
    input   i_opcode,
    input   [$clog2(DEPTH)-1:0] i_addr,
    input   [DWIDTH-1:0] i_ins,

    output  o_valid,
    input   o_ready,
    output  [DWIDTH-1:0] o_data
);

    localparam PIPE_STAGE = 4;
    logic [2:0][DWIDTH-1:0]                 pipe_ins;
    logic [2:0]                             pipe_opcode;
    logic [PIPE_STAGE:0][$clog2(DEPTH)-1:0] pipe_addr;
    logic [PIPE_STAGE:0][DWIDTH-1:0]        pipe_data;

    logic [DWIDTH-1:0]   bypass_rdata_p1;    // 因为无法直接修改ram的rdata而对wdata进行打拍
    logic bypass_load;
    logic byp_rdata_valid;    // bp_data寄存器现在被写入，数据是有效的
    logic [2:0] mux_sel_p1;
    logic [DEPTH-1:0]   addr_accessed;
    logic addr_not_acc_p1;  // 该指令访问RAM的地址之前未被访问

    // 以前向传播来命名
    logic   [PIPE_STAGE-1:0]    pipe_valid_tmp;
    logic   [PIPE_STAGE:0]  pipe_valid,pipe_ready;
    logic   op_2cycle_block;        // 延迟为2的指令还在ALU的第一级，此时无法转发数据，反压P1的指令，不让其进入ALU

    logic ram_wen,ram_ren,ram_ren_q;
    logic [$clog2(DEPTH)-1:0]   ram_waddr,ram_raddr;
    logic [DWIDTH-1:0]   ram_wdata,ram_rdata;
    logic [DEPTH-1:0]   addr_accessed_set_mask;

    logic   [DWIDTH-1:0]        bypass_data_p1_s1,bypass_data_p1_s2,bypass_data_p1_s3,bypass_data_p1_s4;
    logic   [DWIDTH-1:0]        alu_res,alu_res_1cycle;
    logic   [PIPE_STAGE:0]      bypass_to_p0;       // p0被其他级bypass，可以不用读RAM，低功耗考虑,0:tie 0,1: P1, 1:P2 ...
    logic   [PIPE_STAGE:0]      bypass_to_p1;       // p1被其他级bypass，需要作数据转发给ALU,0,1:tie 0,1: P2, 1:P3 ...
    logic   [PIPE_STAGE:0]      addr_eq_p0;         // 地址与p0的地址一致,0:tie 0,1: P1, 1:P2 ...
    logic   [PIPE_STAGE:0]      addr_eq_p1;         // 地址与p1的地址一致,0,1:tie 0,1: P2, 1:P3 ...

// =============== pipeline ===============//

// valid的前向传播
    generate
        // pipe_valid[1],p1
        always_ff @(posedge clk) begin
            if(~rstn)
                pipe_valid_tmp[0] <= 1'b0;
            else if(pipe_ready[0])
                pipe_valid_tmp[0] <= i_valid;
        end
        // pipe_valid[2],p2
        always_ff @(posedge clk) begin
            if(~rstn)
                pipe_valid_tmp[1] <= 1'b0;
            else if(pipe_valid_tmp[0] && pipe_ready[1] && ~op_2cycle_block)
                pipe_valid_tmp[1] <= 1'b1;
            else if(pipe_valid_tmp[1] && pipe_ready[2])
                pipe_valid_tmp[1] <= 1'b0;
        end

        for(genvar k=2;k<PIPE_STAGE;k=k+1) begin
            always_ff @(posedge clk) begin
                if(~rstn)
                    pipe_valid_tmp[k] <= 1'b0;
                else if(pipe_ready[k])
                    pipe_valid_tmp[k] <= pipe_valid_tmp[k-1];
            end
        end
    endgenerate
    assign  pipe_valid = {pipe_valid_tmp,i_valid};

//  当此时在ALU第一级的指令是乘法指令且与P1的指令地址相同，阻塞P1
    assign  op_2cycle_block = pipe_valid[2] && pipe_valid[1] && pipe_opcode[2] && addr_eq_p1[2];

// ready的反向传播
    always_comb begin
        pipe_ready[4] = o_ready;
        for(int i=PIPE_STAGE-1;i>=0;i=i-1) begin
            if(i==1) 
                pipe_ready[1] = ~pipe_valid[2] || (pipe_ready[2] && ~op_2cycle_block);
            else
                pipe_ready[i] = pipe_ready[i+1] || ~pipe_valid[i+1];
        end
    end

// ================ ram ================== //

    assign  ram_wen     = pipe_valid[4] && pipe_ready[4];
    assign  ram_waddr   = pipe_addr[4];
    assign  ram_wdata   = pipe_data[4];
// 读ram条件：
// 1.ram的该地址已被初始化
// 2.不需要bypass
    assign  ram_ren     = pipe_valid[0] && pipe_ready[0] && addr_accessed[i_addr] && (~|bypass_to_p0);   
    assign  ram_raddr   = pipe_addr[0];

    always_ff @( posedge clk ) begin
        if(~rstn)
            ram_ren_q <= 1'b0;
        else
            ram_ren_q <= ram_ren;
    end

    ram_2p #(DEPTH,DWIDTH)   u_ram
    (
        .clk(clk),
        
        .wen(ram_wen),
        .waddr(ram_waddr),
        .wdata(ram_wdata),
        .ren(ram_ren),
        .raddr(ram_raddr),
        .rdata(ram_rdata)
    );

// ============== pipeline E0 ===============//
    assign  pipe_addr[0] = i_addr;
    assign  pipe_ins[0] = i_ins;
    assign  pipe_data[0] = 'd0;
    assign  pipe_opcode[0] = i_opcode;

// =============== pipeline E1 ============= //

    assign  pipe_data[1] = 'd0;
    always_ff @( posedge clk ) begin 
        if(~rstn) begin
            pipe_addr[1] <= {$clog2(DEPTH){1'b0}};
            pipe_ins[1] <= {DWIDTH{1'b0}};
            pipe_opcode[1] <= 1'b0;
            addr_not_acc_p1 <= 1'b0;
        end
        else if(pipe_valid[0] && pipe_ready[0]) begin
            pipe_addr[1] <= pipe_addr[0];
            pipe_ins[1] <= pipe_ins[0];
            pipe_opcode[1] <= pipe_opcode[0];
            addr_not_acc_p1 <= ~addr_accessed[i_addr];
        end
    end

// ==================== ALU ====================//

    assign  mux_sel_p1 = {byp_rdata_valid,ram_ren_q&&(~|bypass_to_p1),addr_not_acc_p1};
    mux_one_hot #(3,DWIDTH) u_mux (
        .mux_in({bypass_rdata_p1,ram_rdata,{DWIDTH{1'b0}}}),
        .sel(mux_sel_p1),
        .mux_out(bypass_data_p1_s1)
    );

// 注意mux顺序，离P1最近的指令优先级最高
    assign  bypass_data_p1_s2 = bypass_to_p1[4] ? pipe_data[4]  :   bypass_data_p1_s1;
    assign  bypass_data_p1_s3 = bypass_to_p1[3] ? alu_res       :   bypass_data_p1_s2;
    assign  bypass_data_p1_s4 = bypass_to_p1[2] ? alu_res_1cycle:   bypass_data_p1_s3;

// 反压控制由流水线完成，不用alu内部的流水线反压控制
    pipeline_multicycle_alu #(DWIDTH) u_alu (
        .clk(clk),
        .rstn(rstn),

        .i_valid(pipe_valid[2]),
        .i_ready(),
        .i_opcode(pipe_opcode[2]),
        .a(pipe_data[2]),
        .b(pipe_ins[2]),

        .o_valid(),
        .o_ready(pipe_ready[3]),
        .c(alu_res),

        .c_1cycle(alu_res_1cycle)
    );
    
// ================ pipeline E2 ================= //

    always_ff @(posedge clk) begin
        if(~rstn) begin
            pipe_addr[2] <= {$clog2(DEPTH){1'b0}}; 
            pipe_opcode[2] <= 'b0;
            pipe_ins[2] <= 'd0;
            pipe_data[2] <= 'd0;
        end
        else if(pipe_valid[1] && pipe_ready[1] && ~op_2cycle_block) begin
            pipe_addr[2] <= pipe_addr[1];
            pipe_opcode[2] <= pipe_opcode[1];
            pipe_ins[2] <= pipe_ins[1];
            pipe_data[2] <= bypass_data_p1_s4;
        end
    end

// ================= pipeline E3 ==================//

    assign  pipe_data[3] = alu_res_1cycle;
    always_ff @(posedge clk) begin
        if(~rstn) begin
            pipe_addr[3] <= {$clog2(DEPTH){1'b0}}; 
        end
        else if(pipe_valid[2] && pipe_ready[2]) begin
            pipe_addr[3] <= pipe_addr[2];
        end
    end

// ================= pipeline E4 ==================//

    always_ff @(posedge clk) begin
        if(~rstn) begin
            pipe_addr[4] <= {$clog2(DEPTH){1'b0}}; 
            pipe_data[4] <= 'd0;
        end
        else if(pipe_valid[3] && pipe_ready[3]) begin
            pipe_addr[4] <= pipe_addr[3];
            pipe_data[4] <= alu_res;
        end
    end

// =================== forwarding ================= //

    always_ff @(posedge clk ) begin
        if(~rstn)
            bypass_rdata_p1 <= {DWIDTH{1'b0}};
        else if(pipe_valid[0] && pipe_ready[0] && bypass_to_p0[4])  // 检测到raddr == waddr时才使用此bp_data 
            bypass_rdata_p1 <= ram_wdata;
        else if(pipe_valid[1] && ram_ren_q && ~pipe_ready[1] && (~|bypass_to_p1))   // RAM产生读数据但是流水线停滞了,并且没有bypass
            bypass_rdata_p1 <= ram_rdata;
    end

// 加载bp_data_p1的情况
// 1. P2的数据转发到P0
// 2. RAM的读数据出来但是P1被反压 并且该数据不需要被P2转发
    assign  bypass_load = (pipe_valid[0] && pipe_ready[0] && bypass_to_p0[4]) || (pipe_valid[1] && ram_ren_q && ~pipe_ready[1] && (~|bypass_to_p1));

    always_ff @(posedge clk) begin
        if(~rstn)
            byp_rdata_valid <= 1'b0;
        else if(bypass_load)    //  如果写入bp_data_p1 就拉高
            byp_rdata_valid <= 1'b1;
        else if(pipe_valid[1] && pipe_ready[1])
            byp_rdata_valid <= 1'b0;
    end

// 仿真debug用
    logic   ram_rdata_block;
    assign  ram_rdata_block = pipe_valid[1] && ram_ren_q && ~pipe_ready[1];

    always_comb begin
        addr_eq_p0[0] = 1'b0;
        bypass_to_p0[0] = 1'b0;
        for(int i=1;i<=PIPE_STAGE;i=i+1) begin
            addr_eq_p0[i] = pipe_addr[i] == pipe_addr[0];
            bypass_to_p0[i] = pipe_valid[0] && pipe_valid[i] && addr_eq_p0[i];
        end
    end

    always_comb begin
        addr_eq_p1[1:0] = 2'b00;
        bypass_to_p1[1:0] = 2'b00;
        for(int i=2;i<=PIPE_STAGE;i=i+1) begin
            addr_eq_p1[i] = pipe_addr[i] == pipe_addr[1];
            bypass_to_p1[i] = pipe_valid[1] && pipe_valid[i] && addr_eq_p1[i]; 
        end
    end

// ============ ram_accessed ============ //

    assign  addr_accessed_set_mask = 1 << i_addr;
    always_ff @(posedge clk ) begin
        if(~rstn)
            addr_accessed <= {DEPTH{1'b0}};
        else if(pipe_valid[0] && pipe_ready[0])
            addr_accessed <= addr_accessed | addr_accessed_set_mask;
    end

// ============== output ================//

    assign  i_ready = pipe_ready[0];
    assign  o_valid = pipe_valid[4];
    assign  o_data  = pipe_data[4];

endmodule