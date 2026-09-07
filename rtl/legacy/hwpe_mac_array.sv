// ============================================================
// hwpe_mac_array.sv
// Sequential MAC Array for SRCNN HWPE (4 output channels × 36 DSPs)
//
// On win_valid_i: latches the window snapshot (so addr_gen can
// immediately start loading the next pixel), clears accumulators,
// then runs K = in_ch*9 MAC cycles in parallel for all out_ch.
// Asserts mac_valid_o for 1 cycle when done.
// ============================================================

module hwpe_mac_array
#(
  parameter int MAX_OUT_CH = 4,
  parameter int K_MAX      = 36   // MAX_IN_CH * KS * KS
)
(
  input  logic        clk_i,
  input  logic        rst_ni,

  // Window buffer from addr_gen (snapshot on win_valid_i)
  input  logic signed [15:0] win_buf_i [K_MAX-1:0],
  input  logic               win_valid_i,

  // Weights from weight_buf
  input  logic signed [15:0] weight_i [MAX_OUT_CH-1:0][K_MAX-1:0],

  // Configuration
  input  logic [2:0]  in_ch_i,
  input  logic [2:0]  out_ch_i,

  // Pixel location pass-through (for post_proc write address)
  input  logic [7:0]  out_row_i,
  input  logic [7:0]  out_col_i,
  output logic [7:0]  out_row_o,
  output logic [7:0]  out_col_o,

  // Accumulator output
  output logic signed [31:0] acc_o [MAX_OUT_CH-1:0],
  output logic               mac_valid_o   // 1-cycle pulse
);

  typedef enum logic [1:0] { S_IDLE, S_COMPUTE, S_OUTPUT } state_e;
  state_e state_q, state_d;

  logic [5:0] k_q;
  logic [5:0] k_total;
  assign k_total = {3'b0, in_ch_i} * 6'd9;   // in_ch * 9, max 36

  // Snapshot of window (latched on win_valid to free addr_gen immediately)
  logic signed [15:0] win_snap_q [K_MAX-1:0];

  // Accumulators: int32 sufficient for SRCNN weight/activation ranges
  logic signed [31:0] acc_q [MAX_OUT_CH-1:0];

  // Latched pixel location
  logic [7:0] row_q, col_q;

  // ── FSM ───────────────────────────────────────────────────────────────
  always_comb begin
    state_d     = state_q;
    mac_valid_o = 1'b0;
    unique case (state_q)
      S_IDLE:    if (win_valid_i) state_d = S_COMPUTE;
      S_COMPUTE: if (k_q == k_total - 1) state_d = S_OUTPUT;
      S_OUTPUT: begin
        mac_valid_o = 1'b1;
        state_d     = S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

  // ── Sequential ────────────────────────────────────────────────────────
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      k_q     <= '0;
      row_q   <= '0;  col_q <= '0;
      for (int i = 0; i < K_MAX; i++) win_snap_q[i] <= '0;
      for (int ch = 0; ch < MAX_OUT_CH; ch++) acc_q[ch] <= '0;
    end else begin
      state_q <= state_d;

      // Latch window snapshot and reset accumulators on win_valid
      if (state_q == S_IDLE && win_valid_i) begin
        for (int i = 0; i < K_MAX; i++) win_snap_q[i] <= win_buf_i[i];
        for (int ch = 0; ch < MAX_OUT_CH; ch++) acc_q[ch] <= '0;
        k_q   <= '0;
        row_q <= out_row_i;
        col_q <= out_col_i;
      end

      // Parallel MAC: all active output channels compute simultaneously
      if (state_q == S_COMPUTE) begin
        for (int ch = 0; ch < MAX_OUT_CH; ch++) begin
          if (3'(ch) < out_ch_i)
            acc_q[ch] <= acc_q[ch]
                       + $signed(win_snap_q[k_q]) * $signed(weight_i[ch][k_q]);
        end
        k_q <= k_q + 6'd1;
      end
    end
  end

  // ── Outputs ───────────────────────────────────────────────────────────
  assign out_row_o = row_q;
  assign out_col_o = col_q;

  for (genvar ch = 0; ch < MAX_OUT_CH; ch++)
    assign acc_o[ch] = acc_q[ch];

endmodule
