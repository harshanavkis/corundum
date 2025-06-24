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

    localparam AES_IDLE = 2'b00;
    localparam AES_INIT_START = 2'b01;
    localparam AES_INIT_STOP = 2'b10;

    reg [1:0] cur_state, next_state;

    reg init_start_i;
    wire aes_gcm_pipe_reset, aes_gcm_iv_val, aes_gcm_icb_start_cnt, init_done_o, init_busy_o;
    wire [3:0] aes_gcm_key_word_val;
    wire [255:0] aes_gcm_key;
    wire [95:0] aes_gcm_iv;
    wire [255:0] aes_gcm_val;
    wire aes_gcm_ready;

    always @ (posedge clk) begin
        // If reset is asserted, go back to IDLE state
        if (rst) begin
            cur_state <= AES_IDLE;

        // Else transition to the next state
        end else begin
            if (aes_out_tlast) begin
                cur_state <= AES_IDLE;
            end else begin
                cur_state <= next_state;
            end
        end
    end

    // Combinational always block for next state logic
    always @(*) begin
        // Default next state assignment
        next_state = AES_IDLE;
        init_start_i = 0;

        case (cur_state)
            AES_IDLE: begin
                    next_state = AES_INIT_START; // Transition to STATE_1 on input_signal
                end

            AES_INIT_START:  begin
                    next_state = AES_INIT_STOP; // Transition to STATE_2 if input_signal is low
                    init_start_i = 1;
                end

            default:  next_state = AES_INIT_STOP; // Fallback to default state
        endcase
    end

    aes_gcm_controller aes_gcm_ctrl (
        .clk_i(clk),
        .rst_i(rst),
        .init_start_i(init_start_i),
        .aes_gcm_pipe_reset_o(aes_gcm_pipe_reset),
        .aes_gcm_key_word_val_o(aes_gcm_key_word_val),
        .aes_gcm_iv_val_o(aes_gcm_iv_val),
        .aes_gcm_icb_start_cnt_o(aes_gcm_icb_start_cnt),
        .aes_gcm_key(aes_gcm_key),
        .aes_gcm_iv(aes_gcm_iv),
        .init_done_o(init_done_o),
        .init_busy_o(init_busy_o)
    );
    
    // wire [15:0] aes_gcm_data_in_bval = aes_in_tkeep;
    // wire [127:0] aes_gcm_data_in = aes_in_tdata;
    // wire aes_gcm_icb_stop_cnt = aes_in_tlast;
    wire aes_gcm_data_out_val;
    wire [15:0] aes_gcm_data_out_bval;
    wire [127:0] aes_gcm_data_out;
    wire aes_gcm_ghash_tag_val;
    wire [127:0] aes_gcm_ghash_tag;
    wire aes_gcm_icb_cnt_overflow;
    wire aes_gcm_ghash_pkt_val;
    wire [127:0] aes_gcm_data_in;
    wire [15:0] aes_gcm_data_in_bval;
    wire aes_gcm_icb_stop_cnt;

    wire [127:0] aes_in_tdata_be;
    wire [15:0] aes_in_tkeep_be;
    
    endian_swap le_to_be(
        .data_in(aes_in_tdata),
        .tkeep_in(aes_in_tkeep),
        .data_out(aes_in_tdata_be),
        .tkeep_out(aes_in_tkeep_be)
    );

    assign aes_gcm_data_in_bval = aes_in_tvalid ? aes_in_tkeep_be : 16'h0;
    assign aes_gcm_data_in = aes_in_tvalid ? aes_in_tdata_be : 128'h0;
    assign aes_gcm_icb_stop_cnt = aes_in_tvalid ? aes_in_tlast : 1'b0;

    assign aes_in_tready = (!init_busy_o) && aes_gcm_ready;

    assign aes_gcm_ghash_pkt_val = aes_in_tvalid;

    top_aes_gcm aes_gcm_core (
        .rst_i(aes_gcm_pipe_reset),
        .clk_i(clk),
        .aes_gcm_mode_i(2'b10),
        .aes_gcm_enc_dec_i(1'b0),
        .aes_gcm_pipe_reset_i(aes_gcm_pipe_reset),
        .aes_gcm_key_word_val_i(aes_gcm_key_word_val),
        .aes_gcm_key_word_i(aes_gcm_key),
        .aes_gcm_iv_val_i(aes_gcm_iv_val),
        .aes_gcm_iv_i(aes_gcm_iv),
        .aes_gcm_icb_start_cnt_i(aes_gcm_icb_start_cnt),
        .aes_gcm_icb_stop_cnt_i(aes_gcm_icb_stop_cnt),
        .aes_gcm_ghash_pkt_val_i(aes_gcm_ghash_pkt_val),
        .aes_gcm_ghash_aad_bval_i(16'h0),
        .aes_gcm_ghash_aad_i(128'h0),
        .aes_gcm_data_in_bval_i(aes_gcm_data_in_bval),
        .aes_gcm_data_in_i(aes_gcm_data_in),
        .aes_gcm_ready_o(aes_gcm_ready),
        .aes_gcm_data_out_val_o(aes_gcm_data_out_val),
        .aes_gcm_data_out_bval_o(aes_gcm_data_out_bval),
        .aes_gcm_data_out_o(aes_gcm_data_out),
        .aes_gcm_ghash_tag_val_o(aes_gcm_ghash_tag_val),
        .aes_gcm_ghash_tag_o(aes_gcm_ghash_tag),
        .aes_gcm_icb_cnt_overflow_o(aes_gcm_icb_cnt_overflow)
   );

   wire [127:0] aes_out_tdata_le;
   wire [15:0] aes_out_tkeep_le;
   
   endian_swap be_to_le(
       .data_in(aes_gcm_data_out),
       .tkeep_in(aes_gcm_data_out_bval),
       .data_out(aes_out_tdata_le),
       .tkeep_out(aes_out_tkeep_le)
   );

   wire [127:0] aes_gcm_ghash_tag_le;
   wire [15:0] aes_gcm_ghash_tkeep_le;

   endian_swap hash_be_to_le(
       .data_in(aes_gcm_ghash_tag),
       .tkeep_in(16'hFFFF),
       .data_out(aes_gcm_ghash_tag_le),
       .tkeep_out(aes_gcm_ghash_tkeep_le)
   );

   assign aes_out_tdata = aes_gcm_ghash_tag_val ? aes_gcm_ghash_tag_le : aes_out_tdata_le;
   assign aes_out_tkeep = aes_gcm_ghash_tag_val ? aes_gcm_ghash_tkeep_le : aes_out_tkeep_le;
   assign aes_out_tvalid = aes_gcm_ghash_tag_val ? aes_gcm_ghash_tag_val : aes_gcm_data_out_val;
   assign aes_out_tlast = aes_in_tvalid ? 1'b0 : (aes_gcm_ghash_tag_val ? 1'b1 : 1'b0);
        
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

    axis_adapter #(
        .S_DATA_WIDTH(128),
        .S_KEEP_ENABLE(1),
        .S_KEEP_WIDTH(16),
        .M_DATA_WIDTH(512),
        .M_KEEP_ENABLE(1),
        .M_KEEP_WIDTH(64),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
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
        .m_axis_tlast(m_axis_sync_tx_tlast),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(m_axis_sync_tx_tuser)
    );


endmodule