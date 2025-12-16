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

    wire mmio_req_valid;
    wire [OP_WIDTH-1:0] mmio_req_rw;
    wire [63:0] mmio_req_addr;
    wire [63:0] mmio_req_data;
    wire mmio_req_ready;
    wire [63:0] mmio_rsp_data;
    wire mmio_rsp_valid;
    wire mmio_rsp_last;
    wire mmio_rsp_ready;

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

    assign mmio_req_valid = txn_generator_in_tvalid;
    assign mmio_req_rw = dev_op; // uses last bit and 0: read, 1: write
    assign mmio_req_addr = dev_addr;
    assign mmio_req_data = dev_mmio_data;

    assign txn_generator_out_tdata = mmio_rsp_data;
    assign txn_generator_out_tkeep = 8'hFF;
    assign txn_generator_out_tvalid = mmio_rsp_valid;
    assign txn_generator_in_tready = mmio_req_ready;
    assign txn_generator_out_tlast = mmio_rsp_last;
    assign mmio_rsp_ready = txn_generator_out_tready;
    assign txn_generator_out_tuser = 1'b0;

    abstract_dma dma_device (
        .clk(clk),
        .rst(rst),
        .mmio_req_valid(mmio_req_valid),
        .mmio_req_rw(mmio_req_rw),
        .mmio_req_addr(mmio_req_addr),
        .mmio_req_data(mmio_req_data),
        .mmio_req_ready(mmio_req_ready),
        .mmio_rsp_data(mmio_rsp_data),
        .mmio_rsp_valid(mmio_rsp_valid),
        .mmio_rsp_last(mmio_rsp_last),
        .mmio_rsp_ready(mmio_rsp_ready),
        .dma_req_valid(),
        .dma_req_rw(),
        .dma_req_len(),
        .dma_req_addr(),
        .dma_req_data(),
        .dma_req_ready(),
        .dma_rsp_valid(),
        .dma_rsp_data(),
        .dma_rsp_ready()
    );

endmodule