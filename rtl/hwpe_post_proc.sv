// ============================================================
// hwpe_post_proc.sv — Post-Proc with AXI burst write (DDR3-direct)
//   2D register array for per-(channel, slot) storage.
//   Explicit channel mux for AXI write data.
// ============================================================

module hwpe_post_proc
#(
  parameter int FIXED_BITS     = 8,
  parameter int MAX_OUT_CH     = 4,
  parameter int AXI_ADDR_WIDTH = 32,
  parameter int AXI_DATA_WIDTH = 256
)
(
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic signed [31:0] acc_i     [MAX_OUT_CH-1:0],
  input  logic               mac_valid_i,
  input  logic [15:0]        pixel_idx_i,

  input  logic signed [15:0] bias_i    [MAX_OUT_CH-1:0],

  input  logic [31:0] out_base_addr_i,
  input  logic [2:0]  out_ch_i,
  input  logic [1:0]  layer_num_i,
  input  logic [15:0] total_pix_i,
  input  logic        mode_b_i,         // 0=Mode A (out_ch beats of 16pix), 1=Mode B (1ch × 4-beat burst of 64pix)

  output logic [AXI_ADDR_WIDTH-1:0]   axi_aw_addr_o,
  output logic [7:0]                  axi_aw_len_o,
  output logic [2:0]                  axi_aw_size_o,
  output logic [1:0]                  axi_aw_burst_o,
  output logic                        axi_aw_valid_o,
  input  logic                        axi_aw_ready_i,
  output logic [AXI_DATA_WIDTH-1:0]   axi_w_data_o,
  output logic [AXI_DATA_WIDTH/8-1:0] axi_w_strb_o,
  output logic                        axi_w_last_o,
  output logic                        axi_w_valid_o,
  input  logic                        axi_w_ready_i,
  input  logic [1:0]                  axi_b_resp_i,
  input  logic                        axi_b_valid_i,
  output logic                        axi_b_ready_o,

  output logic        write_done_o
);

  localparam int PIX_PER_BEAT = AXI_DATA_WIDTH / 16;  // 16

  // ── Post-processing combinational ──
  logic signed [31:0] v_arr       [MAX_OUT_CH-1:0];
  logic signed [15:0] result_comb [MAX_OUT_CH-1:0];

  always_comb begin
    for (int ch = 0; ch < MAX_OUT_CH; ch++) begin
      v_arr[ch] = (acc_i[ch] >>> FIXED_BITS) + $signed(bias_i[ch]);
      if (layer_num_i != 2'd3 && v_arr[ch] < 32'sd0) v_arr[ch] = 32'sd0;
      if (v_arr[ch] > 32'sd32767)  v_arr[ch] = 32'sd32767;
      if (v_arr[ch] < -32'sd32768) v_arr[ch] = -32'sd32768;
      result_comb[ch] = v_arr[ch][15:0];
    end
  end

  // ── Buffer: 4×16 slots reused across modes ──
  // Mode A: buf_q[channel][slot], 16 pixels per channel, out_ch channels.
  // Mode B: buf_q[beat_group][slot_in_beat], 4 beat_groups × 16 pixels = 64 pixels, 1 channel.
  //         Mode B fill: pixel index i (0..63) → buf_q[i[5:4]][i[3:0]].
  logic signed [15:0]        buf_q [MAX_OUT_CH-1:0][PIX_PER_BEAT-1:0];
  logic [6:0]                fill_cnt_q;         // 7-bit: 0..63 in Mode B, 0..15 in Mode A
  logic [15:0]               tile_base_pix_q;
  logic [2:0]                wr_ch_q;            // Mode A: current channel being written
  logic [1:0]                beat_cnt_q;         // Mode B: current beat (0..3) within 4-beat burst

  // ── FSM ──
  typedef enum logic [2:0] {
    PP_IDLE,
    PP_FILL,
    PP_AW,
    PP_W,
    PP_B,
    PP_DONE
  } pp_state_e;
  pp_state_e state_q, state_d;

  // ── Fill-count target differs per mode ──
  logic [6:0] fill_last;
  assign fill_last = mode_b_i ? 7'd63 : 7'd15;

  // ── AXI defaults ──
  // Mode A: 1-beat burst per channel, wr_ch selects channel stride.
  // Mode B: 4-beat INCR burst, starts at tile base (ch=0 only).
  logic [31:0] wr_addr;
  assign wr_addr = out_base_addr_i
                 + (mode_b_i ? 32'd0 : 32'(wr_ch_q) * 32'(total_pix_i) * 32'd2)
                 + (32'(tile_base_pix_q) << 1);

  assign axi_aw_size_o  = 3'b101;
  assign axi_aw_burst_o = 2'b01;
  assign axi_aw_len_o   = mode_b_i ? 8'd3 : 8'd0;   // Mode B: 4 beats, Mode A: 1 beat
  assign axi_aw_addr_o  = wr_addr;
  assign axi_w_strb_o   = {(AXI_DATA_WIDTH/8){1'b1}};
  assign axi_w_last_o   = mode_b_i ? (beat_cnt_q == 2'd3) : 1'b1;
  assign axi_b_ready_o  = 1'b1;

  // ── AXI write data mux ──
  // Mode A: select buf_q[wr_ch].
  // Mode B: select buf_q[beat_cnt] (beat_cnt is the beat-group index within the burst).
  logic [1:0] wdata_sel;
  assign wdata_sel = mode_b_i ? beat_cnt_q : wr_ch_q[1:0];
  always_comb begin
    axi_w_data_o = '0;
    for (int p = 0; p < PIX_PER_BEAT; p++) begin
      axi_w_data_o[p*16 +: 16] = buf_q[wdata_sel][p];
    end
  end

  // ── Next state ──
  always_comb begin
    state_d        = state_q;
    axi_aw_valid_o = 1'b0;
    axi_w_valid_o  = 1'b0;
    write_done_o   = 1'b0;

    unique case (state_q)
      PP_IDLE: if (mac_valid_i) state_d = PP_FILL;

      PP_FILL: begin
        if (fill_cnt_q == fill_last && mac_valid_i) state_d = PP_AW;
      end

      PP_AW: begin
        axi_aw_valid_o = 1'b1;
        if (axi_aw_ready_i) state_d = PP_W;
      end

      PP_W: begin
        axi_w_valid_o = 1'b1;
        if (axi_w_ready_i) begin
          if (mode_b_i) begin
            if (beat_cnt_q == 2'd3) state_d = PP_B;  // last beat of burst → wait B
            // else: stay in PP_W, send next beat
          end else begin
            state_d = PP_B;                          // Mode A: single beat → B
          end
        end
      end

      PP_B: if (axi_b_valid_i) begin
        if (mode_b_i) begin
          state_d = PP_DONE;                         // 1 burst covers whole tile in Mode B
        end else if ((wr_ch_q + 3'd1) >= 3'(out_ch_i)) begin
          state_d = PP_DONE;
        end else begin
          state_d = PP_AW;                           // next channel
        end
      end

      PP_DONE: begin
        write_done_o = 1'b1;
        state_d      = PP_IDLE;
      end

      default: state_d = PP_IDLE;
    endcase
  end

  // ── Sequential ──
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q         <= PP_IDLE;
      fill_cnt_q      <= '0;
      tile_base_pix_q <= '0;
      wr_ch_q         <= '0;
      beat_cnt_q      <= '0;
      for (int ch = 0; ch < MAX_OUT_CH; ch++)
        for (int p = 0; p < PIX_PER_BEAT; p++)
          buf_q[ch][p] <= '0;
    end else begin
      state_q <= state_d;

      // First-pixel entry: store at slot 0 (Mode A: all ch, Mode B: linear slot 0 = buf_q[0][0])
      if (state_q == PP_IDLE && mac_valid_i) begin
        tile_base_pix_q <= pixel_idx_i;
        wr_ch_q         <= 3'd0;
        beat_cnt_q      <= 2'd0;
        fill_cnt_q      <= 7'd1;
        if (mode_b_i) begin
          buf_q[0][0] <= result_comb[0];
        end else begin
          buf_q[0][0] <= result_comb[0];
          buf_q[1][0] <= result_comb[1];
          buf_q[2][0] <= result_comb[2];
          buf_q[3][0] <= result_comb[3];
        end
      end

      // Subsequent pixels in FILL state
      if (state_q == PP_FILL && mac_valid_i) begin
        if (mode_b_i) begin
          // Mode B: pixel index fill_cnt goes to buf[fill_cnt[5:4]][fill_cnt[3:0]]
          buf_q[fill_cnt_q[5:4]][fill_cnt_q[3:0]] <= result_comb[0];
        end else begin
          buf_q[0][fill_cnt_q[3:0]] <= result_comb[0];
          buf_q[1][fill_cnt_q[3:0]] <= result_comb[1];
          buf_q[2][fill_cnt_q[3:0]] <= result_comb[2];
          buf_q[3][fill_cnt_q[3:0]] <= result_comb[3];
        end
        if (fill_cnt_q != fill_last) fill_cnt_q <= fill_cnt_q + 7'd1;
      end

      // Mode A: advance channel on B receive
      if (!mode_b_i && state_q == PP_B && axi_b_valid_i) begin
        if ((wr_ch_q + 3'd1) >= 3'(out_ch_i)) wr_ch_q <= 3'd0;
        else                                    wr_ch_q <= wr_ch_q + 3'd1;
      end

      // Mode B: advance beat_cnt within PP_W on each accepted beat
      if (mode_b_i && state_q == PP_W && axi_w_ready_i) begin
        beat_cnt_q <= beat_cnt_q + 2'd1;
      end
    end
  end

endmodule
