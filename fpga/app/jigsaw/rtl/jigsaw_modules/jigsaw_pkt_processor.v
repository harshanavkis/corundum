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

    // FIFO parameters
    localparam FIFO_DEPTH = 128; // Adjust based on your requirements
    localparam FIFO_ADDR_WIDTH = $clog2(FIFO_DEPTH);

    // Simplified state machine states - reduced to two states
    localparam STATE_IDLE = 1'b0;
    localparam STATE_ACTIVE = 1'b1;

    // State registers
    reg current_state, next_state;
    reg receiving_mode;
    reg transmitting_mode;

    // FIFO storage
    reg [AXI_DATA_WIDTH-1:0] fifo_data [0:FIFO_DEPTH-1];
    reg [KEEP_WIDTH-1:0] fifo_keep [0:FIFO_DEPTH-1];
    reg [FIFO_DEPTH-1:0] fifo_last;
    reg [FIFO_DEPTH-1:0] fifo_user;
    reg [FIFO_ADDR_WIDTH-1:0] write_ptr, read_ptr;
    reg [FIFO_ADDR_WIDTH:0] fifo_count; // Extra bit for full detection
    reg first_beat;
    reg packet_complete;

    // Output data and keep signals
    reg [AXI_DATA_WIDTH-1:0] tx_tdata_reg;
    reg [KEEP_WIDTH-1:0] tx_tkeep_reg;
    reg tx_tlast_reg;
    reg tx_tvalid_reg;
    reg tx_tuser_reg;

    // State machine transition logic
    always @(posedge clk) begin
        if (rst) begin
            current_state <= STATE_IDLE;
            receiving_mode <= 1'b0;
            transmitting_mode <= 1'b0;
            write_ptr <= 0;
            read_ptr <= 0;
            fifo_count <= 0;
            first_beat <= 1'b1;
            packet_complete <= 1'b0;
        end else begin
            current_state <= next_state;
            
            // FIFO write logic
            if ((current_state == STATE_IDLE || (current_state == STATE_ACTIVE && receiving_mode)) && 
                s_axis_sync_rx_tvalid && s_axis_sync_rx_tready) begin
                
                if (first_beat) begin
                    // For first beat, store only data portion after header
                    fifo_data[write_ptr] <= {{(DATA_POS){1'b0}}, s_axis_sync_rx_tdata[AXI_DATA_WIDTH-1:DATA_POS]};
                    fifo_keep[write_ptr] <= {{(KEEP_HEADER){1'b0}}, s_axis_sync_rx_tkeep[KEEP_WIDTH-1:KEEP_HEADER]};
                    first_beat <= 1'b0;
                end else begin
                    // For subsequent beats, store all data
                    fifo_data[write_ptr] <= s_axis_sync_rx_tdata;
                    fifo_keep[write_ptr] <= s_axis_sync_rx_tkeep;
                end
                
                fifo_last[write_ptr] <= s_axis_sync_rx_tlast;
                fifo_user[write_ptr] <= s_axis_sync_rx_tuser;
                write_ptr <= (write_ptr + 1) % FIFO_DEPTH; // Wrap around
                fifo_count <= fifo_count + 1;
                
                if (s_axis_sync_rx_tlast) begin
                    packet_complete <= 1'b1;
                    receiving_mode <= 1'b0;
                    transmitting_mode <= 1'b1;
                end
            end
            
            // FIFO read logic
            if ((current_state == STATE_ACTIVE && transmitting_mode) && 
                m_axis_sync_tx_tready && tx_tvalid_reg) begin
                
                read_ptr <= (read_ptr + 1) % FIFO_DEPTH; // Wrap around
                fifo_count <= fifo_count - 1;
                
                if (tx_tlast_reg && fifo_count == 1) begin
                    first_beat <= 1'b1; // Reset for next packet
                    packet_complete <= 1'b0;
                    transmitting_mode <= 1'b0;
                end
            end
        end
    end

    // Next state logic - simplified to two states
    always @(*) begin
        next_state = current_state;
        
        case (current_state)
            STATE_IDLE: begin
                if (s_axis_sync_rx_tvalid) begin
                    next_state = STATE_ACTIVE;
                    receiving_mode = 1'b1;
                end
            end
            
            STATE_ACTIVE: begin
                if (!receiving_mode && !transmitting_mode) begin
                    next_state = STATE_IDLE;
                end
            end
            
            default: next_state = STATE_IDLE;
        endcase
    end

    // Output generation logic
    always @(*) begin
        // Default assignments
        tx_tvalid_reg = 1'b0;
        tx_tdata_reg = {AXI_DATA_WIDTH{1'b0}};
        tx_tkeep_reg = {KEEP_WIDTH{1'b0}};
        tx_tlast_reg = 1'b0;
        tx_tuser_reg = 1'b0;
        
        if (current_state == STATE_ACTIVE && transmitting_mode && fifo_count > 0) begin
            tx_tvalid_reg = 1'b1;
            tx_tdata_reg = fifo_data[read_ptr];
            tx_tkeep_reg = fifo_keep[read_ptr];
            tx_tlast_reg = fifo_last[read_ptr];
            tx_tuser_reg = fifo_user[read_ptr];
        end
    end

    // Ready signal - we're ready to accept data if we're in IDLE or ACTIVE receiving mode and FIFO isn't full
    assign s_axis_sync_rx_tready = (current_state == STATE_IDLE || 
                                (current_state == STATE_ACTIVE && receiving_mode && !packet_complete)) && 
                                (fifo_count < FIFO_DEPTH);

    // Output assignments
    assign m_axis_sync_tx_tdata = tx_tdata_reg;
    assign m_axis_sync_tx_tkeep = tx_tkeep_reg;
    assign m_axis_sync_tx_tvalid = tx_tvalid_reg;
    assign m_axis_sync_tx_tlast = tx_tlast_reg;
    assign m_axis_sync_tx_tuser = tx_tuser_reg;

endmodule