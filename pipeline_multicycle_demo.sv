module pipeline_multicycle_demo #(
    parameter   DEPTH = 32,
    parameter   DWIDTH = 16
) (
    input   clk,
    input   rstn,

    input   i_valid,     // 操作使能，
    output  i_ready,
    input   i_opcode,
    input   [$clog2(DEPTH)-1:0] i_addr,
    input   [DWIDTH-1:0] i_ins,

    output  o_valid,
    input   o_ready,
    output  [DWIDTH-1:0] o_data
);

    localparam  AWIDTH = $clog2(DEPTH);
    logic   core_valid;
    logic   core_ready;

    logic   core_opcode;
    logic   [AWIDTH-1:0] core_addr;
    logic   [DWIDTH-1:0] core_ins;

    pipeline_multicycle_opcheck #(AWIDTH) u_opcheck
    (
        .clk(clk),
        .rstn(rstn),

        .i_valid(i_valid),
        .i_ready(i_ready),
        .i_addr(i_addr),
        .i_opcode(i_opcode),
        .i_ins(i_ins),

        .o_valid(core_valid),
        .o_ready(core_ready),
        .o_opcode(core_opcode),
        .o_addr(core_addr),
        .o_ins(core_ins)
    );

    pipeline_multicycle_core #(DEPTH,DWIDTH) u_pipeline_core
    (
        .clk(clk),
        .rstn(rstn),

        .i_valid(core_valid),
        .i_ready(core_ready),
        .i_opcode(core_opcode),
        .i_addr(core_addr),
        .i_ins(core_ins),

        .o_valid(o_valid),
        .o_ready(o_ready),
        .o_data(o_data)
    );
    
endmodule