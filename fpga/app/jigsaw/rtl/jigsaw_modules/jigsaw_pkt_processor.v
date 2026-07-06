module jigsaw_pkt_processor #(
    parameter ID_WIDTH = 4,        // Width of ID field, parameterizable
    parameter OP_WIDTH = 4,        // Width of operation field
    parameter ADDR_WIDTH = 64,     // Width of address field
    parameter LEN_WIDTH = 16,      // Width of length field
    parameter AXI_DATA_WIDTH = 512,    // AXI data width
    parameter KEEP_WIDTH = AXI_DATA_WIDTH/8,  // TKEEP width (one bit per byte)
    parameter NUM_AES_ENGINES = 4  // Parallel AES-GCM engines per direction
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

    // Packets are striped over NUM_AES_ENGINES parallel AES-GCM engines per
    // direction: axis_demux dispatches frame k to engine k mod N and
    // axis_mux collects frames in the same rotation (both latch their
    // select input at frame boundaries; the select counters below advance
    // once per completed frame), so frame order is preserved without a
    // reorder buffer. Each engine sits between two FIFO width adapters:
    // the input FIFO lets the dispatcher hand off a whole frame at 512-bit
    // line rate and move on to the next engine (no head-of-line blocking on
    // the engine's 128-bit datapath or its per-packet re-init), and the
    // output FIFO holds the result until the collector's rotation reaches
    // that engine.

    localparam CL_ENG = (NUM_AES_ENGINES > 1) ? $clog2(NUM_AES_ENGINES) : 1;

    genvar n;

    // ---------------------------------------------------------------
    // Decryption path: rx -> RR demux -> N x (fifo 512->128 ->
    //   aes_gcm_decryption -> fifo 128->512, tag-gated) -> RR mux
    // ---------------------------------------------------------------

    wire [NUM_AES_ENGINES*AXI_DATA_WIDTH-1:0] dec_disp_tdata;
    wire [NUM_AES_ENGINES*KEEP_WIDTH-1:0] dec_disp_tkeep;
    wire [NUM_AES_ENGINES-1:0] dec_disp_tvalid;
    wire [NUM_AES_ENGINES-1:0] dec_disp_tready;
    wire [NUM_AES_ENGINES-1:0] dec_disp_tlast;
    wire [NUM_AES_ENGINES-1:0] dec_disp_tuser;

    // Round-robin dispatch: advance once per completed input frame
    reg [CL_ENG-1:0] dec_disp_sel;

    always @(posedge clk) begin
        if (rst) begin
            dec_disp_sel <= 0;
        end else if (s_axis_sync_rx_tvalid && s_axis_sync_rx_tready && s_axis_sync_rx_tlast) begin
            dec_disp_sel <= (dec_disp_sel == NUM_AES_ENGINES-1) ? 0 : dec_disp_sel + 1;
        end
    end

    axis_demux #(
        .M_COUNT(NUM_AES_ENGINES),
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .KEEP_ENABLE(1),
        .KEEP_WIDTH(KEEP_WIDTH),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .USER_WIDTH(1)
    ) dec_dispatch (
        .clk(clk),
        .rst(rst),
        .s_axis_tdata(s_axis_sync_rx_tdata),
        .s_axis_tkeep(s_axis_sync_rx_tkeep),
        .s_axis_tvalid(s_axis_sync_rx_tvalid),
        .s_axis_tready(s_axis_sync_rx_tready),
        .s_axis_tlast(s_axis_sync_rx_tlast),
        .s_axis_tid(8'h0),
        .s_axis_tdest({(8+CL_ENG){1'b0}}),
        .s_axis_tuser(s_axis_sync_rx_tuser),
        .m_axis_tdata(dec_disp_tdata),
        .m_axis_tkeep(dec_disp_tkeep),
        .m_axis_tvalid(dec_disp_tvalid),
        .m_axis_tready(dec_disp_tready),
        .m_axis_tlast(dec_disp_tlast),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(dec_disp_tuser),
        .enable(1'b1),
        .drop(1'b0),
        .select(dec_disp_sel)
    );

    wire [NUM_AES_ENGINES*AXI_DATA_WIDTH-1:0] dec_out_tdata;
    wire [NUM_AES_ENGINES*KEEP_WIDTH-1:0] dec_out_tkeep;
    wire [NUM_AES_ENGINES-1:0] dec_out_tvalid;
    wire [NUM_AES_ENGINES-1:0] dec_out_tready;
    wire [NUM_AES_ENGINES-1:0] dec_out_tlast;
    wire [NUM_AES_ENGINES-1:0] dec_out_tuser;

    generate
        for (n = 0; n < NUM_AES_ENGINES; n = n + 1) begin : dec_engine

            wire [127:0] eng_in_tdata;
            wire [15:0] eng_in_tkeep;
            wire eng_in_tvalid;
            wire eng_in_tready;
            wire eng_in_tlast;
            wire eng_in_tuser;

            axis_fifo_adapter #(
                .DEPTH(2048),
                .S_DATA_WIDTH(AXI_DATA_WIDTH),
                .S_KEEP_ENABLE(1),
                .S_KEEP_WIDTH(KEEP_WIDTH),
                .M_DATA_WIDTH(128),
                .M_KEEP_ENABLE(1),
                .M_KEEP_WIDTH(16),
                .ID_ENABLE(0),
                .DEST_ENABLE(0),
                .USER_ENABLE(1),
                .USER_WIDTH(1)
            ) dec_in_fifo (
                .clk(clk),
                .rst(rst),

                .s_axis_tdata(dec_disp_tdata[n*AXI_DATA_WIDTH +: AXI_DATA_WIDTH]),
                .s_axis_tkeep(dec_disp_tkeep[n*KEEP_WIDTH +: KEEP_WIDTH]),
                .s_axis_tvalid(dec_disp_tvalid[n]),
                .s_axis_tready(dec_disp_tready[n]),
                .s_axis_tlast(dec_disp_tlast[n]),
                .s_axis_tid(8'h0),
                .s_axis_tdest(8'h0),
                .s_axis_tuser(dec_disp_tuser[n]),

                .m_axis_tdata(eng_in_tdata),
                .m_axis_tkeep(eng_in_tkeep),
                .m_axis_tvalid(eng_in_tvalid),
                .m_axis_tready(eng_in_tready),
                .m_axis_tlast(eng_in_tlast),
                .m_axis_tid(),
                .m_axis_tdest(),
                .m_axis_tuser(eng_in_tuser),

                .pause_req(1'b0),
                .pause_ack(),
                .status_depth(),
                .status_depth_commit(),
                .status_overflow(),
                .status_bad_frame(),
                .status_good_frame()
            );

            wire [127:0] eng_out_tdata;
            wire [15:0] eng_out_tkeep;
            wire eng_out_tvalid;
            wire eng_out_tready;
            wire eng_out_tlast;
            wire eng_out_tuser;
            wire eng_tag_ok;

            // Engine n handles global RX frames n, n+N, n+2N, ...; with
            // IV = global frame index the striped engines jointly cover
            // the sender's per-packet IV sequence 0,1,2,...
            aes_gcm_decryption #(
                .IV_INIT(96'h0 + n),
                .IV_STRIDE(NUM_AES_ENGINES)
            ) decr_module (
                .clk(clk),
                .rst(rst),
                .enc_dec(1'b1),
                .aes_in_tdata(eng_in_tdata),
                .aes_in_tkeep(eng_in_tkeep),
                .aes_in_tvalid(eng_in_tvalid),
                .aes_in_tready(eng_in_tready),
                .aes_in_tlast(eng_in_tlast),
                .aes_in_tuser(eng_in_tuser),
                .aes_out_tdata(eng_out_tdata),
                .aes_out_tkeep(eng_out_tkeep),
                .aes_out_tvalid(eng_out_tvalid),
                .aes_out_tready(eng_out_tready),
                .aes_out_tlast(eng_out_tlast),
                .aes_out_tuser(eng_out_tuser),
                .ghash_tag_val(eng_tag_ok)
            );

            // Release decrypted frames only after their tag has verified:
            // one credit per verified frame, consumed as the frame leaves
            // the FIFO. credits == 0 pauses the FIFO output, which lands
            // exactly on a frame boundary. A frame whose tag never
            // verifies keeps its credit at zero and stays quarantined in
            // the FIFO (same policy as the previous single-engine pause).
            reg [3:0] tag_credits;
            wire dec_frame_out = dec_out_tvalid[n] && dec_out_tready[n] && dec_out_tlast[n];

            always @(posedge clk) begin
                if (rst) begin
                    tag_credits <= 4'd0;
                end else begin
                    case ({eng_tag_ok, dec_frame_out})
                        2'b10: tag_credits <= tag_credits + 4'd1;
                        2'b01: tag_credits <= tag_credits - 4'd1;
                        default: tag_credits <= tag_credits;
                    endcase
                end
            end

            // Frames are released only after tag verification (credits
            // below), so a whole frame is buffered here before the first
            // byte leaves: this FIFO bounds the maximum decryptable frame.
            // Sized 2 MiB (DEPTH is in bytes) to hold the engine's 1 MiB
            // per-packet ciphertext limit with margin; on a real FPGA this
            // is substantial block RAM per engine.
            axis_fifo_adapter #(
                .DEPTH(2097152),
                .S_DATA_WIDTH(128),
                .S_KEEP_ENABLE(1),
                .S_KEEP_WIDTH(16),
                .M_DATA_WIDTH(AXI_DATA_WIDTH),
                .M_KEEP_ENABLE(1),
                .M_KEEP_WIDTH(KEEP_WIDTH),
                .ID_ENABLE(0),
                .DEST_ENABLE(0),
                .USER_ENABLE(1),
                .PAUSE_ENABLE(1),
                .USER_WIDTH(1)
            ) dec_out_fifo (
                .clk(clk),
                .rst(rst),

                .s_axis_tdata(eng_out_tdata),
                .s_axis_tkeep(eng_out_tkeep),
                .s_axis_tvalid(eng_out_tvalid),
                .s_axis_tready(eng_out_tready),
                .s_axis_tlast(eng_out_tlast),
                .s_axis_tid(8'h0),
                .s_axis_tdest(8'h0),
                .s_axis_tuser(1'h0),

                .m_axis_tdata(dec_out_tdata[n*AXI_DATA_WIDTH +: AXI_DATA_WIDTH]),
                .m_axis_tkeep(dec_out_tkeep[n*KEEP_WIDTH +: KEEP_WIDTH]),
                .m_axis_tvalid(dec_out_tvalid[n]),
                .m_axis_tready(dec_out_tready[n]),
                .m_axis_tlast(dec_out_tlast[n]),
                .m_axis_tid(),
                .m_axis_tdest(),
                .m_axis_tuser(dec_out_tuser[n]),

                .pause_req(tag_credits == 4'd0),
                .pause_ack(),
                .status_depth(),
                .status_depth_commit(),
                .status_overflow(),
                .status_bad_frame(),
                .status_good_frame()
            );

        end
    endgenerate

    wire [AXI_DATA_WIDTH-1:0] decrypted_tdata;
    wire [KEEP_WIDTH-1:0] decrypted_tkeep;
    wire decrypted_tvalid;
    wire decrypted_tready;
    wire decrypted_tlast;
    wire decrypted_tuser;

    // In-order collect: advance once per completed output frame
    reg [CL_ENG-1:0] dec_col_sel;

    always @(posedge clk) begin
        if (rst) begin
            dec_col_sel <= 0;
        end else if (decrypted_tvalid && decrypted_tready && decrypted_tlast) begin
            dec_col_sel <= (dec_col_sel == NUM_AES_ENGINES-1) ? 0 : dec_col_sel + 1;
        end
    end

    axis_mux #(
        .S_COUNT(NUM_AES_ENGINES),
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .KEEP_ENABLE(1),
        .KEEP_WIDTH(KEEP_WIDTH),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .USER_WIDTH(1)
    ) dec_collect (
        .clk(clk),
        .rst(rst),
        .s_axis_tdata(dec_out_tdata),
        .s_axis_tkeep(dec_out_tkeep),
        .s_axis_tvalid(dec_out_tvalid),
        .s_axis_tready(dec_out_tready),
        .s_axis_tlast(dec_out_tlast),
        .s_axis_tid({(NUM_AES_ENGINES*8){1'b0}}),
        .s_axis_tdest({(NUM_AES_ENGINES*8){1'b0}}),
        .s_axis_tuser(dec_out_tuser),
        .m_axis_tdata(decrypted_tdata),
        .m_axis_tkeep(decrypted_tkeep),
        .m_axis_tvalid(decrypted_tvalid),
        .m_axis_tready(decrypted_tready),
        .m_axis_tlast(decrypted_tlast),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(decrypted_tuser),
        .enable(1'b1),
        .select(dec_col_sel)
    );

    // ---------------------------------------------------------------
    // Transaction generator (single instance, keeps frames in order)
    // ---------------------------------------------------------------

    wire [AXI_DATA_WIDTH-1:0] txn_generator_out_tdata;
    wire [KEEP_WIDTH-1:0] txn_generator_out_tkeep;
    wire txn_generator_out_tvalid;
    wire txn_generator_out_tready;
    wire txn_generator_out_tlast;
    wire txn_generator_out_tuser;

    txn_generator txner (
        .clk(clk),
        .rst(rst),
        .txn_generator_in_tdata(decrypted_tdata),
        .txn_generator_in_tkeep(decrypted_tkeep),
        .txn_generator_in_tvalid(decrypted_tvalid),
        .txn_generator_in_tready(decrypted_tready),
        .txn_generator_in_tlast(decrypted_tlast),
        .txn_generator_in_tuser(decrypted_tuser),
        .txn_generator_out_tdata(txn_generator_out_tdata),
        .txn_generator_out_tkeep(txn_generator_out_tkeep),
        .txn_generator_out_tvalid(txn_generator_out_tvalid),
        .txn_generator_out_tready(txn_generator_out_tready),
        .txn_generator_out_tlast(txn_generator_out_tlast),
        .txn_generator_out_tuser(txn_generator_out_tuser)
    );

    // ---------------------------------------------------------------
    // Encryption path: txn_generator -> RR demux -> N x (fifo 512->128
    //   -> aes_gcm_encryption -> fifo 128->512) -> RR mux -> tx
    // ---------------------------------------------------------------

    wire [NUM_AES_ENGINES*AXI_DATA_WIDTH-1:0] enc_disp_tdata;
    wire [NUM_AES_ENGINES*KEEP_WIDTH-1:0] enc_disp_tkeep;
    wire [NUM_AES_ENGINES-1:0] enc_disp_tvalid;
    wire [NUM_AES_ENGINES-1:0] enc_disp_tready;
    wire [NUM_AES_ENGINES-1:0] enc_disp_tlast;
    wire [NUM_AES_ENGINES-1:0] enc_disp_tuser;

    // Round-robin dispatch: advance once per completed input frame
    reg [CL_ENG-1:0] enc_disp_sel;

    always @(posedge clk) begin
        if (rst) begin
            enc_disp_sel <= 0;
        end else if (txn_generator_out_tvalid && txn_generator_out_tready && txn_generator_out_tlast) begin
            enc_disp_sel <= (enc_disp_sel == NUM_AES_ENGINES-1) ? 0 : enc_disp_sel + 1;
        end
    end

    axis_demux #(
        .M_COUNT(NUM_AES_ENGINES),
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .KEEP_ENABLE(1),
        .KEEP_WIDTH(KEEP_WIDTH),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .USER_WIDTH(1)
    ) enc_dispatch (
        .clk(clk),
        .rst(rst),
        .s_axis_tdata(txn_generator_out_tdata),
        .s_axis_tkeep(txn_generator_out_tkeep),
        .s_axis_tvalid(txn_generator_out_tvalid),
        .s_axis_tready(txn_generator_out_tready),
        .s_axis_tlast(txn_generator_out_tlast),
        .s_axis_tid(8'h0),
        .s_axis_tdest({(8+CL_ENG){1'b0}}),
        .s_axis_tuser(txn_generator_out_tuser),
        .m_axis_tdata(enc_disp_tdata),
        .m_axis_tkeep(enc_disp_tkeep),
        .m_axis_tvalid(enc_disp_tvalid),
        .m_axis_tready(enc_disp_tready),
        .m_axis_tlast(enc_disp_tlast),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(enc_disp_tuser),
        .enable(1'b1),
        .drop(1'b0),
        .select(enc_disp_sel)
    );

    wire [NUM_AES_ENGINES*AXI_DATA_WIDTH-1:0] enc_out_tdata;
    wire [NUM_AES_ENGINES*KEEP_WIDTH-1:0] enc_out_tkeep;
    wire [NUM_AES_ENGINES-1:0] enc_out_tvalid;
    wire [NUM_AES_ENGINES-1:0] enc_out_tready;
    wire [NUM_AES_ENGINES-1:0] enc_out_tlast;
    wire [NUM_AES_ENGINES-1:0] enc_out_tuser;

    generate
        for (n = 0; n < NUM_AES_ENGINES; n = n + 1) begin : enc_engine

            wire [127:0] eng_in_tdata;
            wire [15:0] eng_in_tkeep;
            wire eng_in_tvalid;
            wire eng_in_tready;
            wire eng_in_tlast;
            wire eng_in_tuser;

            axis_fifo_adapter #(
                .DEPTH(2048),
                .S_DATA_WIDTH(AXI_DATA_WIDTH),
                .S_KEEP_ENABLE(1),
                .S_KEEP_WIDTH(KEEP_WIDTH),
                .M_DATA_WIDTH(128),
                .M_KEEP_ENABLE(1),
                .M_KEEP_WIDTH(16),
                .ID_ENABLE(0),
                .DEST_ENABLE(0),
                .USER_ENABLE(1),
                .USER_WIDTH(1)
            ) enc_in_fifo (
                .clk(clk),
                .rst(rst),

                .s_axis_tdata(enc_disp_tdata[n*AXI_DATA_WIDTH +: AXI_DATA_WIDTH]),
                .s_axis_tkeep(enc_disp_tkeep[n*KEEP_WIDTH +: KEEP_WIDTH]),
                .s_axis_tvalid(enc_disp_tvalid[n]),
                .s_axis_tready(enc_disp_tready[n]),
                .s_axis_tlast(enc_disp_tlast[n]),
                .s_axis_tid(8'h0),
                .s_axis_tdest(8'h0),
                .s_axis_tuser(enc_disp_tuser[n]),

                .m_axis_tdata(eng_in_tdata),
                .m_axis_tkeep(eng_in_tkeep),
                .m_axis_tvalid(eng_in_tvalid),
                .m_axis_tready(eng_in_tready),
                .m_axis_tlast(eng_in_tlast),
                .m_axis_tid(),
                .m_axis_tdest(),
                .m_axis_tuser(eng_in_tuser),

                .pause_req(1'b0),
                .pause_ack(),
                .status_depth(),
                .status_depth_commit(),
                .status_overflow(),
                .status_bad_frame(),
                .status_good_frame()
            );

            wire [127:0] eng_out_tdata;
            wire [15:0] eng_out_tkeep;
            wire eng_out_tvalid;
            wire eng_out_tready;
            wire eng_out_tlast;
            wire eng_out_tuser;

            // TX IV space is disjoint from RX (MSB direction bit): GCM
            // forbids (key, IV) reuse, and both directions share the key
            aes_gcm_encryption #(
                .IV_INIT(96'h800000000000000000000000 + n),
                .IV_STRIDE(NUM_AES_ENGINES)
            ) encr_module (
                .clk(clk),
                .rst(rst),
                .enc_dec(1'b0),
                .aes_in_tdata(eng_in_tdata),
                .aes_in_tkeep(eng_in_tkeep),
                .aes_in_tvalid(eng_in_tvalid),
                .aes_in_tready(eng_in_tready),
                .aes_in_tlast(eng_in_tlast),
                .aes_in_tuser(eng_in_tuser),
                .aes_out_tdata(eng_out_tdata),
                .aes_out_tkeep(eng_out_tkeep),
                .aes_out_tvalid(eng_out_tvalid),
                .aes_out_tready(eng_out_tready),
                .aes_out_tlast(eng_out_tlast),
                .aes_out_tuser(eng_out_tuser)
            );

            // Output FIFO absorbs the engine's frame (the AES core does not
            // honour output backpressure) while the collector's rotation is
            // still on another engine
            axis_fifo_adapter #(
                .DEPTH(1024),
                .S_DATA_WIDTH(128),
                .S_KEEP_ENABLE(1),
                .S_KEEP_WIDTH(16),
                .M_DATA_WIDTH(AXI_DATA_WIDTH),
                .M_KEEP_ENABLE(1),
                .M_KEEP_WIDTH(KEEP_WIDTH),
                .ID_ENABLE(0),
                .DEST_ENABLE(0),
                .USER_ENABLE(1),
                .USER_WIDTH(1)
            ) enc_out_fifo (
                .clk(clk),
                .rst(rst),

                .s_axis_tdata(eng_out_tdata),
                .s_axis_tkeep(eng_out_tkeep),
                .s_axis_tvalid(eng_out_tvalid),
                .s_axis_tready(eng_out_tready),
                .s_axis_tlast(eng_out_tlast),
                .s_axis_tid(8'h0),
                .s_axis_tdest(8'h0),
                .s_axis_tuser(1'h0),

                .m_axis_tdata(enc_out_tdata[n*AXI_DATA_WIDTH +: AXI_DATA_WIDTH]),
                .m_axis_tkeep(enc_out_tkeep[n*KEEP_WIDTH +: KEEP_WIDTH]),
                .m_axis_tvalid(enc_out_tvalid[n]),
                .m_axis_tready(enc_out_tready[n]),
                .m_axis_tlast(enc_out_tlast[n]),
                .m_axis_tid(),
                .m_axis_tdest(),
                .m_axis_tuser(enc_out_tuser[n]),

                .pause_req(1'b0),
                .pause_ack(),
                .status_depth(),
                .status_depth_commit(),
                .status_overflow(),
                .status_bad_frame(),
                .status_good_frame()
            );

        end
    endgenerate

    // In-order collect: advance once per completed output frame
    reg [CL_ENG-1:0] enc_col_sel;

    always @(posedge clk) begin
        if (rst) begin
            enc_col_sel <= 0;
        end else if (m_axis_sync_tx_tvalid && m_axis_sync_tx_tready && m_axis_sync_tx_tlast) begin
            enc_col_sel <= (enc_col_sel == NUM_AES_ENGINES-1) ? 0 : enc_col_sel + 1;
        end
    end

    axis_mux #(
        .S_COUNT(NUM_AES_ENGINES),
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .KEEP_ENABLE(1),
        .KEEP_WIDTH(KEEP_WIDTH),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(1),
        .USER_WIDTH(1)
    ) enc_collect (
        .clk(clk),
        .rst(rst),
        .s_axis_tdata(enc_out_tdata),
        .s_axis_tkeep(enc_out_tkeep),
        .s_axis_tvalid(enc_out_tvalid),
        .s_axis_tready(enc_out_tready),
        .s_axis_tlast(enc_out_tlast),
        .s_axis_tid({(NUM_AES_ENGINES*8){1'b0}}),
        .s_axis_tdest({(NUM_AES_ENGINES*8){1'b0}}),
        .s_axis_tuser(enc_out_tuser),
        .m_axis_tdata(m_axis_sync_tx_tdata),
        .m_axis_tkeep(m_axis_sync_tx_tkeep),
        .m_axis_tvalid(m_axis_sync_tx_tvalid),
        .m_axis_tready(m_axis_sync_tx_tready),
        .m_axis_tlast(m_axis_sync_tx_tlast),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(m_axis_sync_tx_tuser),
        .enable(1'b1),
        .select(enc_col_sel)
    );

endmodule
