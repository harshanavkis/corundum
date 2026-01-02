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

    localparam OP_POS = 0;
    localparam ADDR_POS = OP_POS + OP_WIDTH;
    localparam LEN_POS = ADDR_POS + ADDR_WIDTH;
    localparam DATA_POS = LEN_POS + LEN_WIDTH;

    wire [OP_WIDTH-1:0] dev_op;
    assign dev_op = txn_generator_in_tdata[OP_POS +: OP_WIDTH];

    // MMIO path signals
    wire [71:0] mmio_read_data;
    wire mmio_read_valid;
    wire mmio_ready;
    
    reg [AXI_DATA_WIDTH - 1:0] mmio_reg_tdata;
    reg [KEEP_WIDTH - 1:0] mmio_reg_tkeep;
    reg mmio_reg_tvalid;
    reg mmio_reg_tlast;
    reg mmio_reg_tuser;

    // DMA path signals
    wire [AXI_DATA_WIDTH-1:0] dma_fifo_in_tdata;
    wire [KEEP_WIDTH-1:0] dma_fifo_in_tkeep;
    wire dma_fifo_in_tvalid;
    wire dma_fifo_in_tready;
    wire dma_fifo_in_tlast;
    wire dma_fifo_in_tuser;

    wire [AXI_DATA_WIDTH-1:0] dma_fifo_out_tdata;
    wire [KEEP_WIDTH-1:0] dma_fifo_out_tkeep;
    wire dma_fifo_out_tvalid;
    wire dma_fifo_out_tready;
    wire dma_fifo_out_tlast;
    wire dma_fifo_out_tuser;

    wire [AXI_DATA_WIDTH-1:0] payload_to_dma_out_tdata;
    wire [KEEP_WIDTH-1:0] payload_to_dma_out_tkeep;
    wire payload_to_dma_out_tvalid;
    wire payload_to_dma_out_tready;
    wire payload_to_dma_out_tlast;
    wire payload_to_dma_out_tuser;

    wire dma_start;
    wire dma_direction;
    wire [63:0] dma_src_addr;
    wire [63:0] dma_dst_addr;
    wire [63:0] dma_len;
    wire dma_status;
    wire dma_status_valid;
    wire clear_dma_start;

    // State machine to track multi-beat transactions
    localparam IDLE = 2'd0;
    localparam MMIO_ACTIVE = 2'd1;
    localparam DMA_ACTIVE = 2'd2;

    reg [1:0] state, state_next;

    always @(posedge clk) begin
        if (rst)
            state <= IDLE;
        else
            state <= state_next;
    end

    // State transition logic
    always @(*) begin
        state_next = state;
        
        case (state)
            IDLE: begin
                if (txn_generator_in_tvalid) begin
                    if (dev_op == 8'd0 || dev_op == 8'd1)
                        state_next = MMIO_ACTIVE;
                    else if (dev_op == 8'd2)
                        state_next = DMA_ACTIVE;
                end
            end
            
            MMIO_ACTIVE: begin
                // MMIO is single beat, return to IDLE after accepting
                if (txn_generator_in_tvalid && txn_generator_in_tready)
                    state_next = IDLE;
            end
            
            DMA_ACTIVE: begin
                // DMA can be multi-beat, wait for tlast
                if (txn_generator_in_tvalid && txn_generator_in_tready && txn_generator_in_tlast)
                    state_next = IDLE;
            end
            
            default: state_next = IDLE;
        endcase
    end

    // Route to MMIO or DMA based on current state
    wire route_to_mmio = (state == IDLE && (dev_op == 8'd0 || dev_op == 8'd1)) || 
                         (state == MMIO_ACTIVE);
    wire route_to_dma = (state == IDLE && dev_op == 8'd2) || 
                        (state == DMA_ACTIVE);

    // MMIO path: Direct register (single beat only)
    wire mmio_can_accept = !mmio_reg_tvalid;
    
    always @(posedge clk) begin
        if (rst) begin
            mmio_reg_tdata <= {AXI_DATA_WIDTH{1'b0}};
            mmio_reg_tkeep <= {KEEP_WIDTH{1'b0}};
            mmio_reg_tvalid <= 1'b0;
            mmio_reg_tlast <= 1'b0;
            mmio_reg_tuser <= 1'b0;
        end else begin
            if (route_to_mmio && txn_generator_in_tvalid && mmio_can_accept) begin
                mmio_reg_tdata <= txn_generator_in_tdata;
                mmio_reg_tkeep <= txn_generator_in_tkeep;
                mmio_reg_tvalid <= 1'b1;
                mmio_reg_tlast <= txn_generator_in_tlast;
                mmio_reg_tuser <= txn_generator_in_tuser;
            end else if (mmio_ready && mmio_reg_tvalid) begin
                mmio_reg_tvalid <= 1'b0;
            end
        end
    end

    // DMA path: Through FIFO (can handle multi-beat transactions)
    assign dma_fifo_in_tdata = txn_generator_in_tdata;
    assign dma_fifo_in_tkeep = txn_generator_in_tkeep;
    assign dma_fifo_in_tvalid = route_to_dma && txn_generator_in_tvalid;
    assign dma_fifo_in_tlast = txn_generator_in_tlast;
    assign dma_fifo_in_tuser = txn_generator_in_tuser;

    // Input ready based on current routing
    assign txn_generator_in_tready = (route_to_mmio && mmio_can_accept) || 
                                      (route_to_dma && dma_fifo_in_tready);

    // DMA FIFO instantiation
    axis_fifo #(
        .DEPTH(256),
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .KEEP_ENABLE(1),
        .KEEP_WIDTH(KEEP_WIDTH),
        .LAST_ENABLE(1),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .USER_WIDTH(1),
        .FRAME_FIFO(0)
    ) dma_input_fifo (
        .clk(clk),
        .rst(rst),
        
        // Input from txn_generator_in
        .s_axis_tdata(dma_fifo_in_tdata),
        .s_axis_tkeep(dma_fifo_in_tkeep),
        .s_axis_tvalid(dma_fifo_in_tvalid),
        .s_axis_tready(dma_fifo_in_tready),
        .s_axis_tlast(dma_fifo_in_tlast),
        .s_axis_tid(8'd0),
        .s_axis_tdest(8'd0),
        .s_axis_tuser(dma_fifo_in_tuser),
        
        // Output to payload_to_dma
        .m_axis_tdata(dma_fifo_out_tdata),
        .m_axis_tkeep(dma_fifo_out_tkeep),
        .m_axis_tvalid(dma_fifo_out_tvalid),
        .m_axis_tready(dma_fifo_out_tready),
        .m_axis_tlast(dma_fifo_out_tlast),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(dma_fifo_out_tuser),
        
        .status_overflow(),
        .status_bad_frame(),
        .status_good_frame()
    );

    // MMIO module
    payload_to_mmio payload_to_mmio (
        .clk(clk),
        .rst(rst),
        .op_code(mmio_reg_tdata[OP_POS +: OP_WIDTH]),
        .address(mmio_reg_tdata[ADDR_POS +: ADDR_WIDTH]),
        .payload_data(mmio_reg_tdata[DATA_POS+: 64]),
        .payload_valid(mmio_reg_tvalid),
        .payload_ready(mmio_ready),
        .read_data(mmio_read_data),
        .read_data_valid(mmio_read_valid),
        .read_data_ready(txn_generator_out_tready & ~payload_to_dma_out_tvalid),
        .dma_start(dma_start),
        .dma_direction(dma_direction),
        .dma_src_addr(dma_src_addr),
        .dma_dst_addr(dma_dst_addr),
        .dma_len(dma_len),
        .dma_status(dma_status),
        .dma_status_valid(dma_status_valid),
        .computation_status(1'b0),
        .computation_status_valid(1'b0),
        .clear_dma_start(clear_dma_start)
    );

    // DMA module
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
        .payload_to_dma_in_tdata(dma_fifo_out_tdata),
        .payload_to_dma_in_tkeep(dma_fifo_out_tkeep),
        .payload_to_dma_in_tvalid(dma_fifo_out_tvalid),
        .payload_to_dma_in_tready(dma_fifo_out_tready),
        .payload_to_dma_in_tlast(dma_fifo_out_tlast),
        .payload_to_dma_in_tuser(dma_fifo_out_tuser),
        .payload_to_dma_out_tdata(payload_to_dma_out_tdata),
        .payload_to_dma_out_tkeep(payload_to_dma_out_tkeep),
        .payload_to_dma_out_tvalid(payload_to_dma_out_tvalid),
        .payload_to_dma_out_tready(payload_to_dma_out_tready),
        .payload_to_dma_out_tlast(payload_to_dma_out_tlast),
        .payload_to_dma_out_tuser(payload_to_dma_out_tuser)
    );

    // Output mux: MMIO takes priority
    assign txn_generator_out_tdata = mmio_read_valid ? {{(AXI_DATA_WIDTH-72){1'b0}}, mmio_read_data} : payload_to_dma_out_tdata;
    assign txn_generator_out_tkeep = mmio_read_valid ? {{(KEEP_WIDTH-9){1'b0}}, 9'h1FF} : payload_to_dma_out_tkeep;
    assign txn_generator_out_tvalid = mmio_read_valid | payload_to_dma_out_tvalid;
    assign txn_generator_out_tlast = mmio_read_valid ? 1'b1 : payload_to_dma_out_tlast;
    assign txn_generator_out_tuser = mmio_read_valid ? 1'b0 : payload_to_dma_out_tuser;

    assign payload_to_dma_out_tready = txn_generator_out_tready & ~mmio_read_valid;

endmodule