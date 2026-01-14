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
    input  wire [1:0][AXI_DATA_WIDTH-1:0]    s_axis_sync_rx_tdata,
    input  wire [1:0][KEEP_WIDTH-1:0]    s_axis_sync_rx_tkeep,
    input  wire [1:0]                   s_axis_sync_rx_tvalid,
    output wire [1:0]                   s_axis_sync_rx_tready,
    input  wire [1:0]                   s_axis_sync_rx_tlast,
    input  wire [1:0]                   s_axis_sync_rx_tuser,
    
    // Master AXI Stream interface (Output)
    output wire [1:0][AXI_DATA_WIDTH-1:0]    m_axis_sync_tx_tdata,
    output wire [1:0][KEEP_WIDTH-1:0]    m_axis_sync_tx_tkeep,
    output wire [1:0]                   m_axis_sync_tx_tvalid,
    input  wire [1:0]                   m_axis_sync_tx_tready,
    output wire [1:0]                   m_axis_sync_tx_tlast,
    output wire [1:0]                   m_axis_sync_tx_tuser
);

    // Calculate field positions
    localparam ID_POS = 0;
    localparam OP_POS = ID_WIDTH;
    localparam ADDR_POS = OP_POS + OP_WIDTH;
    localparam LEN_POS = ADDR_POS + ADDR_WIDTH;
    localparam DATA_POS = LEN_POS + LEN_WIDTH;
    localparam KEEP_HEADER = (ID_WIDTH + OP_WIDTH + ADDR_WIDTH + LEN_WIDTH)/8;

    // txn_generator txner(
    //     .clk(clk),
    //     .rst(rst),
    //     .txn_generator_in_tdata(s_axis_sync_rx_tdata),
    //     .txn_generator_in_tkeep(s_axis_sync_rx_tkeep),
    //     .txn_generator_in_tvalid(s_axis_sync_rx_tvalid),
    //     .txn_generator_in_tready(s_axis_sync_rx_tready),
    //     .txn_generator_in_tlast(s_axis_sync_rx_tlast),
    //     .txn_generator_in_tuser(s_axis_sync_rx_tuser),
    //     .txn_generator_out_tdata(m_axis_sync_tx_tdata),
    //     .txn_generator_out_tkeep(m_axis_sync_tx_tkeep),
    //     .txn_generator_out_tvalid(m_axis_sync_tx_tvalid),
    //     .txn_generator_out_tready(m_axis_sync_tx_tready),
    //     .txn_generator_out_tlast(m_axis_sync_tx_tlast),
    //     .txn_generator_out_tuser(m_axis_sync_tx_tuser)
    // );

    // jigsaw_host_side jigsaw_host_side_dma_wr (
    //     .clk(clk),
    //     .rst(rst),
    //     .network_in_tdata(s_axis_sync_rx_tdata),
    //     .network_in_tkeep(s_axis_sync_rx_tkeep),
    //     .network_in_tvalid(s_axis_sync_rx_tvalid),
    //     .network_in_tready(s_axis_sync_rx_tready),
    //     .network_in_tlast(s_axis_sync_rx_tlast),
    //     .network_in_tuser(s_axis_sync_rx_tuser),
    //     .network_out_tdata(),
    //     .network_out_tkeep(),
    //     .network_out_tvalid(),
    //     .network_out_tready(),
    //     .network_out_tlast(),
    //     .network_out_tuser(),
    //     .host_in_tdata(),
    //     .host_in_tkeep(),
    //     .host_in_tvalid(),
    //     .host_in_tready(),
    //     .host_in_tlast(),
    //     .host_in_tuser(),
    //     .host_out_tdata(m_axis_sync_tx_tdata),
    //     .host_out_tkeep(m_axis_sync_tx_tkeep),
    //     .host_out_tvalid(m_axis_sync_tx_tvalid),
    //     .host_out_tready(m_axis_sync_tx_tready),
    //     .host_out_tlast(m_axis_sync_tx_tlast),
    //     .host_out_tuser(m_axis_sync_tx_tuser),
    //     .sq_valid_write(),
    //     .sq_dir_write(),
    //     .sq_addr_write(),
    //     .sq_len_write(),
    //     .sq_valid_read(),
    //     .sq_dir_read(),
    //     .sq_addr_read(),
    //     .sq_len_read(),
    //     .mmio_vaddr()
    // );

    logic network_in_tready;
    logic host_in_tready;

    assign s_axis_sync_rx_tready = network_in_tready || host_in_tready;
    
    jigsaw_host_side jigsaw_host_side_dma_rd (
        .clk(clk),
        .rst(rst),
        .network_in_tdata(s_axis_sync_rx_tdata),
        .network_in_tkeep(s_axis_sync_rx_tkeep),
        .network_in_tvalid(s_axis_sync_rx_tvalid),
        .network_in_tready(network_in_tready),
        .network_in_tlast(s_axis_sync_rx_tlast),
        .network_in_tuser(s_axis_sync_rx_tuser),
        .network_out_tdata(m_axis_sync_tx_tdata),
        .network_out_tkeep(m_axis_sync_tx_tkeep),
        .network_out_tvalid(m_axis_sync_tx_tvalid),
        .network_out_tready(m_axis_sync_tx_tready),
        .network_out_tlast(m_axis_sync_tx_tlast),
        .network_out_tuser(m_axis_sync_tx_tuser),
        .host_in_tdata(s_axis_sync_rx_tdata),
        .host_in_tkeep(s_axis_sync_rx_tkeep),
        .host_in_tvalid(s_axis_sync_rx_tvalid),
        .host_in_tready(host_in_tready),
        .host_in_tlast(s_axis_sync_rx_tlast),
        .host_in_tuser(s_axis_sync_rx_tuser),
        .host_out_tdata(),
        .host_out_tkeep(),
        .host_out_tvalid(),
        .host_out_tready(m_axis_sync_tx_tready),
        .host_out_tlast(),
        .host_out_tuser(),
        .sq_valid_write(),
        .sq_dir_write(),
        .sq_addr_write(),
        .sq_len_write(),
        .sq_valid_read(),
        .sq_dir_read(),
        .sq_addr_read(),
        .sq_len_read(),
        .mmio_vaddr(),
        .mmio_ctrl(),
        .mmio_clear()
    );

endmodule