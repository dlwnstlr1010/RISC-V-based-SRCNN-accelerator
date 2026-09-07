// ============================================================
// hwpe_im2col.sv — Hardware im2col Engine (DDR3-direct version)
//   Line Buffer (4 replicas, 256-bit wide) + 4-way parallel read
//   + AXI burst read (input from DDR3) + AXI burst write (output)
//
// Phase 1 (LOAD) : AXI 256-bit burst read from DDR3. 16 pixels/beat
//                  written into 4 replicated wide line buffers.
// Phase 2 (COMP) : 4 parallel reads/cycle (each lane extracts pixel
//                  from its replica's 256-bit word). 5 cycles per
//                  16-pixel beat output.
// Phase 3 (AXI W): INCR burst write (up to 16 beats) for im2col matrix.
// ============================================================

module hwpe_im2col #(
  parameter int AXI_ADDR_WIDTH = 32,
  parameter int AXI_DATA_WIDTH = 256,
  parameter int MAX_IN_CH      = 16,
  parameter int MAX_BATCH_ROWS = 16,
  parameter int MAX_IMG_W      = 256,
  parameter int MAX_BURST      = 16
)(
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        start_i,
  output logic        done_o,

  input  logic [31:0] in_base_addr_i,   // DDR3 base address for input
  input  logic [15:0] in_ch_stride_i,   // pixels per channel (total_pix)
  input  logic [4:0]  in_ch_i,          // up to 16
  input  logic [7:0]  img_w_i,
  input  logic [7:0]  img_h_i,
  input  logic [31:0] ddr_dest_addr_i,  // DDR3 dest for im2col matrix
  input  logic [15:0] batch_start_i,
  input  logic [15:0] batch_pix_i,

  // ── AXI4 read (input from DDR3) ──
  output logic [AXI_ADDR_WIDTH-1:0]   axi_ar_addr_o,
  output logic [7:0]                  axi_ar_len_o,
  output logic [2:0]                  axi_ar_size_o,
  output logic [1:0]                  axi_ar_burst_o,
  output logic                        axi_ar_valid_o,
  input  logic                        axi_ar_ready_i,
  input  logic [AXI_DATA_WIDTH-1:0]   axi_r_data_i,
  input  logic                        axi_r_last_i,
  input  logic                        axi_r_valid_i,
  output logic                        axi_r_ready_o,

  // ── AXI4 write (im2col matrix to DDR3) ──
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
  output logic                        axi_b_ready_o
);

  localparam int PIX_PER_BEAT = AXI_DATA_WIDTH / 16;  // 16
  localparam int LANES        = 4;
  localparam int PAD          = 1;

  // Line buffer: 256-bit words (16 pixels per word)
  // Total storage: MAX_IN_CH * MAX_BATCH_ROWS * (MAX_IMG_W/16) words per replica
  localparam int WORDS_PER_ROW = MAX_IMG_W / PIX_PER_BEAT;                 // 16
  localparam int WORDS_PER_IC  = MAX_BATCH_ROWS * WORDS_PER_ROW;           // 256
  localparam int BUF_WORDS     = MAX_IN_CH * WORDS_PER_IC;                 // 4096
  localparam int BUF_AW        = $clog2(BUF_WORDS);                       // 12

  // ---------------- Line buffer (4 replicas, wide words) ----------------
  logic [BUF_AW-1:0]        buf_waddr;
  logic [AXI_DATA_WIDTH-1:0] buf_wdata;
  logic                      buf_we;
  logic [BUF_AW-1:0]        buf_raddr [LANES];
  logic [AXI_DATA_WIDTH-1:0] buf_rword [LANES];

  generate
    for (genvar b = 0; b < LANES; b++) begin : g_bank
      (* ram_style = "block" *) logic [AXI_DATA_WIDTH-1:0] line_buf [0:BUF_WORDS-1];
      always_ff @(posedge clk_i) begin
        if (buf_we) line_buf[buf_waddr] <= buf_wdata;
        buf_rword[b] <= line_buf[buf_raddr[b]];
      end
    end
  endgenerate

  // ---------------- FSM ----------------
  typedef enum logic [3:0] {
    S_IDLE,
    S_LOAD_AR,     // issue AR for one row of one ic
    S_LOAD_R,     // receive R beats and write to line buffer
    S_AW,
    S_COMP,
    S_W,
    S_B,
    S_DONE
  } state_e;
  state_e state_q, state_d;

  // ---------------- Geometry ----------------
  logic [7:0]  first_out_row, last_out_row;
  logic [7:0]  first_in_row,  last_in_row;
  logic [15:0] last_pix;

  assign last_pix      = batch_start_i + batch_pix_i - 16'd1;
  assign first_out_row = batch_start_i[15:0] / {8'b0, img_w_i};
  assign last_out_row  = last_pix[15:0]      / {8'b0, img_w_i};
  assign first_in_row  = (first_out_row == 8'd0)              ? 8'd0             : first_out_row - 8'd1;
  assign last_in_row   = (last_out_row  >= (img_h_i - 8'd1))  ? (img_h_i - 8'd1) : last_out_row  + 8'd1;

  // ---------------- LOAD counters ----------------
  logic [4:0]              load_ic_q;                    // 0..MAX_IN_CH-1
  logic [$clog2(MAX_BATCH_ROWS)-1:0] load_row_q;         // 0..num_rows-1 (relative to first_in_row)
  logic [$clog2(WORDS_PER_ROW):0]    load_word_q;        // 0..WORDS_PER_ROW-1 (current word within row)
  logic [7:0]              load_src_row;
  logic [7:0]              words_per_row_img;            // ceil((img_w+15)/16) worst-case beats per row

  assign load_src_row       = first_in_row + 8'(load_row_q);
  // +31 accounts for worst-case pix_skip of 15 pixels (30 bytes) before 32-byte-aligned start.
  // E.g., img_w=150 → 11 beats (covers any row's aligned read regardless of pix_skip).
  assign words_per_row_img  = (img_w_i + 8'd31) >> 4;

  // ---------------- 32-byte AXI alignment: per-row pixel skip table ----------------
  // AXI AR must be 32-byte aligned. Row start byte = ic*stride*2 + row*img_w*2 — may be
  // unaligned when img_w isn't 16-pix aligned. We align down and track the pixel skip so
  // the COMP phase can read from the correct slot in the loaded beat.
  logic [3:0] row_skip_q [MAX_IN_CH-1:0][MAX_BATCH_ROWS-1:0];

  logic load_row_last, load_ic_last;
  assign load_row_last = ((first_in_row + 8'(load_row_q)) >= last_in_row);
  assign load_ic_last  = ((load_ic_q + 5'd1) >= in_ch_i);

  // ---------------- COMPUTE counters ----------------
  logic [7:0]  k_q;
  logic [15:0] out_pix_q;
  logic [2:0]  phase_q;
  logic [LANES-1:0] pad_pipe_q;
  logic [31:0] ddr_addr_q;

  logic [7:0]  k_total;
  logic [15:0] pix_per_k;

  assign k_total   = {3'b0, in_ch_i} * 8'd9;
  assign pix_per_k = ((batch_pix_i + PIX_PER_BEAT - 1) / PIX_PER_BEAT) * PIX_PER_BEAT;

  // ---------------- BURST state (write side) ----------------
  logic [4:0] burst_len_q;
  logic [4:0] burst_cnt_q;

  logic [15:0] rem_pix;
  logic [11:0] rem_beats;
  logic [4:0]  rem_beats_cap16;
  logic [12:0] bytes_to_4k;
  logic [7:0]  beats_to_4k;
  logic [4:0]  beats_to_4k_cap16;
  logic [4:0]  burst_len_new;

  assign rem_pix           = pix_per_k - out_pix_q;
  assign rem_beats         = rem_pix[15:4];
  assign rem_beats_cap16   = (rem_beats >= 12'd16) ? 5'd16 : rem_beats[4:0];
  assign bytes_to_4k       = 13'h1000 - {1'b0, ddr_addr_q[11:0]};
  assign beats_to_4k       = bytes_to_4k[12:5];
  assign beats_to_4k_cap16 = (beats_to_4k >= 8'd16) ? 5'd16 : beats_to_4k[4:0];
  assign burst_len_new     = (rem_beats_cap16 < beats_to_4k_cap16) ? rem_beats_cap16
                                                                    : beats_to_4k_cap16;

  // ---------------- Per-lane address generation (COMP) ----------------
  logic [15:0]       cur_global_pix [LANES];
  logic [7:0]        cur_out_row    [LANES];
  logic [7:0]        cur_out_col    [LANES];
  logic [4:0]        cur_ic;
  logic [1:0]        cur_kr, cur_ks;
  logic signed [8:0] cur_src_row    [LANES];
  logic signed [8:0] cur_src_col    [LANES];
  logic              cur_in_bounds  [LANES];
  logic              cur_is_pad     [LANES];

  assign cur_ic = k_q / 8'd9;
  assign cur_kr = (k_q % 8'd9) / 2'd3;
  assign cur_ks = k_q % 2'd3;

  // Per-lane word addr and pixel offset
  logic [BUF_AW-1:0] lane_word_addr [LANES];
  logic [3:0]        lane_pix_off   [LANES];
  logic [3:0]        lane_pix_off_r [LANES];   // registered for BRAM 1-cycle latency

  generate
    for (genvar l = 0; l < LANES; l++) begin : g_lane_addr
      assign cur_global_pix[l] = batch_start_i + out_pix_q + 16'(l);
      assign cur_out_row[l]    = cur_global_pix[l] / {8'b0, img_w_i};
      assign cur_out_col[l]    = cur_global_pix[l] % {8'b0, img_w_i};
      assign cur_src_row[l]    = $signed({1'b0, cur_out_row[l]}) + $signed({7'b0, cur_kr}) - $signed(9'(PAD));
      assign cur_src_col[l]    = $signed({1'b0, cur_out_col[l]}) + $signed({7'b0, cur_ks}) - $signed(9'(PAD));
      assign cur_in_bounds[l]  = (cur_src_row[l] >= 0) && (cur_src_row[l] < $signed({1'b0, img_h_i}))
                              && (cur_src_col[l] >= 0) && (cur_src_col[l] < $signed({1'b0, img_w_i}));
      assign cur_is_pad[l]     = ((out_pix_q + 16'(l)) >= batch_pix_i) || !cur_in_bounds[l];

      // Map (ic, src_row_in_buf, src_col) to word addr + pixel offset.
      // Adjust by per-row pix_skip (from unaligned row start); effective col within the
      // aligned load = src_col + row_skip. Word idx can reach 10 for img_w=150 with max skip,
      // still fits in 4 bits.
      logic [3:0] buf_row_idx;
      logic [7:0] src_col_8;
      logic [3:0] lane_row_skip;
      logic [7:0] eff_col;
      assign buf_row_idx       = 4'(cur_src_row[l][7:0] - first_in_row);
      assign src_col_8         = cur_src_col[l][7:0];
      assign lane_row_skip     = row_skip_q[cur_ic][buf_row_idx];
      assign eff_col           = src_col_8 + {4'b0, lane_row_skip};
      assign lane_word_addr[l] = { cur_ic[3:0], buf_row_idx, eff_col[7:4] };
      assign lane_pix_off[l]   = eff_col[3:0];

      assign buf_raddr[l] = lane_word_addr[l];
    end
  endgenerate

  // ---------------- AXI defaults ----------------
  logic [AXI_DATA_WIDTH-1:0] wbuf_q;
  assign axi_ar_size_o  = 3'b101;                       // 32 bytes per beat (256-bit)
  assign axi_ar_burst_o = 2'b01;                        // INCR
  assign axi_aw_size_o  = 3'b101;
  assign axi_aw_burst_o = 2'b01;
  assign axi_aw_len_o   = {3'b0, burst_len_new - 5'd1};
  assign axi_w_strb_o   = {(AXI_DATA_WIDTH/8){1'b1}};
  assign axi_w_last_o   = (burst_cnt_q == burst_len_q - 5'd1);
  assign axi_w_data_o   = wbuf_q;
  assign axi_b_ready_o  = 1'b1;

  // ---------------- LOAD: AXI AR addressing ----------------
  // Each burst reads one row of one channel, from 32-byte-aligned base.
  // load_row_byte_addr is the natural row-start byte; we align down for AR and save the
  // pixel skip so COMP can offset into the loaded beats.
  logic [31:0] load_row_byte_addr;
  logic [3:0]  load_pix_skip;
  assign load_row_byte_addr = in_base_addr_i
                            + (32'(load_ic_q) * 32'(in_ch_stride_i) * 32'd2)
                            + (32'(load_src_row) * 32'(img_w_i) * 32'd2);
  assign load_pix_skip  = load_row_byte_addr[4:1];               // 0..15 pixels
  assign axi_ar_addr_o  = load_row_byte_addr & ~32'h1F;          // 32-byte align down
  assign axi_ar_len_o   = 8'(words_per_row_img - 8'd1);          // beats - 1 (always worst-case)

  // AXI R always ready (wide line buffer absorbs 1 beat/cy)
  assign axi_r_ready_o = (state_q == S_LOAD_R);

  // ---------------- Line buffer write mux ----------------
  always_comb begin
    buf_we    = 1'b0;
    buf_waddr = '0;
    buf_wdata = '0;
    if (state_q == S_LOAD_R && axi_r_valid_i) begin
      buf_we    = 1'b1;
      buf_waddr = { load_ic_q[3:0], load_row_q[3:0], load_word_q[3:0] };
      buf_wdata = axi_r_data_i;
    end
  end

  // ---------------- Next-state after load ----------------
  state_e nxt_after_load;
  always_comb begin
    if (load_row_last && load_ic_last) nxt_after_load = S_AW;
    else                                nxt_after_load = S_LOAD_AR;
  end

  // ---------------- FSM combinational ----------------
  always_comb begin
    state_d        = state_q;
    axi_ar_valid_o = 1'b0;
    axi_aw_valid_o = 1'b0;
    axi_aw_addr_o  = ddr_addr_q;
    axi_w_valid_o  = 1'b0;
    done_o         = 1'b0;

    unique case (state_q)
      S_IDLE:   if (start_i)          state_d = S_LOAD_AR;

      S_LOAD_AR: begin
        axi_ar_valid_o = 1'b1;
        if (axi_ar_ready_i)            state_d = S_LOAD_R;
      end

      S_LOAD_R: begin
        // wait for last beat; after full burst of this row, advance
        if (axi_r_valid_i && axi_r_last_i) state_d = nxt_after_load;
      end

      S_AW: begin
        axi_aw_valid_o = 1'b1;
        if (axi_aw_ready_i)            state_d = S_COMP;
      end

      S_COMP: if (phase_q == 3'd4)    state_d = S_W;

      S_W: begin
        axi_w_valid_o = 1'b1;
        if (axi_w_ready_i) begin
          if (burst_cnt_q == burst_len_q - 5'd1) state_d = S_B;
          else                                   state_d = S_COMP;
        end
      end

      S_B: if (axi_b_valid_i) begin
        if (k_q >= k_total - 1 && out_pix_q >= pix_per_k) state_d = S_DONE;
        else                                              state_d = S_AW;
      end

      S_DONE: begin
        done_o  = 1'b1;
        state_d = S_IDLE;
      end

      default: state_d = S_IDLE;
    endcase
  end

  // ---------------- Sequential ----------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= S_IDLE;
      load_ic_q    <= '0;
      load_row_q   <= '0;
      load_word_q  <= '0;
      k_q          <= '0;
      out_pix_q    <= '0;
      phase_q      <= '0;
      pad_pipe_q   <= '0;
      ddr_addr_q   <= '0;
      wbuf_q       <= '0;
      burst_len_q  <= 5'd1;
      burst_cnt_q  <= '0;
      for (int l = 0; l < LANES; l++) lane_pix_off_r[l] <= 4'd0;
      for (int i = 0; i < MAX_IN_CH; i++)
        for (int j = 0; j < MAX_BATCH_ROWS; j++)
          row_skip_q[i][j] <= 4'd0;
    end else begin
      state_q <= state_d;

      unique case (state_q)
        S_IDLE: begin
          if (start_i) begin
            load_ic_q   <= '0;
            load_row_q  <= '0;
            load_word_q <= '0;
            k_q         <= '0;
            out_pix_q   <= '0;
            phase_q     <= '0;
            pad_pipe_q  <= '0;
            ddr_addr_q  <= ddr_dest_addr_i;
            wbuf_q      <= '0;
            burst_len_q <= 5'd1;
            burst_cnt_q <= '0;
          end
        end

        S_LOAD_AR: begin
          // Capture per-row pixel skip when AR handshakes — COMP reads this back via
          // row_skip_q[cur_ic][buf_row_idx] to offset into the 32-byte-aligned load.
          if (axi_ar_ready_i) begin
            row_skip_q[load_ic_q][load_row_q[3:0]] <= load_pix_skip;
          end
        end

        S_LOAD_R: begin
          if (axi_r_valid_i) begin
            // advance word counter within current row
            if (axi_r_last_i) begin
              load_word_q <= '0;
              // advance row/ic for next burst
              if (load_row_last) begin
                load_row_q <= '0;
                if (!load_ic_last) load_ic_q <= load_ic_q + 5'd1;
              end else begin
                load_row_q <= load_row_q + 1'b1;
              end
            end else begin
              load_word_q <= load_word_q + 1'b1;
            end
          end
        end

        S_AW: begin
          if (axi_aw_ready_i) begin
            burst_len_q <= burst_len_new;
            burst_cnt_q <= 5'd0;
          end
        end

        S_COMP: begin
          if (phase_q < 3'd4) begin
            for (int l = 0; l < LANES; l++) begin
              pad_pipe_q[l]     <= cur_is_pad[l];
              lane_pix_off_r[l] <= lane_pix_off[l];
            end
            out_pix_q <= out_pix_q + 16'd4;
          end
          if (phase_q >= 3'd1) begin
            for (int l = 0; l < LANES; l++) begin
              // Extract pixel from 256-bit word using registered offset
              wbuf_q[((phase_q - 3'd1)*LANES + l)*16 +: 16] <=
                pad_pipe_q[l]
                  ? 16'd0
                  : buf_rword[l][lane_pix_off_r[l]*16 +: 16];
            end
          end
          if (phase_q < 3'd4) phase_q <= phase_q + 3'd1;
          else                phase_q <= '0;
        end

        S_W: if (axi_w_ready_i) begin
          ddr_addr_q  <= ddr_addr_q + 32'd32;
          burst_cnt_q <= burst_cnt_q + 5'd1;
        end

        S_B: if (axi_b_valid_i) begin
          if (out_pix_q >= pix_per_k) begin
            if (k_q < k_total - 1) begin
              k_q       <= k_q + 8'd1;
              out_pix_q <= '0;
            end
          end
        end

        default: ;
      endcase
    end
  end

endmodule
