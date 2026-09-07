// ============================================================
// hwpe_axi_dma.sv — 128-bit AXI4 burst read DMA + BRAM double buffer
//
// Reads tile data from DDR3 via AXI burst, stores in internal
// BRAM double buffer. PE array reads from the "ready" buffer
// while DMA fills the other.
//
// AXI burst config: INCR, 16 beats × 128-bit = 256 bytes/burst
// ============================================================

module hwpe_axi_dma #(
  parameter int AXI_ADDR_WIDTH = 32,
  parameter int AXI_DATA_WIDTH = 256,
  parameter int AXI_ID_WIDTH   = 1,
  parameter int BRAM_DEPTH     = 1024  // words (256-bit) per buffer
)(
  input  logic                        clk_i,
  input  logic                        rst_ni,

  // ── Control interface (from fc_hwpe FSM) ──
  input  logic                        start_i,      // pulse to start DMA
  input  logic [31:0]                 src_addr_i,    // DDR3 byte address
  input  logic [15:0]                 num_words_i,   // total 32-bit words to transfer
  output logic                        done_o,        // DMA complete
  output logic                        buf_ready_o,   // read buffer has valid data
  output logic [2:0]                  dbg_state_o,   // debug: DMA FSM state

  // ── PE array read port (synchronous, partitioned into 4 banks) ──
  // rd_addr_i is the global beat index into the active buffer.
  // Mode A consumer uses rd_data_o[255:0]   (one bank at a time, auto-selected via rd_addr_i[1:0]).
  // Mode B consumer uses rd_data_wide_o     (all 4 banks in parallel, 1024-bit).
  input  logic [$clog2(BRAM_DEPTH)-1:0] rd_addr_i,
  output logic [AXI_DATA_WIDTH-1:0]     rd_data_o,
  output logic [4*AXI_DATA_WIDTH-1:0]   rd_data_wide_o,

  // ── AXI4 Master (read-only, 128-bit) ──
  // AR channel
  output logic [AXI_ID_WIDTH-1:0]     axi_ar_id_o,
  output logic [AXI_ADDR_WIDTH-1:0]   axi_ar_addr_o,
  output logic [7:0]                  axi_ar_len_o,
  output logic [2:0]                  axi_ar_size_o,
  output logic [1:0]                  axi_ar_burst_o,
  output logic                        axi_ar_lock_o,
  output logic [3:0]                  axi_ar_cache_o,
  output logic [2:0]                  axi_ar_prot_o,
  output logic [3:0]                  axi_ar_qos_o,
  output logic                        axi_ar_valid_o,
  input  logic                        axi_ar_ready_i,
  // R channel
  input  logic [AXI_ID_WIDTH-1:0]     axi_r_id_i,
  input  logic [AXI_DATA_WIDTH-1:0]   axi_r_data_i,
  input  logic [1:0]                  axi_r_resp_i,
  input  logic                        axi_r_last_i,
  input  logic                        axi_r_valid_i,
  output logic                        axi_r_ready_o,
  // AW/W/B channels (tied off — read-only DMA)
  output logic [AXI_ID_WIDTH-1:0]     axi_aw_id_o,
  output logic [AXI_ADDR_WIDTH-1:0]   axi_aw_addr_o,
  output logic [7:0]                  axi_aw_len_o,
  output logic [2:0]                  axi_aw_size_o,
  output logic [1:0]                  axi_aw_burst_o,
  output logic                        axi_aw_lock_o,
  output logic [3:0]                  axi_aw_cache_o,
  output logic [2:0]                  axi_aw_prot_o,
  output logic [3:0]                  axi_aw_qos_o,
  output logic                        axi_aw_valid_o,
  input  logic                        axi_aw_ready_i,
  output logic [AXI_DATA_WIDTH-1:0]   axi_w_data_o,
  output logic [AXI_DATA_WIDTH/8-1:0] axi_w_strb_o,
  output logic                        axi_w_last_o,
  output logic                        axi_w_valid_o,
  input  logic                        axi_w_ready_i,
  input  logic [AXI_ID_WIDTH-1:0]     axi_b_id_i,
  input  logic [1:0]                  axi_b_resp_i,
  input  logic                        axi_b_valid_i,
  output logic                        axi_b_ready_o
);

  // ── Tie off write channels ──────────────────────────────────
  assign axi_aw_id_o    = '0;
  assign axi_aw_addr_o  = '0;
  assign axi_aw_len_o   = '0;
  assign axi_aw_size_o  = '0;
  assign axi_aw_burst_o = '0;
  assign axi_aw_lock_o  = 1'b0;
  assign axi_aw_cache_o = '0;
  assign axi_aw_prot_o  = '0;
  assign axi_aw_qos_o   = '0;
  assign axi_aw_valid_o = 1'b0;
  assign axi_w_data_o   = '0;
  assign axi_w_strb_o   = '0;
  assign axi_w_last_o   = 1'b0;
  assign axi_w_valid_o  = 1'b0;
  assign axi_b_ready_o  = 1'b1;

  // ── Constants ───────────────────────────────────────────────
  // Each AXI beat = 128 bits = 16 bytes = 4 × 32-bit words
  // Burst of 16 beats = 256 bytes = 64 words
  localparam int BEAT_BYTES    = AXI_DATA_WIDTH / 8;  // 16
  localparam int WORDS_PER_BEAT = BEAT_BYTES / 4;      // 4
  localparam int BURST_LEN     = 16;                   // beats per burst (ar_len = 15)
  localparam int BURST_BYTES   = BURST_LEN * BEAT_BYTES; // 256

  // ── AR channel defaults ─────────────────────────────────────
  assign axi_ar_id_o    = '0;
  assign axi_ar_size_o  = 3'b101;  // 32 bytes per beat (256-bit)
  assign axi_ar_burst_o = 2'b01;   // INCR
  assign axi_ar_lock_o  = 1'b0;
  assign axi_ar_cache_o = 4'b0011; // bufferable, cacheable
  assign axi_ar_prot_o  = '0;
  assign axi_ar_qos_o   = '0;
  assign axi_ar_len_o   = 8'(BURST_LEN - 1); // 15

  // ── DMA state machine ──────────────────────────────────────
  typedef enum logic [2:0] {
    DMA_IDLE,
    DMA_AR,       // issue AR request
    DMA_R,        // receive R beats, write to BRAM
    DMA_DONE
  } dma_state_e;

  dma_state_e state_q, state_d;

  logic [31:0]                     cur_addr_q;     // current AXI read address
  logic [15:0]                     words_left_q;   // 32-bit words remaining
  logic [$clog2(BRAM_DEPTH)-1:0]  wr_ptr_q;       // BRAM write pointer
  logic [3:0]                      beat_cnt_q;     // beats received in current burst
  logic                            active_buf_q;   // which buffer is being written (0 or 1)

  // ── 4-bank partitioned double-buffer BRAM ──────────────────────
  // Global beat G → bank G%4, local_addr G/4. Same total storage as before
  // (4 banks × BRAM_DEPTH/4 entries = BRAM_DEPTH beats total per buffer),
  // just re-arranged. Mode A reads one bank; Mode B reads all 4 in parallel.
  localparam int NBANKS        = 4;
  localparam int BANK_DEPTH    = BRAM_DEPTH / NBANKS;    // beats per bank per buffer
  localparam int BANK_AW       = $clog2(BANK_DEPTH);     // local addr width (beats)
  localparam int BANK_BUF_AW   = BANK_AW + 1;            // incl. buffer sel bit

  logic [$clog2(BRAM_DEPTH)-1:0]  rd_addr_reg;           // latched read addr for output slice select

  (* ram_style = "block" *) logic [AXI_DATA_WIDTH-1:0] bram_bank0 [0:2*BANK_DEPTH-1];
  (* ram_style = "block" *) logic [AXI_DATA_WIDTH-1:0] bram_bank1 [0:2*BANK_DEPTH-1];
  (* ram_style = "block" *) logic [AXI_DATA_WIDTH-1:0] bram_bank2 [0:2*BANK_DEPTH-1];
  (* ram_style = "block" *) logic [AXI_DATA_WIDTH-1:0] bram_bank3 [0:2*BANK_DEPTH-1];

  // Write port: route beat wr_ptr_q to bank (wr_ptr_q[1:0]); local addr = wr_ptr_q[BANK_AW+1:2].
  // bram_wr_en / bram_wr_data are driven in the combinational block below (unchanged).
  logic                      bram_wr_en;
  logic [AXI_DATA_WIDTH-1:0] bram_wr_data;

  logic [BANK_BUF_AW-1:0] bank_wr_addr;
  logic [NBANKS-1:0]      bank_wr_en;

  assign bank_wr_addr = {active_buf_q, wr_ptr_q[$clog2(BRAM_DEPTH)-1:2]};

  always_comb begin
    bank_wr_en = '0;
    if (bram_wr_en) bank_wr_en[wr_ptr_q[1:0]] = 1'b1;
  end

  always_ff @(posedge clk_i) begin
    if (bank_wr_en[0]) bram_bank0[bank_wr_addr] <= bram_wr_data;
    if (bank_wr_en[1]) bram_bank1[bank_wr_addr] <= bram_wr_data;
    if (bank_wr_en[2]) bram_bank2[bank_wr_addr] <= bram_wr_data;
    if (bank_wr_en[3]) bram_bank3[bank_wr_addr] <= bram_wr_data;
  end

  // Read port: all 4 banks read at same local addr = rd_addr_i[BANK_AW+1:2].
  // rd_data_wide_o concatenates all 4 banks (Mode B consumes full 1024-bit).
  // rd_data_o presents the bank selected by rd_addr_reg[1:0] (Mode A 256-bit).
  logic [BANK_BUF_AW-1:0] bank_rd_addr;
  logic [AXI_DATA_WIDTH-1:0] bram_rd_bank [NBANKS];

  assign bank_rd_addr = {~active_buf_q, rd_addr_i[$clog2(BRAM_DEPTH)-1:2]};

  always_ff @(posedge clk_i) begin
    bram_rd_bank[0] <= bram_bank0[bank_rd_addr];
    bram_rd_bank[1] <= bram_bank1[bank_rd_addr];
    bram_rd_bank[2] <= bram_bank2[bank_rd_addr];
    bram_rd_bank[3] <= bram_bank3[bank_rd_addr];
    rd_addr_reg     <= rd_addr_i;
  end

  assign rd_data_wide_o = {bram_rd_bank[3], bram_rd_bank[2], bram_rd_bank[1], bram_rd_bank[0]};
  assign rd_data_o      = bram_rd_bank[rd_addr_reg[1:0]];

  // ── Combinational logic ────────────────────────────────────
  always_comb begin
    state_d        = state_q;
    axi_ar_addr_o  = cur_addr_q;
    axi_ar_valid_o = 1'b0;
    axi_r_ready_o  = 1'b0;
    bram_wr_en     = 1'b0;
    bram_wr_data   = axi_r_data_i;
    done_o         = 1'b0;

    unique case (state_q)
      DMA_IDLE: begin
        if (start_i && num_words_i != '0)
          state_d = DMA_AR;
      end

      DMA_AR: begin
        axi_ar_valid_o = 1'b1;
        axi_ar_addr_o  = cur_addr_q;
        // Adjust burst length for last burst
        if (words_left_q < BURST_LEN * WORDS_PER_BEAT)
          ; // keep ar_len at max, MIG handles short reads gracefully
        if (axi_ar_ready_i)
          state_d = DMA_R;
      end

      DMA_R: begin
        axi_r_ready_o = 1'b1;
        if (axi_r_valid_i) begin
          bram_wr_en   = 1'b1;
          bram_wr_data = axi_r_data_i;
          if (axi_r_last_i) begin
            if (words_left_q <= BURST_LEN * WORDS_PER_BEAT)
              state_d = DMA_DONE;
            else
              state_d = DMA_AR;  // issue next burst
          end
        end
      end

      DMA_DONE: begin
        done_o  = 1'b1;
        state_d = DMA_IDLE;
      end

      default: state_d = DMA_IDLE;
    endcase
  end

  // ── Sequential logic ───────────────────────────────────────
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= DMA_IDLE;
      cur_addr_q   <= '0;
      words_left_q <= '0;
      wr_ptr_q     <= '0;
      beat_cnt_q   <= '0;
      active_buf_q <= 1'b0;
    end else begin
      state_q <= state_d;

      unique case (state_q)
        DMA_IDLE: begin
          if (start_i && num_words_i != '0) begin
            cur_addr_q   <= src_addr_i;
            words_left_q <= num_words_i;
            wr_ptr_q     <= '0;
            beat_cnt_q   <= '0;
          end
        end

        DMA_AR: begin
          if (axi_ar_ready_i)
            beat_cnt_q <= '0;
        end

        DMA_R: begin
          if (axi_r_valid_i) begin
            wr_ptr_q   <= wr_ptr_q + 1;
            beat_cnt_q <= beat_cnt_q + 1;
            if (axi_r_last_i) begin
              cur_addr_q   <= cur_addr_q + BURST_BYTES;
              words_left_q <= (words_left_q > BURST_LEN * WORDS_PER_BEAT)
                            ? words_left_q - 16'(BURST_LEN * WORDS_PER_BEAT)
                            : '0;
            end
          end
        end

        DMA_DONE: begin
          active_buf_q <= ~active_buf_q;  // swap buffers
        end

        default: ;
      endcase
    end
  end

  // Buffer ready = DMA is not currently writing to the read buffer
  assign buf_ready_o = (state_q != DMA_R) || (state_q == DMA_IDLE);

  // Debug: expose FSM state
  assign dbg_state_o = state_q;

endmodule
