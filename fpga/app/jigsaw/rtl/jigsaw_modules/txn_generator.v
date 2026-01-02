module txn_generator #(
    parameter AXI_DATA_WIDTH = 512,    // AXI data width
    parameter KEEP_WIDTH = AXI_DATA_WIDTH/8,  // TKEEP width (one bit per byte)
    parameter OP_WIDTH = 8,
    parameter ADDR_WIDTH = 64,
    parameter LEN_WIDTH = 64
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

    /*
    Packets can be of three types: rd, wr, reply

    For such packet types originating from the input (txn_generator_in):
        - rd, wr: indicates MMIO access
        - reply: indicates reply to a DMA read operation from the device
    
    Similarly while sending, the generator must prepend the type:
        - reply: contains the MMIO read request
        - rd, wr: performs DMA to the remote memory region, includes address in plaintext
            - For wr, payload is encrypted
    
    Packet structure received:
        - |8-bit TYPE|Payload|
    
    Payload structure:
        - |8-bit OP|64-bit address|64-bit length|Payload Data|
    
    Payload Data for MMIO:
        - 64-bit fixed size

    Payload data for DMA:
        - Variable size depending on DMA'ed data
    */

    // assign txn_generator_out_tdata = ~txn_generator_in_tdata;
    // assign txn_generator_out_tkeep = txn_generator_in_tkeep;
    // assign txn_generator_out_tvalid = txn_generator_in_tvalid;
    // assign txn_generator_in_tready = txn_generator_out_tready;
    // assign txn_generator_out_tlast = txn_generator_in_tlast;
    // assign txn_generator_out_tuser = txn_generator_in_tuser;

    localparam OP_POS = 0;
    localparam ADDR_POS = OP_POS + OP_WIDTH;
    localparam LEN_POS = ADDR_POS + ADDR_WIDTH;
    localparam DATA_POS = LEN_POS + LEN_WIDTH;
    localparam KEEP_HEADER = (OP_WIDTH + ADDR_WIDTH + LEN_WIDTH)/8;

    wire [OP_WIDTH-1:0] dev_op, op;
    wire [ADDR_WIDTH-1:0] dev_addr, addr;
    wire [LEN_WIDTH-1:0] dev_len, len;
    wire [63:0] dev_mmio_data, data;

    assign dev_op = txn_generator_in_tdata[OP_POS +: OP_WIDTH];
    assign dev_addr = txn_generator_in_tdata[ADDR_POS +: ADDR_WIDTH];
    assign dev_len = txn_generator_in_tdata[LEN_POS +: LEN_WIDTH];
    assign dev_mmio_data = txn_generator_in_tdata[DATA_POS+: 64];

    wire [71:0] mmio_read_data;
    wire mmio_read_valid;

    wire dma_start;
    wire dma_direction;
    wire [63:0] dma_src_addr;
    wire [63:0] dma_dst_addr;
    wire [63:0] dma_len;
    wire dma_status;
    wire dma_status_valid;

    wire payload_mmio_valid;
    assign payload_mmio_valid = txn_generator_in_tvalid && ((dev_op == 8'd0) || (dev_op == 8'd1));
    wire clear_dma_start;

    wire [AXI_DATA_WIDTH-1:0] payload_to_dma_out_tdata;
    wire [KEEP_WIDTH-1:0] payload_to_dma_out_tkeep;
    wire payload_to_dma_out_tvalid;
    wire payload_to_dma_out_tready;
    wire payload_to_dma_out_tlast;
    wire payload_to_dma_out_tuser;

    payload_to_mmio payload_to_mmio (
        .clk(clk),
        .rst(rst),
        .op_code(dev_op),
        .address(dev_addr),
        .payload_data(dev_mmio_data),
        .payload_valid(payload_mmio_valid),
        .payload_ready(txn_generator_in_tready),
        .read_data(mmio_read_data),
        .read_data_valid(mmio_read_valid),
        .read_data_ready(txn_generator_out_tready & ~payload_to_dma_out_tvalid),  // Gate with DMA inactive
        .dma_start(dma_start),
        .dma_direction(dma_direction),
        .dma_src_addr(dma_src_addr),
        .dma_dst_addr(dma_dst_addr),
        .dma_len(dma_len),
        .dma_status(dma_status),
        .dma_status_valid(dma_status_valid),
        .computation_status(0),
        .computation_status_valid(1'b0),
        .clear_dma_start(clear_dma_start)
    );

    payload_to_dma payload_to_dma (
        .clk(clk),
        .rst(rst),
        .dma_start(dma_start),
        .dma_direction(dma_direction),
        .dma_src_addr(dma_src_addr),
        .dma_dst_addr(dma_dst_addr),
        .dma_len(dma_len),
        .dma_status(dma_status),
        .dma_status_valid(dma_status_valid),
        .clear_dma_start(clear_dma_start),
        .payload_to_dma_in_tdata(),
        .payload_to_dma_in_tkeep(),
        .payload_to_dma_in_tvalid(),
        .payload_to_dma_in_tready(),
        .payload_to_dma_in_tlast(),
        .payload_to_dma_in_tuser(),
        .payload_to_dma_out_tdata(payload_to_dma_out_tdata),
        .payload_to_dma_out_tkeep(payload_to_dma_out_tkeep),
        .payload_to_dma_out_tvalid(payload_to_dma_out_tvalid),
        .payload_to_dma_out_tready(payload_to_dma_out_tready),
        .payload_to_dma_out_tlast(payload_to_dma_out_tlast),
        .payload_to_dma_out_tuser(payload_to_dma_out_tuser)
    );

    assign txn_generator_out_tdata = mmio_read_valid ? {{(AXI_DATA_WIDTH-72){1'b0}}, mmio_read_data} : payload_to_dma_out_tdata;
    assign txn_generator_out_tkeep = mmio_read_valid ? {{(KEEP_WIDTH-9){1'b0}}, 9'h1FF} : payload_to_dma_out_tkeep;
    assign txn_generator_out_tvalid = mmio_read_valid | payload_to_dma_out_tvalid;
    assign txn_generator_out_tlast = mmio_read_valid ? 1'b1 : payload_to_dma_out_tlast;
    assign txn_generator_out_tuser = mmio_read_valid ? 1'b0 : payload_to_dma_out_tuser;

    assign payload_to_dma_out_tready = txn_generator_out_tready & ~mmio_read_valid;

endmodule