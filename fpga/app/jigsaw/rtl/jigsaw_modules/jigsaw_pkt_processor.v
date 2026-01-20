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
    input  wire                    s_axis_sync_rx_tvalid,
    output wire                    s_axis_sync_rx_tready,
    input  wire                    s_axis_sync_rx_tlast,
    input  wire                    s_axis_sync_rx_tuser,
    
    // Master AXI Stream interface (Output)
    output wire [AXI_DATA_WIDTH-1:0]    m_axis_sync_tx_tdata,
    output wire [KEEP_WIDTH-1:0]    m_axis_sync_tx_tkeep,
    output wire                    m_axis_sync_tx_tvalid,
    input  wire                    m_axis_sync_tx_tready,
    output wire                    m_axis_sync_tx_tlast,
    output wire                    m_axis_sync_tx_tuser
);

    // Calculate field positions
    localparam ID_POS = 0;
    localparam OP_POS = ID_WIDTH;
    localparam ADDR_POS = OP_POS + OP_WIDTH;
    localparam LEN_POS = ADDR_POS + ADDR_WIDTH;
    localparam DATA_POS = LEN_POS + LEN_WIDTH;
    localparam KEEP_HEADER = (ID_WIDTH + OP_WIDTH + ADDR_WIDTH + LEN_WIDTH)/8;

    // Intermediate wires for jigsaw_host_side network interface to txn_generator
    wire [AXI_DATA_WIDTH-1:0] network_to_txn_tdata;
    wire [KEEP_WIDTH-1:0] network_to_txn_tkeep;
    wire network_to_txn_tvalid;
    wire network_to_txn_tready;
    wire network_to_txn_tlast;
    wire network_to_txn_tuser;

    wire [AXI_DATA_WIDTH-1:0] txn_to_network_tdata;
    wire [KEEP_WIDTH-1:0] txn_to_network_tkeep;
    wire txn_to_network_tvalid;
    wire txn_to_network_tready;
    wire txn_to_network_tlast;
    wire txn_to_network_tuser;

    // Submission queue wires
    wire sq_valid_write;
    wire sq_dir_write;
    wire [63:0] sq_addr_write;
    wire [63:0] sq_len_write;
    wire sq_valid_read;
    wire sq_dir_read;
    wire [63:0] sq_addr_read;
    wire [63:0] sq_len_read;

    // MMIO wires
    wire [63:0] mmio_vaddr;
    wire mmio_ctrl;
    wire mmio_clear;
    wire mmio_write_done;
    wire mmio_read_done;

    // Single jigsaw_host_side instance
    // Host interfaces connected to jigsaw_pkt_processor interfaces
    // Network interfaces connected to txn_generator
    jigsaw_host_side jigsaw_host_side_inst (
        .clk(clk),
        .rst(rst),

        // Network side: connected to txn_generator
        .network_in_tdata(txn_to_network_tdata),
        .network_in_tkeep(txn_to_network_tkeep),
        .network_in_tvalid(txn_to_network_tvalid),
        .network_in_tready(txn_to_network_tready),
        .network_in_tlast(txn_to_network_tlast),
        .network_in_tuser(txn_to_network_tuser),

        .network_out_tdata(network_to_txn_tdata),
        .network_out_tkeep(network_to_txn_tkeep),
        .network_out_tvalid(network_to_txn_tvalid),
        .network_out_tready(network_to_txn_tready),
        .network_out_tlast(network_to_txn_tlast),
        .network_out_tuser(network_to_txn_tuser),

        // Host side: connected to jigsaw_pkt_processor interfaces
        .host_in_tdata(s_axis_sync_rx_tdata),
        .host_in_tkeep(s_axis_sync_rx_tkeep),
        .host_in_tvalid(s_axis_sync_rx_tvalid),
        .host_in_tready(s_axis_sync_rx_tready),
        .host_in_tlast(s_axis_sync_rx_tlast),
        .host_in_tuser(s_axis_sync_rx_tuser),

        .host_out_tdata(m_axis_sync_tx_tdata),
        .host_out_tkeep(m_axis_sync_tx_tkeep),
        .host_out_tvalid(m_axis_sync_tx_tvalid),
        .host_out_tready(m_axis_sync_tx_tready),
        .host_out_tlast(m_axis_sync_tx_tlast),
        .host_out_tuser(m_axis_sync_tx_tuser),

        // Submission queue interfaces
        .sq_valid_write(sq_valid_write),
        .sq_dir_write(sq_dir_write),
        .sq_addr_write(sq_addr_write),
        .sq_len_write(sq_len_write),
        .sq_valid_read(sq_valid_read),
        .sq_dir_read(sq_dir_read),
        .sq_addr_read(sq_addr_read),
        .sq_len_read(sq_len_read),

        // MMIO interfaces
        .mmio_vaddr(mmio_vaddr),
        .mmio_ctrl(mmio_ctrl),
        .mmio_clear(mmio_clear),
        .mmio_write_done(mmio_write_done),
        .mmio_read_done(mmio_read_done)
    );

    // txn_generator instance
    // Input from jigsaw_host_side network_out, output to jigsaw_host_side network_in
    txn_generator txner(
        .clk(clk),
        .rst(rst),
        .txn_generator_in_tdata(network_to_txn_tdata),
        .txn_generator_in_tkeep(network_to_txn_tkeep),
        .txn_generator_in_tvalid(network_to_txn_tvalid),
        .txn_generator_in_tready(network_to_txn_tready),
        .txn_generator_in_tlast(network_to_txn_tlast),
        .txn_generator_in_tuser(network_to_txn_tuser),
        .txn_generator_out_tdata(txn_to_network_tdata),
        .txn_generator_out_tkeep(txn_to_network_tkeep),
        .txn_generator_out_tvalid(txn_to_network_tvalid),
        .txn_generator_out_tready(txn_to_network_tready),
        .txn_generator_out_tlast(txn_to_network_tlast),
        .txn_generator_out_tuser(txn_to_network_tuser)
    );

endmodule