// ============================================================
// hwpe_systolic_array.sv — Output-Stationary 4×16 Systolic Array
//
// - 4 rows (output channels) × 16 columns (pixels in parallel)
// - 64 PEs, each uses 1 DSP48 (int16 × int16 → int32 MAC)
// - Reads 256-bit (16 int16) per cycle from BRAM
// - Processes entire inner dimension (up to 36) then outputs
//
// Interface:
//   - start_i: pulse to begin processing a tile
//   - inner_dim_i: number of k steps (9 for L1, 36 for L2/L3)
//   - act_data_i: 16 activations per cycle from BRAM (256-bit)
//   - weight_i: preloaded weights from weight_buf [4][36]
//   - acc_o: 16 output values per channel when done
//   - done_o: pulse when tile processing complete
// ============================================================

module hwpe_systolic_array #(
  parameter int N_COLS    = 16,   // pixels processed in parallel (Mode A)
  parameter int N_ROWS    = 4,    // output channels (Cout) (Mode A)
  parameter int K_MAX     = 144   // max inner dimension (Cin × K², up to 16×9)
)(
  input  logic        clk_i,
  input  logic        rst_ni,

  // Control
  input  logic        start_i,        // pulse: begin tile processing
  input  logic [7:0]  inner_dim_i,    // k steps (9, 36, 72, 144)
  input  logic        mode_b_i,       // 0=Mode A (4ch×16pix), 1=Mode B (1ch×64pix, remap)
  output logic        busy_o,
  output logic        done_o,         // pulse: tile processing complete

  // Activation input from BRAM
  //   Mode A: act_data_i [256-bit = 16 × int16] → 1 BRAM beat per cycle
  //   Mode B: act_data_wide_i [1024-bit = 64 × int16] → 4 BRAM beats (4 banks) per cycle
  output logic [$clog2(K_MAX)-1:0] bram_rd_addr_o,
  input  logic [N_COLS*16-1:0]     act_data_i,
  input  logic [N_ROWS*N_COLS*16-1:0] act_data_wide_i,

  // Weights from weight_buf (preloaded, static during S_RUN). Mode B uses row 0 only.
  input  logic signed [15:0] weight_i [N_ROWS-1:0][K_MAX-1:0],

  // Output: 4ch × 16pix (Mode A) OR 1ch × 64pix packed into acc_o[r][c] where
  // Mode B linear index = r*N_COLS+c (rows interpreted as pixel groups of 16).
  output logic signed [31:0] acc_o    [N_ROWS-1:0][N_COLS-1:0],
  output logic               valid_o  [N_ROWS-1:0]
);

  // ── FSM ───────────────────────────────────────────────────────────────
  typedef enum logic [1:0] { S_IDLE, S_COMPUTE, S_OUTPUT } state_e;
  state_e state_q, state_d;

  logic [7:0] k_q;  // current inner dimension index (up to 144)

  // ── PE accumulators [row][col] ────────────────────────────────────────
  logic signed [31:0] acc_q [N_ROWS-1:0][N_COLS-1:0];

  // ── Extract individual activations ──────────────────────────────────
  // Mode A: 16 act from act_data_i (256-bit).
  // Mode B: 64 act from act_data_wide_i (1024-bit), indexed as [r*N_COLS+c].
  logic signed [15:0] act      [N_COLS-1:0];                    // Mode A
  logic signed [15:0] act_wide [N_ROWS-1:0][N_COLS-1:0];        // Mode B
  for (genvar c = 0; c < N_COLS; c++) begin : gen_act_unpack
    assign act[c] = $signed(act_data_i[c*16 +: 16]);
  end
  for (genvar r = 0; r < N_ROWS; r++) begin : gen_act_wide_r
    for (genvar c = 0; c < N_COLS; c++) begin : gen_act_wide_c
      assign act_wide[r][c] = $signed(act_data_wide_i[(r*N_COLS + c)*16 +: 16]);
    end
  end

  // ── BRAM read address (1 cycle ahead to compensate BRAM read latency) ─
  // BRAM has 1-cycle registered read. Issue addr for k=0 when start fires,
  // then k_q+1 during S_COMPUTE, so act_data_i aligns with weight[k_q].
  assign bram_rd_addr_o = (state_q == S_IDLE && start_i)
                        ? '0
                        : ($clog2(K_MAX))'(k_q + 8'd1);

  // ── FSM next state ───────────────────────────────────────────────────
  always_comb begin
    state_d = state_q;
    done_o  = 1'b0;

    unique case (state_q)
      S_IDLE:    if (start_i) state_d = S_COMPUTE;
      S_COMPUTE: if (k_q == inner_dim_i - 8'd1) state_d = S_OUTPUT;
      S_OUTPUT: begin
        done_o  = 1'b1;
        state_d = S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

  // ── Sequential: MAC + accumulate ─────────────────────────────────────
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      k_q     <= '0;
      for (int r = 0; r < N_ROWS; r++)
        for (int c = 0; c < N_COLS; c++)
          acc_q[r][c] <= '0;
    end else begin
      state_q <= state_d;

      unique case (state_q)
        S_IDLE: begin
          if (start_i) begin
            k_q <= '0;
            // Clear all accumulators
            for (int r = 0; r < N_ROWS; r++)
              for (int c = 0; c < N_COLS; c++)
                acc_q[r][c] <= '0;
          end
        end

        S_COMPUTE: begin
          // 64 MACs in parallel.
          //   Mode A: PE[r][c] = act[c]         * weight[r][k_q]
          //   Mode B: PE[r][c] = act_wide[r][c] * weight[0][k_q]  (all 64 PEs useful)
          for (int r = 0; r < N_ROWS; r++) begin
            for (int c = 0; c < N_COLS; c++) begin
              if (mode_b_i) begin
                acc_q[r][c] <= acc_q[r][c]
                             + $signed(act_wide[r][c]) * $signed(weight_i[0][k_q]);
              end else begin
                acc_q[r][c] <= acc_q[r][c]
                             + $signed(act[c]) * $signed(weight_i[r][k_q]);
              end
            end
          end
          k_q <= k_q + 8'd1;
        end

        S_OUTPUT: ;  // accumulators hold final values

        default: ;
      endcase
    end
  end

  // ── Outputs ──────────────────────────────────────────────────────────
  assign busy_o = (state_q != S_IDLE);

  for (genvar r = 0; r < N_ROWS; r++) begin : gen_out
    assign valid_o[r] = (state_q == S_OUTPUT);
    for (genvar c = 0; c < N_COLS; c++) begin : gen_out_col
      assign acc_o[r][c] = acc_q[r][c];
    end
  end

endmodule
