// ============================================================
// hwpe_weight_buf.sv
// Weight/Bias Buffer for SRCNN HWPE
//
// On load_start_i: reads all weights (out_ch × in_ch×3×3) and
// biases (out_ch) from L2 BRAM via TCDM, stores in FF registers.
// Asserts load_done_o when complete (stays high until reset).
// ============================================================

module hwpe_weight_buf
#(
  parameter int MAX_OUT_CH = 4,
  parameter int K_MAX      = 144  // MAX_IN_CH(16) * KS(3) * KS(3)
)
(
  input  logic        clk_i,
  input  logic        rst_ni,

  // Configuration
  input  logic        load_start_i,
  input  logic [31:0] weight_base_addr_i,
  input  logic [31:0] bias_base_addr_i,
  input  logic [2:0]  out_ch_i,
  input  logic [4:0]  in_ch_i,       // up to 16

  // TCDM read port (32-bit, wen=1: read)
  output logic        tcdm_req_o,
  output logic [31:0] tcdm_add_o,
  output logic [3:0]  tcdm_be_o,
  output logic        tcdm_wen_o,
  input  logic        tcdm_gnt_i,
  input  logic [31:0] tcdm_r_rdata_i,
  input  logic        tcdm_r_valid_i,

  // Weight/bias outputs (valid after load_done_o)
  output logic signed [15:0] weight_o [MAX_OUT_CH-1:0][K_MAX-1:0],
  output logic signed [15:0] bias_o   [MAX_OUT_CH-1:0],
  output logic               load_done_o
);

  typedef enum logic [2:0] {
    S_IDLE, S_LOAD_W, S_WAIT_W, S_LOAD_B, S_WAIT_B, S_DONE
  } state_e;
  state_e state_q, state_d;

  logic [1:0] w_ch_q;
  logic [7:0] w_k_q;
  logic [1:0] b_ch_q;

  logic [7:0] k_size;
  assign k_size = {3'b0, in_ch_i} * 8'd9;  // in_ch * 9, max 144

  (* ram_style = "registers" *) logic signed [15:0] weight_q [MAX_OUT_CH-1:0][K_MAX-1:0];
  logic signed [15:0] bias_q   [MAX_OUT_CH-1:0];

  // ── Address generation ────────────────────────────────────────────────
  logic [31:0] w_byte_addr, b_byte_addr;
  logic        w_addr_hi, b_addr_hi;

  always_comb begin
    // weight[ch][k]: ch * k_size * 2 + k * 2 bytes from weight_base
    w_byte_addr = weight_base_addr_i
                + 32'(w_ch_q) * (32'(k_size) << 1)
                + (32'(w_k_q) << 1);
    w_addr_hi   = w_byte_addr[1];

    // bias[ch]: ch * 2 bytes from bias_base
    b_byte_addr = bias_base_addr_i + (32'(b_ch_q) << 1);
    b_addr_hi   = b_byte_addr[1];
  end

  // ── FSM ───────────────────────────────────────────────────────────────
  always_comb begin
    state_d     = state_q;
    tcdm_req_o  = 1'b0;
    tcdm_add_o  = '0;
    tcdm_be_o   = '0;
    tcdm_wen_o  = 1'b1;    // always read
    load_done_o = 1'b0;

    unique case (state_q)
      S_IDLE: if (load_start_i) state_d = S_LOAD_W;

      S_LOAD_W: begin
        tcdm_req_o = 1'b1;
        tcdm_add_o = {w_byte_addr[31:2], 2'b00};
        tcdm_be_o  = w_addr_hi ? 4'b1100 : 4'b0011;
        if (tcdm_gnt_i) state_d = S_WAIT_W;
      end

      S_WAIT_W: begin
        tcdm_add_o = {w_byte_addr[31:2], 2'b00};
        tcdm_be_o  = w_addr_hi ? 4'b1100 : 4'b0011;
        if (tcdm_r_valid_i)
          state_d = (w_ch_q == 2'(out_ch_i - 1) && w_k_q == k_size - 1)
                    ? S_LOAD_B : S_LOAD_W;
      end

      S_LOAD_B: begin
        tcdm_req_o = 1'b1;
        tcdm_add_o = {b_byte_addr[31:2], 2'b00};
        tcdm_be_o  = b_addr_hi ? 4'b1100 : 4'b0011;
        if (tcdm_gnt_i) state_d = S_WAIT_B;
      end

      S_WAIT_B: begin
        tcdm_add_o = {b_byte_addr[31:2], 2'b00};
        tcdm_be_o  = b_addr_hi ? 4'b1100 : 4'b0011;
        if (tcdm_r_valid_i)
          state_d = (b_ch_q == 2'(out_ch_i - 1)) ? S_DONE : S_LOAD_B;
      end

      S_DONE: begin
        load_done_o = 1'b1;
        state_d     = S_IDLE;  // auto-return for next layer reload
      end
      default: state_d = S_IDLE;
    endcase
  end

  // ── Sequential ────────────────────────────────────────────────────────
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      w_ch_q  <= '0;  w_k_q  <= '0;  b_ch_q <= '0;
      for (int ch = 0; ch < MAX_OUT_CH; ch++) begin
        bias_q[ch] <= '0;
        for (int k = 0; k < K_MAX; k++) weight_q[ch][k] <= '0;
      end
    end else begin
      state_q <= state_d;

      // Reset counters when starting a new load
      if (state_q == S_IDLE && load_start_i) begin
        w_ch_q <= '0;
        w_k_q  <= '0;
        b_ch_q <= '0;
      end

      if (state_q == S_WAIT_W && tcdm_r_valid_i) begin
        weight_q[w_ch_q][w_k_q] <= w_addr_hi
                                    ? $signed(tcdm_r_rdata_i[31:16])
                                    : $signed(tcdm_r_rdata_i[15:0]);
        if (!(w_ch_q == 2'(out_ch_i - 1) && w_k_q == k_size - 1)) begin
          if (w_k_q == k_size - 1) begin
            w_k_q  <= '0;
            w_ch_q <= w_ch_q + 2'd1;
          end else
            w_k_q <= w_k_q + 8'd1;
        end
      end

      if (state_q == S_WAIT_B && tcdm_r_valid_i) begin
        bias_q[b_ch_q] <= b_addr_hi
                          ? $signed(tcdm_r_rdata_i[31:16])
                          : $signed(tcdm_r_rdata_i[15:0]);
        if (b_ch_q != 2'(out_ch_i - 1))
          b_ch_q <= b_ch_q + 2'd1;
      end
    end
  end

  // ── Outputs ───────────────────────────────────────────────────────────
  for (genvar ch = 0; ch < MAX_OUT_CH; ch++) begin
    assign bias_o[ch] = bias_q[ch];
    for (genvar k = 0; k < K_MAX; k++)
      assign weight_o[ch][k] = weight_q[ch][k];
  end

endmodule
