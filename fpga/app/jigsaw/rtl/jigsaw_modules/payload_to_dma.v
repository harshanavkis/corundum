module payload_to_dma #(
    parameter AXI_DATA_WIDTH = 512,
    parameter KEEP_WIDTH = AXI_DATA_WIDTH/8
)
(
    input wire clk,
    input wire rst,

    input wire dma_start,
    input wire dma_direction,
    input wire [63:0] dma_src_addr,
    input wire [63:0] dma_dst_addr,
    input wire [63:0] dma_len,
    output reg dma_status,
    output reg dma_status_valid,
    output reg clear_dma_start,

    input wire [AXI_DATA_WIDTH-1:0] payload_to_dma_in_tdata,
    input wire [KEEP_WIDTH-1:0] payload_to_dma_in_tkeep,
    input wire payload_to_dma_in_tvalid,
    output reg payload_to_dma_in_tready,
    input wire payload_to_dma_in_tlast,
    input wire payload_to_dma_in_tuser,

    output reg [AXI_DATA_WIDTH-1:0] payload_to_dma_out_tdata,
    output reg [KEEP_WIDTH-1:0] payload_to_dma_out_tkeep,
    output reg payload_to_dma_out_tvalid,
    input wire payload_to_dma_out_tready,
    output reg payload_to_dma_out_tlast,
    output reg payload_to_dma_out_tuser
);

    // IDLE: DMA engine is waiting for DMA commands
    localparam IDLE = 0;
    // CLEAR_DMA_REG: DMA engine is clearing the DMA register
    localparam CLEAR_DMA_REG = 1;
    // SEND_HEADER: DMA engine is sending a header with the request (rd/wr, address, length).
    localparam SEND_HEADER = 2;
    // SEND_PAYLOAD: DMA engine is sending payload data if it is a write request.
    localparam SEND_PAYLOAD = 3;

    reg [1:0] state;
    reg [1:0] next_state;

    always @(posedge clk)
    begin
        if (rst)
            state <= IDLE;
        else
            state <= next_state;
    end

    always @(*)
    begin
        next_state = IDLE;
        case (state)
            IDLE: 
                if (dma_start)
                    next_state = CLEAR_DMA_REG;
            CLEAR_DMA_REG: 
                next_state = IDLE;
            default: 
                next_state = IDLE;
        endcase
    end

    always_comb
    begin
       // Default values
       assign dma_status = 1'b0;
       assign dma_status_valid = 1'b0;
       assign clear_dma_start = 1'b0;
       assign payload_to_dma_out_tdata = {AXI_DATA_WIDTH{1'b0}};
       assign payload_to_dma_out_tkeep = {KEEP_WIDTH{1'b0}};
       assign payload_to_dma_out_tvalid = 1'b0;
       assign payload_to_dma_out_tlast = 1'b0;
       assign payload_to_dma_out_tuser = 1'b0;
       
       case (state)
            IDLE: begin
               // Do nothing 
            end 
                
            CLEAR_DMA_REG: begin
                assign clear_dma_start = 1'b1;
            end 
                
            default: begin
                // Do nothing
            end 
       endcase 
    end

endmodule
