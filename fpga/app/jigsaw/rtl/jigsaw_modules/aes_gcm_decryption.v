module aes_gcm_decryption #(
    parameter [95:0] IV_INIT = 96'h0,
    parameter [95:0] IV_STRIDE = 96'h1
) (
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

    // Input frame = 16-byte received tag beat, then ciphertext beats.
    // The tag beat is stripped here and queued (the streaming engine can
    // hold several packets in flight); the engine emits plaintext beats
    // followed by its computed tag beat, which is converted into the
    // empty tlast beat downstream expects and compared against the
    // queued received tag to drive ghash_tag_val.

    reg expecting_tag;
    reg [127:0] rx_tag_mem [0:15];
    reg [4:0] rx_tag_wr, rx_tag_rd;
    wire [4:0] rx_tag_count = rx_tag_wr - rx_tag_rd;
    wire rx_tag_full = rx_tag_count >= 5'd15;

    wire eng_in_tready;

    // Received-tag beat is consumed here; ciphertext beats go to the engine
    assign aes_in_tready = expecting_tag ? !rx_tag_full : eng_in_tready;

    wire tag_beat = aes_in_tvalid && aes_in_tready && expecting_tag;
    wire ct_beat = aes_in_tvalid && aes_in_tready && !expecting_tag;

    always @(posedge clk) begin
        if (rst) begin
            expecting_tag <= 1'b1;
            rx_tag_wr <= 5'd0;
        end else begin
            if (tag_beat) begin
                rx_tag_mem[rx_tag_wr[3:0]] <= aes_in_tdata;
                rx_tag_wr <= rx_tag_wr + 1;
                expecting_tag <= 1'b0;
            end
            if (ct_beat && aes_in_tlast) begin
                expecting_tag <= 1'b1;
            end
        end
    end

    wire [127:0] aes_in_tdata_be;
    wire [15:0] aes_in_tkeep_be;

    endian_swap le_to_be(
        .data_in(aes_in_tdata),
        .tkeep_in(aes_in_tkeep),
        .data_out(aes_in_tdata_be),
        .tkeep_out(aes_in_tkeep_be)
    );

    wire [127:0] eng_out_tdata;
    wire [15:0] eng_out_tbval;
    wire eng_out_tvalid;
    wire eng_out_tlast;
    wire eng_out_is_tag;

    aes_gcm_stream #(
        .KEY(256'h0),
        .IV_INIT(IV_INIT),
        .IV_STRIDE(IV_STRIDE)
    ) engine (
        .clk(clk),
        .rst(rst),
        .enc_dec(enc_dec),
        .s_tdata(aes_in_tdata_be),
        .s_tbval(aes_in_tkeep_be),
        .s_tvalid(aes_in_tvalid && !expecting_tag),
        .s_tready(eng_in_tready),
        .s_tlast(aes_in_tlast),
        .m_tdata(eng_out_tdata),
        .m_tbval(eng_out_tbval),
        .m_tvalid(eng_out_tvalid),
        .m_tready(aes_out_tready),
        .m_tlast(eng_out_tlast),
        .m_is_tag(eng_out_is_tag)
    );

    wire [127:0] eng_out_tdata_le;
    wire [15:0] eng_out_tkeep_le;

    endian_swap be_to_le(
        .data_in(eng_out_tdata),
        .tkeep_in(eng_out_tbval),
        .data_out(eng_out_tdata_le),
        .tkeep_out(eng_out_tkeep_le)
    );

    // Tag beat leaves as the empty tlast beat downstream expects
    assign aes_out_tdata = eng_out_tdata_le;
    assign aes_out_tkeep = eng_out_is_tag ? 16'h0 : eng_out_tkeep_le;
    assign aes_out_tvalid = eng_out_tvalid;
    assign aes_out_tlast = eng_out_tlast;
    assign aes_out_tuser = 1'b0;

    wire tag_out_fire = eng_out_tvalid && aes_out_tready && eng_out_is_tag;

    always @(posedge clk) begin
        if (rst) begin
            rx_tag_rd <= 5'd0;
        end else if (tag_out_fire) begin
            rx_tag_rd <= rx_tag_rd + 1;
        end
    end

    assign ghash_tag_val = tag_out_fire && (eng_out_tdata_le == rx_tag_mem[rx_tag_rd[3:0]]);

endmodule
