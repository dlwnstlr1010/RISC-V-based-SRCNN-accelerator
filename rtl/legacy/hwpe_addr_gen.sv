// ============================================================
// hwpe_addr_gen.sv  —  3-Port Sliding Window Address Generator
//
// Window reuse: when moving to the next pixel in the same row,
// kc=0 ← old kc=1, kc=1 ← old kc=2, only kc=2 is read fresh.
//
//   First pixel of row (col=0):  full load   3/12 beats
//   Subsequent pixels (col>0):   shift + 1/4 beats (kc=2 only)
//
//   1ch:  row first = 6 clk,  rest = 1 beat × 2 = 2 clk
//   4ch:  row first = 24 clk, rest = 4 beats × 2 = 8 clk
//
// 3 TCDM ports read kr=0, kr=1, kr=2 in parallel per beat.
// ============================================================

module hwpe_addr_gen
#(
  parameter int IMG_W     = 150,
  parameter int IMG_H     = 150,
  parameter int KS        = 3,
  parameter int MAX_IN_CH = 4,
  parameter int N_PORTS   = 3
)
(
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        start_i,
  input  logic [31:0] in_base_addr_i,
  input  logic [2:0]  in_ch_i,

  // N_PORTS TCDM read ports (32-bit each)
  output logic [N_PORTS-1:0]        tcdm_req_o,
  output logic [N_PORTS-1:0][31:0]  tcdm_add_o,
  output logic [N_PORTS-1:0][3:0]   tcdm_be_o,
  output logic [N_PORTS-1:0]        tcdm_wen_o,
  input  logic [N_PORTS-1:0]        tcdm_gnt_i,
  input  logic [N_PORTS-1:0][31:0]  tcdm_r_rdata_i,
  input  logic [N_PORTS-1:0]        tcdm_r_valid_i,

  // Window output
  output logic signed [15:0] win_buf_o [MAX_IN_CH*KS*KS-1:0],
  output logic               win_valid_o,
  output logic [7:0]  out_row_o,
  output logic [7:0]  out_col_o,
  output logic        done_o
);

  localparam int K_MAX = MAX_IN_CH * KS * KS;  // 36

  // ── FSM ───────────────────────────────────────────────────────────────
  typedef enum logic [2:0] {
    S_IDLE, S_SHIFT, S_LOAD, S_WAIT, S_VALID, S_ADVANCE, S_DONE
  } state_e;
  state_e state_q, state_d;

  // ── Pixel counters ────────────────────────────────────────────────────
  logic [7:0] out_row_q, out_col_q;

  // ── Beat counters ─────────────────────────────────────────────────────
  logic [1:0] ch_q;       // 0 .. in_ch-1
  logic [1:0] kc_q;       // 0 .. 2  (used in full mode only)
  logic       slide_q;    // 0: full load (all kc),  1: slide (kc=2 only)

  // ── Window buffer ─────────────────────────────────────────────────────
  logic signed [15:0] win_buf_q [K_MAX-1:0];

  // ── kc selection ──────────────────────────────────────────────────────
  logic [1:0] kc_sel;
  assign kc_sel = slide_q ? 2'd2 : kc_q;

  // ── Per-port address / pad (p = kr) ───────────────────────────────────
  logic signed [8:0]  in_row_s [N_PORTS-1:0];
  logic signed [8:0]  in_col_s;
  logic [N_PORTS-1:0] is_pad_s;
  logic [31:0]        byte_addr_s [N_PORTS-1:0];
  logic [N_PORTS-1:0] addr_hi_s;
  logic [5:0]         flat_idx_s [N_PORTS-1:0];
  logic [N_PORTS-1:0] req_mask_s;

  always_comb begin
    in_col_s = $signed(9'(out_col_q)) + $signed(9'(kc_sel)) - 9'sd1;

    for (int p = 0; p < N_PORTS; p++) begin
      in_row_s[p] = $signed(9'(out_row_q)) + $signed(9'(p)) - 9'sd1;

      is_pad_s[p] = (in_row_s[p] < 9'sd0)
                   | (in_row_s[p] >= $signed(9'(IMG_H)))
                   | (in_col_s    < 9'sd0)
                   | (in_col_s    >= $signed(9'(IMG_W)));

      byte_addr_s[p] = in_base_addr_i
                      + 32'(ch_q)              * 32'(IMG_H * IMG_W * 2)
                      + 32'(in_row_s[p][7:0])  * 32'(IMG_W * 2)
                      + (32'(in_col_s[7:0])    << 1);

      addr_hi_s[p]  = byte_addr_s[p][1];
      flat_idx_s[p] = 6'(ch_q) * 6'd9 + 6'(p) * 6'd3 + 6'(kc_sel);

      tcdm_add_o[p] = {byte_addr_s[p][31:2], 2'b00};
      tcdm_be_o[p]  = addr_hi_s[p] ? 4'b1100 : 4'b0011;
      tcdm_wen_o[p] = 1'b1;  // read
    end

    req_mask_s = ~is_pad_s;
  end

  // ── Grant tracking ────────────────────────────────────────────────────
  logic [N_PORTS-1:0] gnt_done_q;
  logic [N_PORTS-1:0] gnt_this_s, gnt_all_s;
  logic               all_granted_s;

  assign gnt_this_s    = tcdm_gnt_i & tcdm_req_o;
  assign gnt_all_s     = gnt_done_q | gnt_this_s;
  assign all_granted_s = ((gnt_all_s & req_mask_s) == req_mask_s)
                       && (req_mask_s != '0);

  // ── Response tracking ─────────────────────────────────────────────────
  logic [N_PORTS-1:0] rvalid_done_q, rvalid_all_s;
  logic               all_rvalid_s;
  logic [N_PORTS-1:0] req_mask_q, addr_hi_q;
  logic [31:0]        rdata_buf_q [N_PORTS-1:0];

  assign rvalid_all_s = rvalid_done_q | tcdm_r_valid_i;
  assign all_rvalid_s = ((rvalid_all_s & req_mask_q) == req_mask_q);

  logic [31:0] rd_sel [N_PORTS-1:0];
  always_comb begin
    for (int p = 0; p < N_PORTS; p++)
      rd_sel[p] = rvalid_done_q[p] ? rdata_buf_q[p] : tcdm_r_rdata_i[p];
  end

  // ── Beat last ─────────────────────────────────────────────────────────
  logic beat_last_s;
  assign beat_last_s = (ch_q == 2'(in_ch_i - 1))
                     && (slide_q || kc_q == 2'd2);

  // ── Look-ahead ────────────────────────────────────────────────────────
  logic next_is_new_row, is_last_pixel;
  assign next_is_new_row = (out_col_q == 8'(IMG_W - 1));
  assign is_last_pixel   = (out_row_q == 8'(IMG_H - 1)) && next_is_new_row;

  // ── FSM combinatorial ─────────────────────────────────────────────────
  always_comb begin
    state_d     = state_q;
    win_valid_o = 1'b0;
    done_o      = 1'b0;
    tcdm_req_o  = '0;

    unique case (state_q)
      S_IDLE:
        if (start_i) state_d = S_LOAD;   // first pixel: full (slide_q=0)

      S_SHIFT:
        state_d = S_LOAD;                // shift done → load new kc=2

      S_LOAD: begin
        for (int p = 0; p < N_PORTS; p++)
          tcdm_req_o[p] = req_mask_s[p] & ~gnt_done_q[p];

        if (req_mask_s == '0)
          state_d = beat_last_s ? S_VALID : S_LOAD;
        else if (all_granted_s)
          state_d = S_WAIT;
      end

      S_WAIT:
        if (all_rvalid_s)
          state_d = beat_last_s ? S_VALID : S_LOAD;

      S_VALID: begin
        win_valid_o = 1'b1;
        state_d     = S_ADVANCE;
      end

      S_ADVANCE:
        state_d = is_last_pixel  ? S_DONE
                : next_is_new_row ? S_LOAD   // new row → full load
                : S_SHIFT;                    // same row → slide

      S_DONE:
        done_o = 1'b1;

      default:
        state_d = S_IDLE;
    endcase
  end

  // ── Beat counter advance signal ─────────────────────────────────────
  // Fires from S_LOAD (all-pad) or S_WAIT (all rvalid)
  logic do_advance_beat;

  // ── Sequential ────────────────────────────────────────────────────────
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= S_IDLE;
      out_row_q     <= '0;  out_col_q <= '0;
      ch_q          <= '0;  kc_q      <= '0;
      slide_q       <= 1'b0;
      gnt_done_q    <= '0;
      rvalid_done_q <= '0;
      req_mask_q    <= '0;
      addr_hi_q     <= '0;
      for (int p = 0; p < N_PORTS; p++) rdata_buf_q[p] <= '0;
      for (int i = 0; i < K_MAX; i++)   win_buf_q[i]   <= 16'sd0;
    end else begin
      state_q <= state_d;
      do_advance_beat = 1'b0;

      // ── S_SHIFT: slide window left by 1 column ────────────────
      if (state_q == S_SHIFT) begin
        for (int ch = 0; ch < MAX_IN_CH; ch++)
          for (int kr = 0; kr < KS; kr++) begin
            win_buf_q[ch*9 + kr*3 + 0] <= win_buf_q[ch*9 + kr*3 + 1];
            win_buf_q[ch*9 + kr*3 + 1] <= win_buf_q[ch*9 + kr*3 + 2];
            // kc=2 will be overwritten in S_LOAD/S_WAIT
          end
      end

      // ── S_LOAD ─────────────────────────────────────────────────
      if (state_q == S_LOAD) begin
        gnt_done_q <= (state_d == S_LOAD) ? gnt_all_s : '0;

        // All-padded beat: write zeros and advance
        if (req_mask_s == '0) begin
          for (int p = 0; p < N_PORTS; p++)
            win_buf_q[flat_idx_s[p]] <= 16'sd0;
          do_advance_beat = 1'b1;
        end

        if (state_d == S_WAIT) begin
          req_mask_q <= req_mask_s;
          addr_hi_q  <= addr_hi_s;
        end
      end else begin
        gnt_done_q <= '0;
      end

      // ── S_WAIT ─────────────────────────────────────────────────
      if (state_q == S_WAIT) begin
        for (int p = 0; p < N_PORTS; p++)
          if (tcdm_r_valid_i[p] && !rvalid_done_q[p])
            rdata_buf_q[p] <= tcdm_r_rdata_i[p];

        rvalid_done_q <= (state_d == S_WAIT) ? rvalid_all_s : '0;

        if (all_rvalid_s) begin
          for (int p = 0; p < N_PORTS; p++) begin
            if (req_mask_q[p])
              win_buf_q[flat_idx_s[p]] <= addr_hi_q[p]
                                          ? $signed(rd_sel[p][31:16])
                                          : $signed(rd_sel[p][15:0]);
            else
              win_buf_q[flat_idx_s[p]] <= 16'sd0;
          end
          do_advance_beat = 1'b1;
        end
      end else begin
        rvalid_done_q <= '0;
      end

      // ── Beat counter advance ───────────────────────────────────
      if (do_advance_beat && !beat_last_s) begin
        if (slide_q)
          ch_q <= ch_q + 2'd1;
        else if (kc_q == 2'd2) begin
          kc_q <= 2'd0;
          ch_q <= ch_q + 2'd1;
        end else
          kc_q <= kc_q + 2'd1;
      end

      // ── S_VALID: reset beat counters ───────────────────────────
      if (state_q == S_VALID) begin
        ch_q <= '0;
        kc_q <= '0;
      end

      // ── S_ADVANCE: advance pixel + set mode ───────────────────
      if (state_q == S_ADVANCE && !is_last_pixel) begin
        if (next_is_new_row) begin
          out_col_q <= 8'd0;
          out_row_q <= out_row_q + 8'd1;
          slide_q   <= 1'b0;   // full load for new row
        end else begin
          out_col_q <= out_col_q + 8'd1;
          slide_q   <= 1'b1;   // slide for same row
        end
      end
    end
  end

  // ── Outputs ───────────────────────────────────────────────────────────
  assign out_row_o = out_row_q;
  assign out_col_o = out_col_q;

  for (genvar i = 0; i < K_MAX; i++)
    assign win_buf_o[i] = win_buf_q[i];

endmodule
