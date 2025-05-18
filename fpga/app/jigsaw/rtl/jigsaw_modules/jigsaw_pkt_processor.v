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

    // State machine states
    localparam STATE_IDLE = 2'b00;
    localparam STATE_FIRST_BEAT = 2'b01;
    localparam STATE_MIDDLE_BEAT = 2'b10;
    
    // State registers
    reg [1:0] current_state, next_state;
    
    // State machine transition logic
    always @(posedge clk) begin
        if (rst) begin
            current_state <= STATE_IDLE;
        end else begin
            current_state <= next_state;
        end
    end
    
    // Next state logic
    always @(*) begin
        next_state = current_state;
        
        case (current_state)
            STATE_IDLE: begin
                if (s_axis_sync_rx_tvalid && s_axis_sync_rx_tready) begin
                    next_state = s_axis_sync_rx_tlast ? STATE_IDLE : STATE_FIRST_BEAT;
                end
            end
            
            STATE_FIRST_BEAT, STATE_MIDDLE_BEAT: begin
                if (s_axis_sync_rx_tvalid && s_axis_sync_rx_tready) begin
                    if (s_axis_sync_rx_tlast)
                        next_state = STATE_IDLE;
                    else
                        next_state = STATE_MIDDLE_BEAT;
                end
            end
            
            default: next_state = STATE_IDLE;
        endcase
    end
    
    // Output data and keep signals based on state
    reg [AXI_DATA_WIDTH-1:0] tx_tdata_reg;
    reg [KEEP_WIDTH-1:0] tx_tkeep_reg;
    
    // Output generation logic
    always @(*) begin
        // Default assignments
        if (current_state == STATE_IDLE) begin
            // For first beat, extract only data portion after header
            tx_tdata_reg = {{(DATA_POS){1'b0}}, s_axis_sync_rx_tdata[AXI_DATA_WIDTH-1:DATA_POS]};
            tx_tkeep_reg = {{(KEEP_HEADER){1'b0}}, s_axis_sync_rx_tkeep[KEEP_WIDTH-1:KEEP_HEADER]};
        end else begin
            // For subsequent beats, pass through all data
            tx_tdata_reg = s_axis_sync_rx_tdata;
            tx_tkeep_reg = s_axis_sync_rx_tkeep;
        end
    end
    
    // Output assignments
    assign m_axis_sync_tx_tdata = tx_tdata_reg;
    assign m_axis_sync_tx_tkeep = tx_tkeep_reg;
    assign m_axis_sync_tx_tvalid = s_axis_sync_rx_tvalid;
    assign m_axis_sync_tx_tlast = s_axis_sync_rx_tlast;
    assign m_axis_sync_tx_tuser = s_axis_sync_rx_tuser;
    
    // Ready signal - we're ready to accept data if the downstream module is ready
    assign s_axis_sync_rx_tready = m_axis_sync_tx_tready;

endmodule