module aes_gcm_decryption
(
    input  wire clk,
    input  wire rst,

    input wire  enc_dec,

    input  wire [127:0] aes_in_tdata,
    input  wire [15:0] aes_in_tkeep,
    input  wire aes_in_tvalid,
    output wire aes_in_tready,
    input  wire aes_in_tlast,
    input  wire aes_in_tuser,

    output wire [127:0] aes_out_tdata,
    output wire [15:0] aes_out_tkeep,
    output wire aes_out_tvalid,
    input  wire aes_out_tready,
    output wire aes_out_tlast,
    output wire aes_out_tuser,

    output wire ghash_tag_val
);

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

    reg tag_read;
    reg [127:0] input_gcm_tag;

    always @ (posedge clk) begin
        // If reset is asserted, go back to IDLE state
        if (rst) begin
            cur_state <= AES_IDLE;
            tag_read <= 1'b0;

        // Else transition to the next state
        end else begin
            if (aes_out_tlast) begin
                cur_state <= AES_IDLE;
                tag_read <= 1'b0;
            end else begin
                cur_state <= next_state;
            end

            if (aes_in_tvalid && !tag_read && aes_in_tready) begin // valid remains asserted until ready is high
                tag_read <= 1'b1;
                input_gcm_tag <= aes_in_tdata;
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
    
    endian_swap le_to_be(
        .data_in(aes_in_tdata),
        .tkeep_in(aes_in_tkeep),
        .data_out(aes_in_tdata_be),
        .tkeep_out(aes_in_tkeep_be)
    );

    // A beat is consumed by the core only when valid and ready are both high:
    // qualify everything presented to the core with tready so a stalled beat
    // is not consumed twice or paired with the wrong keystream block. The
    // first accepted beat of each packet is the received tag (tag_read low
    // at acceptance) and must not enter the core.
    wire aes_in_beat = aes_in_tvalid && aes_in_tready;
    wire aes_in_ct_beat = aes_in_beat && tag_read;

    assign aes_gcm_data_in_bval = aes_in_ct_beat ? aes_in_tkeep_be : 16'h0;
    assign aes_gcm_data_in = aes_in_ct_beat ? aes_in_tdata_be : 128'h0;
    assign aes_gcm_icb_stop_cnt = aes_in_ct_beat ? aes_in_tlast : 1'b0;

    // Hold off the next packet from the end of this packet's input until the
    // per-packet re-init (pipe flush + IV reload + counter restart) has
    // completed, so no data can pair with stale keystream left in the pipe
    reg pkt_gap;
    reg init_done_q;
    always @(posedge clk) begin
        if (rst) begin
            pkt_gap <= 1'b0;
            init_done_q <= 1'b0;
        end else begin
            init_done_q <= init_done_o;
            if (aes_in_ct_beat && aes_in_tlast) begin
                pkt_gap <= 1'b1;
            end else if (init_done_o && !init_done_q) begin
                pkt_gap <= 1'b0;
            end
        end
    end

    assign aes_in_tready = (!init_busy_o) && (!pkt_gap) && aes_gcm_ready;

    // Frame envelope for GHASH: high from the first to the last accepted
    // ciphertext beat, held through mid-packet stalls, and falling right
    // after tlast even if the next packet's tvalid is already asserted
    reg in_pkt;
    always @(posedge clk) begin
        if (rst) begin
            in_pkt <= 1'b0;
        end else if (aes_in_ct_beat) begin
            in_pkt <= !aes_in_tlast;
        end
    end

    assign aes_gcm_ghash_pkt_val = in_pkt || aes_in_ct_beat;

    top_aes_gcm aes_gcm_core (
        .rst_i(rst),
        .clk_i(clk),
        .aes_gcm_mode_i(2'b10),
        .aes_gcm_enc_dec_i(enc_dec),
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

   assign aes_out_tdata = aes_out_tdata_le;
   assign aes_out_tkeep = aes_out_tkeep_le;

   // TODO: Fix this as tlast and valid should fall down with last data block instead of tag
   assign aes_out_tvalid = aes_gcm_ghash_tag_val ? aes_gcm_ghash_tag_val : aes_gcm_data_out_val;
   assign aes_out_tlast = aes_gcm_ghash_tag_val;

   assign ghash_tag_val = aes_gcm_ghash_tag_val && (input_gcm_tag == aes_gcm_ghash_tag_le);
endmodule