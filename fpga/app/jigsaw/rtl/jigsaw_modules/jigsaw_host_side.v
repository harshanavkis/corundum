module jigsaw_host_side #(
    parameter OP_WIDTH = 8,
    parameter ADDR_WIDTH = 64,
    parameter LEN_WIDTH = 64,
    parameter AXI_DATA_WIDTH = 512,
    parameter KEEP_WIDTH = AXI_DATA_WIDTH/8
) (
    input logic clk,
    input logic rst,
    
    // Network side interfaces: in represents data coming from the network
    input  logic [AXI_DATA_WIDTH - 1:0] network_in_tdata,
    input  logic [KEEP_WIDTH - 1:0] network_in_tkeep,
    input  logic network_in_tvalid,
    output logic network_in_tready,
    input  logic network_in_tlast,
    input  logic network_in_tuser,

    // Network side interfaces: out represents data going to the network
    output logic [AXI_DATA_WIDTH - 1:0] network_out_tdata,
    output logic [KEEP_WIDTH - 1:0] network_out_tkeep,
    output logic network_out_tvalid,
    input  logic network_out_tready,
    output logic network_out_tlast,
    output logic network_out_tuser,

    // Host side interfaces: in represents data coming from the host
    input  logic [AXI_DATA_WIDTH - 1:0] host_in_tdata,
    input  logic [KEEP_WIDTH - 1:0] host_in_tkeep,
    input  logic host_in_tvalid,
    output logic host_in_tready,
    input  logic host_in_tlast,
    input  logic host_in_tuser,

    // Host side interfaces: out represents data going to the host
    output logic [AXI_DATA_WIDTH - 1:0] host_out_tdata,
    output logic [KEEP_WIDTH - 1:0] host_out_tkeep,
    output logic host_out_tvalid,
    input  logic host_out_tready,
    output logic host_out_tlast,
    output logic host_out_tuser,

    // Submission queue interfaces
    output logic sq_valid,
    output logic sq_dir,
    output logic [63:0] sq_addr,
    output logic [63:0] sq_len,

    // Host side MMIO vaddr
    input logic [63:0] mmio_vaddr
);

assign host_in_tready = network_out_tready;
assign network_in_tready = host_out_tready;

localparam OP_POS = 0;
localparam ADDR_POS = OP_POS + OP_WIDTH;
localparam LEN_POS = ADDR_POS + ADDR_WIDTH;
localparam DATA_POS = LEN_POS + LEN_WIDTH;

// MMIO process


// DMA process
logic [1:0] dma_rd_state_cur, dma_rd_state_next;
logic [1:0] dma_wr_state_cur, dma_wr_state_next;

localparam DMA_IDLE = 2'b00;
localparam DMA_RD = 2'b01;
localparam DMA_WR = 2'b10;

// DMA Write process
always @(posedge clk) begin
    if (rst) begin
        dma_wr_state_cur <= DMA_IDLE;
    end else begin
        dma_wr_state_cur <= dma_wr_state_next;
    end
end

// TODO: Maybe add a FIFO between the network_in and host_out interfaces,
// since in simulation host_out_tready seems to go low after some time
// for a large amount of data
always @(*) begin
    dma_wr_state_next = dma_wr_state_cur;
    host_out_tvalid = 1'b0;
    host_out_tlast = 1'b0;
    host_out_tdata = network_in_tdata;
    host_out_tkeep = network_in_tkeep;
    host_out_tuser = network_in_tuser;
    
    sq_valid = 1'b0;
    sq_dir = 1'b0;
    sq_addr = 64'b0;
    sq_len = 64'b0;
    
    case (dma_wr_state_cur)
        DMA_IDLE: begin
            if (network_in_tvalid && host_out_tready) begin
                if (network_in_tdata[OP_POS +: OP_WIDTH] == 8'd1) begin
                    dma_wr_state_next = DMA_WR;
                    sq_valid = 1'b1;
                    sq_dir = 1'b1;
                    sq_addr = network_in_tdata[ADDR_POS +: ADDR_WIDTH];
                    sq_len = network_in_tdata[LEN_POS +: LEN_WIDTH];

                    host_out_tvalid = 1'b1;
                end
            end
        end
        DMA_WR: begin
            if (network_in_tvalid && host_out_tready) begin
                host_out_tvalid = 1'b1;
                if (network_in_tlast) begin
                    dma_wr_state_next = DMA_IDLE;
                    host_out_tlast = 1'b1;
                end
            end
        end
        default: ;
    endcase
end

// DMA Read process

endmodule