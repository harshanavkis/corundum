module jigsaw_pkt_processor #(
    parameter ID_WIDTH = 4,        // Width of ID field, parameterizable
    parameter OP_WIDTH = 4,        // Width of operation field
    parameter ADDR_WIDTH = 64,     // Width of address field
    parameter LEN_WIDTH = 16,      // Width of length field
    parameter AXI_DATA_WIDTH = 512,    // AXI data width
    parameter KEEP_WIDTH = AXI_DATA_WIDTH/8  // TKEEP width (one bit per byte)
) (
    // Clock and reset
    input  wire                     clk,
    input  wire                     rst,
    
    // Slave AXI Stream interface (Input)
    input  wire [AXI_DATA_WIDTH-1:0]    s_axis_sync_rx_tdata,
    input  wire [KEEP_WIDTH-1:0]    s_axis_sync_rx_tkeep,
    input  wire                     s_axis_sync_rx_tvalid,
    output wire                     s_axis_sync_rx_tready,
    input  wire                     s_axis_sync_rx_tlast,
    input  wire                     s_axis_sync_rx_tuser,
    
    // Master AXI Stream interface (Output)
    output wire [AXI_DATA_WIDTH-1:0]    m_axis_sync_tx_tdata,
    output wire [KEEP_WIDTH-1:0]    m_axis_sync_tx_tkeep,
    output wire                     m_axis_sync_tx_tvalid,
    input  wire                     m_axis_sync_tx_tready,
    output wire                     m_axis_sync_tx_tlast,
    output wire                     m_axis_sync_tx_tuser
);

    // Calculate field positions
    localparam ID_POS = 0;
    localparam OP_POS = ID_WIDTH;
    localparam ADDR_POS = OP_POS + OP_WIDTH;
    localparam LEN_POS = ADDR_POS + ADDR_WIDTH;
    localparam DATA_POS = LEN_POS + LEN_WIDTH;
    localparam KEEP_HEADER = (ID_WIDTH + OP_WIDTH + ADDR_WIDTH + LEN_WIDTH)/8;

    txn_generator txner(
        .clk(clk),
        .rst(rst),
        .txn_generator_in_tdata(s_axis_sync_rx_tdata),
        .txn_generator_in_tkeep(s_axis_sync_rx_tkeep),
        .txn_generator_in_tvalid(s_axis_sync_rx_tvalid),
        .txn_generator_in_tready(s_axis_sync_rx_tready),
        .txn_generator_in_tlast(s_axis_sync_rx_tlast),
        .txn_generator_in_tuser(s_axis_sync_rx_tuser),
        .txn_generator_out_tdata(m_axis_sync_tx_tdata),
        .txn_generator_out_tkeep(m_axis_sync_tx_tkeep),
        .txn_generator_out_tvalid(m_axis_sync_tx_tvalid),
        .txn_generator_out_tready(m_axis_sync_tx_tready),
        .txn_generator_out_tlast(m_axis_sync_tx_tlast),
        .txn_generator_out_tuser(m_axis_sync_tx_tuser)
    );


endmodule