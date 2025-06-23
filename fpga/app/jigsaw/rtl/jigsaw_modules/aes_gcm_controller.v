module aes_gcm_controller (
    input  wire clk_i,
    input  wire rst_i,
    
    // Control inputs
    input  wire init_start_i,           // Start initialization sequence
    
    // AES-GCM module interface
    output reg aes_gcm_pipe_reset_o,
    output reg [3:0] aes_gcm_key_word_val_o,
    output reg aes_gcm_iv_val_o,
    output reg aes_gcm_icb_start_cnt_o,
    output reg [255:0] aes_gcm_key,
    output reg [95:0] aes_gcm_iv,
    
    // Status outputs
    output reg init_done_o,
    output reg init_busy_o
);

    // State definitions
    typedef enum logic [2:0] {
        IDLE        = 3'b000,
        PIPE_RESET  = 3'b001,
        LOAD_KEY    = 3'b010,
        LOAD_IV     = 3'b011,
        ICB_START   = 3'b100,
        WAIT_READY  = 3'b101,
        DONE        = 3'b110
    } state_t;
    
    state_t current_state, next_state;

    logic [13:0] pipe_reset_counter;
    
    // State machine sequential logic
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            current_state <= IDLE;
        end else begin
            current_state <= next_state;

            // // Count only in PIPE_RESET state
            // if (current_state == PIPE_RESET) begin
            //     if (pipe_reset_counter < 14'd9)
            //         pipe_reset_counter <= pipe_reset_counter + 1;
            // end else begin
            //     pipe_reset_counter <= 14'd0; // Reset when not in PIPE_RESET
            // end
        end
    end
    
    // State machine combinational logic
    always_comb begin
        // Default values
        next_state = current_state;
        
        case (current_state)
            IDLE: begin
                if (init_start_i) begin
                    next_state = PIPE_RESET;
                end
            end
            
            PIPE_RESET: begin
                // Assert pipe reset for one cycle
                // if (pipe_reset_counter == 14'd9)
                    next_state = LOAD_KEY;
                // else
                    // next_state = PIPE_RESET;
            end
            
            LOAD_KEY: begin
                // Load entire key in one cycle
                next_state = LOAD_IV;
            end
            
            LOAD_IV: begin
                // Load IV in one cycle
                next_state = ICB_START;
            end
            
            ICB_START: begin
                // Pulse ICB start count for one cycle
                next_state = WAIT_READY;
            end
            
            WAIT_READY: begin
                // Wait for AES-GCM module to signal ready
                // if (aes_gcm_ready_i==0) begin
                //     next_state = DONE;
                // end
                next_state = DONE;
            end
            
            DONE: begin
                // Stay in done state until next initialization
                if (init_start_i) begin
                    next_state = PIPE_RESET;
                end
            end
            
            default: begin
                next_state = IDLE;
            end
        endcase
    end
    
    // Output assignments
    always_comb begin
        // Default values
        aes_gcm_pipe_reset_o = 1'b0;
        aes_gcm_key_word_val_o = 4'b0000;
        aes_gcm_iv_val_o = 1'b0;
        aes_gcm_icb_start_cnt_o = 1'b0;
        init_done_o = 1'b0;
        init_busy_o = 1'b0;
        aes_gcm_key = 256'h0;
        aes_gcm_iv = 96'h0;
        
        case (current_state)
            IDLE: begin
                // All outputs at default values
            end
            
            PIPE_RESET: begin
                aes_gcm_pipe_reset_o = 1'b1;
                init_busy_o = 1'b1;
            end
            
            LOAD_KEY: begin
                // Load entire 256-bit key at once
                aes_gcm_key_word_val_o = 4'b1111; // All key word valid bits set
                aes_gcm_key = 256'h0;
                init_busy_o = 1'b1;
            end
            
            LOAD_IV: begin
                aes_gcm_iv_val_o = 1'b1;
                aes_gcm_iv = 96'h0;
                init_busy_o = 1'b1;
            end
            
            ICB_START: begin
                aes_gcm_icb_start_cnt_o = 1'b1;
                init_busy_o = 1'b1;
            end
            
            WAIT_READY: begin
                init_busy_o = 1'b1;
            end
            
            DONE: begin
                init_done_o = 1'b1;
            end
            
            default: begin
                // All outputs at default values
            end
        endcase
    end

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, aes_gcm_controller);
    end

endmodule