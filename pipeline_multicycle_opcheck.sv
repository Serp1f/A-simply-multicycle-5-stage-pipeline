module pipeline_multicycle_opcheck #(
    parameter   AWIDTH = 4,
    parameter   DWIDTH = 16
)(
    input   clk,
    input   rstn,
    
    input   i_valid,
    output  i_ready,
    input   [AWIDTH-1:0] i_addr,
    input   i_opcode,
    input   [DWIDTH-1:0] i_ins,

    output  logic o_valid,
    output  logic [AWIDTH-1:0] o_addr,
    output  logic o_opcode,
    output  logic [DWIDTH-1:0] o_ins,
    input   o_ready
);

    logic   op_2cycle;
    logic   addr_b2b;       // 前后两拍的地址相等
    logic   block;
 
    always_ff @(posedge clk) begin
        if(~rstn)
            op_2cycle <= 1'b0;
        else if(i_valid && i_ready && i_opcode && ~block)     // 指令进入
            op_2cycle <= 1'b1;
        else if(o_valid && o_ready) // 指令已经进入流水线执行
            op_2cycle <= 1'b0;
    end

    always_ff @(posedge clk) begin
        if(~rstn) begin
            o_addr <= 'd0;
            o_opcode <= 'd0;
            o_ins <= 'd0;
        end
        else if(i_valid && i_ready) begin
            o_addr <= i_addr;
            o_opcode <= i_opcode;
            o_ins <= i_ins;
        end
    end

    always_ff @(posedge clk) begin
        if(~rstn)
            o_valid <= 1'b0;
        else if(i_valid && i_ready && ~block)
            o_valid <= 1'b1;
        else if(o_valid && o_ready)
            o_valid <= 1'b0;
    end
    
// 禁止指令条件
// 在乘法指令进入的下一个时钟周期，访问相同地址的指令（加法/乘法）均不得进入
    assign  addr_b2b = i_addr == o_addr;
    assign  block = addr_b2b && op_2cycle;
    assign  i_ready = ~o_valid || (o_valid && o_ready && ~block);

endmodule