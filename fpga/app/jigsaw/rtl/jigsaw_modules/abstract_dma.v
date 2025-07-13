module abstract_dma#(
    parameter AXI_DATA_WIDTH = 512, // AXI data width
    parameter KEEP_WIDTH = AXI_DATA_WIDTH/8, // TKEEP width (one bit per byte)
    parameter ADDR_WIDTH = 64,
    parameter OP_WIDTH = 8,
    parameter REG_WIDTH = 64
)
(
    input wire clk,
    input wire rst,
    // MMIO request
    input wire mmio_req_valid, // Must go high for only one cycle
    input wire [OP_WIDTH -1: 0] mmio_req_rw, // 0: read, 1: write
    input wire [ADDR_WIDTH - 1:0] mmio_req_addr,
    input wire [REG_WIDTH - 1:0] mmio_req_data,
    output wire mmio_req_ready,
    // MMIO response
    output wire [REG_WIDTH - 1:0] mmio_rsp_data,
    output wire mmio_rsp_valid,
    output wire mmio_rsp_last,
    input wire mmio_rsp_ready,
    // DMA request
    output wire dma_req_valid,
    output wire dma_req_rw, // 0: read, 1: write
    output wire [KEEP_WIDTH-1:0] dma_req_len,
    output wire [ADDR_WIDTH-1:0] dma_req_addr,
    output wire [AXI_DATA_WIDTH-1:0] dma_req_data,
    input wire dma_req_ready,
    // DMA response
    input wire dma_rsp_valid,
    input wire [AXI_DATA_WIDTH-1:0] dma_rsp_data,
    output wire dma_rsp_ready
);

    // Internal registers
    reg [REG_WIDTH-1:0] reg0;
    reg [REG_WIDTH-1:0] reg1_dma_addr;
    reg [REG_WIDTH-1:0] reg2_dma_len;
    reg [REG_WIDTH-1:0] reg3_dma_start;
    reg [REG_WIDTH-1:0] reg4_comp_done;
    reg [REG_WIDTH-1:0] selected_reg;
    reg [REG_WIDTH-1:0] selected_reg_r;  // Registered version for response
    reg rsp_valid;
    reg rsp_last;

    // Always ready to accept requests
    assign mmio_req_ready = 1'b1;

    // Response valid when we have a valid request
    assign mmio_rsp_valid = rsp_valid;
    assign mmio_rsp_data = selected_reg_r;  // Use registered version
    assign mmio_rsp_last = rsp_last;

    wire [2:0] addr_selector;
    assign addr_selector = mmio_req_addr[5:3];

    // Register selection logic (combinational)
    always @(*) begin
        case (mmio_req_addr[5:3]) // Use bits [5:3] for register selection (8-byte aligned)
            3'b000: selected_reg = reg0; // Address 0x00
            3'b001: selected_reg = reg1_dma_addr; // Address 0x08
            3'b010: selected_reg = reg2_dma_len; // Address 0x10
            3'b011: selected_reg = reg3_dma_start; // Address 0x18
            3'b100: selected_reg = reg4_comp_done; // Address 0x20
            default: selected_reg = {REG_WIDTH{1'b0}};
        endcase
    end

    // Sequential logic for registers and response handling
    always @(posedge clk) begin
        if (rst) begin
            reg0 <= {REG_WIDTH{1'b0}};
            reg1_dma_addr <= {REG_WIDTH{1'b0}};  // Initialize with all 1s (flipped bits)
            reg2_dma_len <= {REG_WIDTH{1'b0}};
            reg3_dma_start <= {REG_WIDTH{1'b0}};
            reg4_comp_done <= {REG_WIDTH{1'b0}};
            selected_reg_r <= {REG_WIDTH{1'b0}};
            rsp_valid <= 1'b0;
            rsp_last <= 1'b0;
        end else begin
            // Response is only valid for read operations
            rsp_valid <= mmio_req_valid && (mmio_req_rw == 8'd0);
            rsp_last <= mmio_req_valid && (mmio_req_rw == 8'd0);
            
            // Register the selected data for read operations
            if (mmio_req_valid && (mmio_req_rw == 8'd0)) begin
                selected_reg_r <= selected_reg;
            end
            
            // Handle write operations
            if (mmio_req_valid && (mmio_req_rw == 8'd1)) begin
                case (mmio_req_addr[5:3]) // Use bits [5:3] for register selection (8-byte aligned)
                    3'b000: reg0 <= mmio_req_data; // Address 0x00
                    3'b001: reg1_dma_addr <= mmio_req_data; // Address 0x08
                    3'b010: reg2_dma_len <= mmio_req_data; // Address 0x10
                    3'b011: reg3_dma_start <= mmio_req_data; // Address 0x18
                    3'b100: reg4_comp_done <= mmio_req_data; // Address 0x20
                endcase
            end
        end
    end

endmodule