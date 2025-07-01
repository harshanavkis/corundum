module txn_generator #(
    parameter AXI_DATA_WIDTH = 512,    // AXI data width
    parameter KEEP_WIDTH = AXI_DATA_WIDTH/8  // TKEEP width (one bit per byte)
)
(
    input  wire clk,
    input  wire rst,

    input  wire [AXI_DATA_WIDTH - 1:0] txn_generator_in_tdata,
    input  wire [KEEP_WIDTH - 1:0] txn_generator_in_tkeep,
    input  wire txn_generator_in_tvalid,
    output wire txn_generator_in_tready,
    input  wire txn_generator_in_tlast,
    input  wire txn_generator_in_tuser,

    output wire [AXI_DATA_WIDTH - 1:0] txn_generator_out_tdata,
    output wire [KEEP_WIDTH - 1:0] txn_generator_out_tkeep,
    output wire txn_generator_out_tvalid,
    input  wire txn_generator_out_tready,
    output wire txn_generator_out_tlast,
    output wire txn_generator_out_tuser
);

    assign txn_generator_out_tdata = ~txn_generator_in_tdata;
    assign txn_generator_out_tkeep = txn_generator_in_tkeep;
    assign txn_generator_out_tvalid = txn_generator_in_tvalid;
    assign txn_generator_in_tready = txn_generator_out_tready;
    assign txn_generator_out_tlast = txn_generator_in_tlast;
    assign txn_generator_out_tuser = txn_generator_in_tuser;

endmodule