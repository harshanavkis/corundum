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
    
    // // Header packet
    // assign m_axis_sync_tx_tdata = {
    //     s_axis_sync_rx_tdata[ID_POS +: ID_WIDTH],
    //     s_axis_sync_rx_tdata[OP_POS +: OP_WIDTH],
    //     s_axis_sync_rx_tdata[ADDR_POS +: ADDR_WIDTH],
    //     s_axis_sync_rx_tdata[LEN_POS +: LEN_WIDTH]
    // };

    // assign m_axis_sync_tx_tkeep = s_axis_sync_rx_tkeep[0 +: KEEP_HEADER];
    // /////////////////////

    // Data packet
    assign m_axis_sync_tx_tdata = s_axis_sync_rx_tdata[AXI_DATA_WIDTH-1: DATA_POS];
    assign m_axis_sync_tx_tkeep = s_axis_sync_rx_tkeep[KEEP_WIDTH-1: KEEP_HEADER];
    /////////////////////

    assign m_axis_sync_tx_tvalid = s_axis_sync_rx_tvalid;
    assign s_axis_sync_rx_tready = m_axis_sync_tx_tready;
    assign m_axis_sync_tx_tlast = s_axis_sync_rx_tlast;
    assign m_axis_sync_tx_tuser = s_axis_sync_rx_tuser;



endmodule