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

    // Internal signals for 128-bit AXI streams (AES-GCM native width)
    wire [127:0] aes_in_tdata;
    wire [15:0] aes_in_tkeep;
    wire aes_in_tvalid;
    wire aes_in_tready;
    wire aes_in_tlast;
    wire aes_in_tuser;

    wire [127:0] aes_out_tdata;
    wire [15:0] aes_out_tkeep;
    wire aes_out_tvalid;
    wire aes_out_tready;
    wire aes_out_tlast;
    wire aes_out_tuser;
    wire ghash_tag_val;

    reg pause_decrypted_transmit;
    wire tx_last;

    assign m_axis_sync_tx_tlast = tx_last;

    always @ (posedge clk) begin
        // If reset is asserted, go back to IDLE state
        if (rst) begin
            pause_decrypted_transmit <= 1'b1;

        // Else transition to the next state
        end else begin
            if (ghash_tag_val) begin
                pause_decrypted_transmit <= 1'b0;
            end

            if (!pause_decrypted_transmit && tx_last) begin
                pause_decrypted_transmit <= 1'b1;
            end
        end
    end
        
    // AXI Stream width adapter: 512-bit input to 128-bit for AES
    axis_adapter #(
        .S_DATA_WIDTH(512),
        .S_KEEP_ENABLE(1),
        .S_KEEP_WIDTH(64),
        .M_DATA_WIDTH(128),
        .M_KEEP_ENABLE(1),
        .M_KEEP_WIDTH(16),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .USER_WIDTH(1)
    ) input_adapter (
        .clk(clk),
        .rst(rst),
        
        // 512-bit input
        .s_axis_tdata(s_axis_sync_rx_tdata),
        .s_axis_tkeep(s_axis_sync_rx_tkeep),
        .s_axis_tvalid(s_axis_sync_rx_tvalid),
        .s_axis_tready(s_axis_sync_rx_tready),
        .s_axis_tlast(s_axis_sync_rx_tlast),
        .s_axis_tid(8'h0),
        .s_axis_tdest(8'h0),
        .s_axis_tuser(s_axis_sync_rx_tuser),
        
        // 128-bit output to AES
        .m_axis_tdata(aes_in_tdata),
        .m_axis_tkeep(aes_in_tkeep),
        .m_axis_tvalid(aes_in_tvalid),
        .m_axis_tready(aes_in_tready),
        .m_axis_tlast(aes_in_tlast),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(aes_in_tuser)
    );

    aes_gcm_encryption encr_module(
        .clk(clk),
        .rst(rst),
        .enc_dec(1'b1),
        .aes_in_tdata(aes_in_tdata),
        .aes_in_tkeep(aes_in_tkeep),
        .aes_in_tvalid(aes_in_tvalid),
        .aes_in_tready(aes_in_tready),
        .aes_in_tlast(aes_in_tlast),
        .aes_in_tuser(aes_in_tuser),
        .aes_out_tdata(aes_out_tdata),
        .aes_out_tkeep(aes_out_tkeep),
        .aes_out_tvalid(aes_out_tvalid),
        .aes_out_tready(aes_out_tready),
        .aes_out_tlast(aes_out_tlast),
        .aes_out_tuser(aes_out_tuser),
        .ghash_tag_val(ghash_tag_val)
    );

    axis_fifo_adapter #(
        .DEPTH(1024),
        .S_DATA_WIDTH(128),
        .S_KEEP_ENABLE(1),
        .S_KEEP_WIDTH(16),
        .M_DATA_WIDTH(512),
        .M_KEEP_ENABLE(1),
        .M_KEEP_WIDTH(64),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .PAUSE_ENABLE(1),
        .USER_WIDTH(1)
    ) output_adapter (
        .clk(clk),
        .rst(rst),
        
        // 128-bit input from AES
        .s_axis_tdata(aes_out_tdata),
        .s_axis_tkeep(aes_out_tkeep),
        .s_axis_tvalid(aes_out_tvalid),
        .s_axis_tready(aes_out_tready),
        .s_axis_tlast(aes_out_tlast),
        .s_axis_tid(8'h0),
        .s_axis_tdest(8'h0),
        .s_axis_tuser(1'h0),
        
        // 512-bit output
        .m_axis_tdata(m_axis_sync_tx_tdata),
        .m_axis_tkeep(m_axis_sync_tx_tkeep),
        .m_axis_tvalid(m_axis_sync_tx_tvalid),
        .m_axis_tready(m_axis_sync_tx_tready),
        .m_axis_tlast(tx_last),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(m_axis_sync_tx_tuser),

        .pause_req(pause_decrypted_transmit),
        .pause_ack(),
        .status_depth(),
        .status_depth_commit(),
        .status_overflow(),
        .status_bad_frame(),
        .status_good_frame()
    );


endmodule