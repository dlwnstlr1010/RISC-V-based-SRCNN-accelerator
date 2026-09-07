/*
 * srcnn_test.c — SRCNN multi-config sweep (single binary)
 *
 * Runs all 5 channel configs (C1..C5) sequentially against user-provided
 * golden references. Per-config reports PE utilization and max_diff vs golden.
 *
 * To build: make clean all platform=fpga io=uart
 */
#include <stdio.h>
#include <stdint.h>
#include "pulp.h"
#include "archi/chips/pulpissimo/memory_map.h"
#include "archi/hwme/hwme_v1.h"
#include "srcnn_data_all.h"

#define FIXED_BIT   8
#define KS          3
#define PAD         1
#define SA_COLS     16

/* Frame size — can be changed at runtime for UHD tile-driver mode.
   Default = 120x120 for the 5-config sweep (LCM-aligned: 14400 = 225*64 → L3 Mode B
   exactly 100% PE util; also divisible by SA_COLS=16 so L1/L2 zero padding).
   Set via set_frame_size(). */
static int g_img_w   = 120;
static int g_img_h   = 120;
static int g_n_pix   = 14400;
static int g_n_pixp  = 14400;   /* ceil(g_n_pix / 16) * 16 — 14400 is already aligned */

#define IMG_W      g_img_w
#define IMG_H      g_img_h
#define N_PIXELS   g_n_pix
#define N_PIX_PAD  g_n_pixp

static void set_frame_size(int w, int h) {
    g_img_w  = w; g_img_h = h;
    g_n_pix  = w * h;
    g_n_pixp = ((g_n_pix + SA_COLS - 1) / SA_COLS) * SA_COLS;
}

#define DDR3_BASE   ARCHI_DDR_ADDR
#ifdef UHD_DEMO
  /* UHD mode: three ~16 MB buffers at the start, tile workspaces higher up. */
  #define UHD_INPUT   (DDR3_BASE + 0x00000000)   /* 3840*2160*2 = 16.6 MB */
  #define UHD_OUTPUT  (DDR3_BASE + 0x01000000)
  #define UHD_GOLDEN  (DDR3_BASE + 0x02000000)
  #define DDR_INPUT   (DDR3_BASE + 0x03000000)   /* 126*126 tile workspace */
  #define DDR_OUT_A   (DDR3_BASE + 0x03100000)
  #define DDR_OUT_B   (DDR3_BASE + 0x03200000)
  #define DDR_IM2COL  (DDR3_BASE + 0x03400000)
#else
  #define DDR_INPUT   (DDR3_BASE + 0x00000000)
  #define DDR_OUT_A   (DDR3_BASE + 0x00400000)
  #define DDR_OUT_B   (DDR3_BASE + 0x00800000)
  #define DDR_IM2COL  (DDR3_BASE + 0x00C00000)
#endif

#define REG_MODE          0x05C
#define REG_DDR_ADDR      0x060
#define REG_TILE_LEN      0x064
#define REG_TOTAL_PIX     0x068
#define REG_BATCH_PIX     0x06C
#define REG_HW_CYCLES     0x080
#define REG_IM2COL_ADDR   0x084
#define REG_IM2COL_SIZE   0x088
#define REG_IM2COL_BSTART 0x08C

#define HWPE_REG(off)  (ARCHI_FC_HWPE_ADDR + (off))
static inline void     hwpe_wr(uint32_t off, uint32_t val) { pulp_write32(HWPE_REG(off), val); }
static inline uint32_t hwpe_rd(uint32_t off) { return pulp_read32(HWPE_REG(off)); }

#define L2_WEIGHT   0x1C060000u
#define L2_BIAS     0x1C061000u

/* Per-layer cycle accumulators (reset by run_hwpe_layer at entry; accumulated
   across all multi-pass passes within one layer). */
static uint32_t g_cnt_sys, g_cnt_run, g_cnt_im2col, g_cnt_dma, g_cnt_loadw, g_cnt_pp;
static uint32_t g_tile_count, g_batch_count, g_pass_count;
static int      g_mode_b;
static int      g_out_ch_total;
static int      g_k_total;

/* Per-frame util totals (sum over L1+L2+L3 of one config) */
static uint32_t f_cnt_sys, f_useful_macs, f_compute_cycles;

/* Monotonic HWPE active-cycle accumulator (sum of im2col+dma+loadw+run+pp
   across all batches). Reset explicitly before a throughput-measured window. */
static uint64_t g_hwpe_cy_total;

/* Enable CV32E40P machine-mode perf counters by clearing mcountinhibit.CY.
   CV32E40P leaves mcycle disabled after reset via the 0x320 inhibit bit. */
static inline void enable_mcycle(void) {
    /* Clear bit 0 (mcycle inhibit) and bit 2 (minstret inhibit). */
    __asm__ volatile ("csrci 0x320, 0x5");
}

/* Read CV32E40P 64-bit machine cycle counter (mcycle=0xB00, mcycleh=0xB80).
   CV32E40P doesn't implement the user-mode Zicntr aliases (0xC00/0xC80). */
static inline uint64_t read_mcycle(void) {
    uint32_t lo, hi, hi2;
    do {
        __asm__ volatile ("csrr %0, 0xB80" : "=r"(hi));
        __asm__ volatile ("csrr %0, 0xB00" : "=r"(lo));
        __asm__ volatile ("csrr %0, 0xB80" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

static int run_hwpe_pass(const int16_t *weights, const int16_t *bias,
                         int in_ch, int out_ch_pass, int k_total, int layer_num,
                         int pass_idx,
                         uint32_t in_ddr_addr, uint32_t out_ddr_addr)
{
    volatile int16_t *l2w = (volatile int16_t *)L2_WEIGHT;
    volatile int16_t *l2b = (volatile int16_t *)L2_BIAS;

    for (int i = 0; i < out_ch_pass * k_total; i++) l2w[i] = weights[i];
    for (int i = 0; i < out_ch_pass; i++)            l2b[i] = bias[i];

    int mode_b = (out_ch_pass == 1 && g_mode_b) ? 1 : 0;

    hwpe_wr(0x048, L2_WEIGHT);
    hwpe_wr(0x04C, L2_BIAS);
    hwpe_wr(0x050, in_ch);
    hwpe_wr(0x054, out_ch_pass);
    hwpe_wr(0x058, layer_num);
    hwpe_wr(REG_MODE, mode_b);
    hwpe_wr(REG_TOTAL_PIX, N_PIX_PAD);
    hwpe_wr(REG_IM2COL_ADDR, in_ddr_addr);
    hwpe_wr(REG_IM2COL_SIZE, (IMG_H << 8) | IMG_W);

    int max_tiles = 1024 / k_total;
    int max_bp = max_tiles * SA_COLS;
    /* im2col has MAX_BATCH_ROWS=16; row span per batch = ceil(bp_pad/img_w) + 2 (±1 halo).
       Use (16-3) headroom to cover bp_pad rounding above bp when bp isn't 16-aligned
       (e.g. UHD tile img_w=126 → 126 is not 16-multiple, so bp_pad > bp).
       Also align the cap down to SA_COLS=16 so bp == bp_pad (no dummy spill into the
       next batch's output region). */
    int row_cap_bp = 13 * IMG_W;
    row_cap_bp = (row_cap_bp / SA_COLS) * SA_COLS;
    if (max_bp > row_cap_bp) max_bp = row_cap_bp;
    if (mode_b) max_bp = (max_bp / 64) * 64;
    int ddr_offset = 0;

    for (int bs = 0; bs < N_PIXELS; bs += max_bp) {
        int bp = max_bp;
        if (bs + bp > N_PIXELS) bp = N_PIXELS - bs;
        int bp_pad = mode_b ? (((bp + 63) / 64) * 64) : (((bp + SA_COLS - 1) / SA_COLS) * SA_COLS);
        int stride = bp_pad / SA_COLS;
        int tile_len = k_total * stride * 8;

        hwpe_wr(HWME_SOFT_CLEAR, 1);
        hwpe_wr(REG_DDR_ADDR, DDR_IM2COL + ddr_offset * 2);
        hwpe_wr(REG_TILE_LEN, tile_len);
        hwpe_wr(REG_BATCH_PIX, bp_pad);
        hwpe_wr(REG_IM2COL_BSTART, bs);
        hwpe_wr(0x040, L2_WEIGHT);
        hwpe_wr(0x044, out_ddr_addr + bs * 2);
        hwpe_wr(HWME_TRIGGER, 1);

        int timeout = 2000000;
        while (timeout-- > 0)
            if (hwpe_rd(HWME_STATUS) & 0x2) break;
        if (timeout <= 0) {
            printf("  TIMEOUT L%d pass%d bs=%d\n", layer_num, pass_idx, bs);
            return -1;
        }

        uint32_t batch_im2col = hwpe_rd(0x090);
        uint32_t batch_dma    = hwpe_rd(0x094);
        uint32_t batch_loadw  = hwpe_rd(0x098);
        uint32_t batch_run    = hwpe_rd(0x09C);
        uint32_t batch_pp     = hwpe_rd(0x0A4);
        g_cnt_sys    += hwpe_rd(0x0A0);
        g_cnt_run    += batch_run;
        g_cnt_im2col += batch_im2col;
        g_cnt_dma    += batch_dma;
        g_cnt_loadw  += batch_loadw;
        g_cnt_pp     += batch_pp;
        g_tile_count += mode_b ? (bp_pad / 64) : (bp_pad / SA_COLS);
        g_batch_count++;
        /* Monotonic HWPE active-cycle total (each batch's active phases). */
        g_hwpe_cy_total += (uint64_t)batch_im2col + batch_dma
                         + batch_loadw + batch_run + batch_pp;

        ddr_offset += k_total * bp_pad;
    }
    return 0;
}

static int run_hwpe_layer(const int16_t *weights, const int16_t *bias,
                          int in_ch, int out_ch, int k_total, int layer_num,
                          uint32_t in_ddr_addr, uint32_t out_ddr_addr)
{
    g_cnt_sys = 0; g_cnt_run = 0; g_cnt_im2col = 0; g_cnt_dma = 0;
    g_cnt_loadw = 0; g_cnt_pp = 0;
    g_tile_count = 0; g_batch_count = 0; g_pass_count = 0;
    g_mode_b = (out_ch == 1) ? 1 : 0;
    g_out_ch_total = out_ch;
    g_k_total = k_total;

    volatile int16_t *ddr_out = (volatile int16_t *)out_ddr_addr;
    for (int i = 0; i < out_ch * N_PIX_PAD; i++) ddr_out[i] = 0;

    int passes = (out_ch + 3) / 4;
    for (int p = 0; p < passes; p++) {
        int pass_out = out_ch - p * 4;
        if (pass_out > 4) pass_out = 4;
        const int16_t *w_p = weights + p * 4 * k_total;
        const int16_t *b_p = bias    + p * 4;
        uint32_t       out_p = out_ddr_addr + (uint32_t)p * 4u * (uint32_t)N_PIX_PAD * 2u;
        if (run_hwpe_pass(w_p, b_p, in_ch, pass_out, k_total, layer_num,
                          p, in_ddr_addr, out_p)) return -1;
        g_pass_count++;
    }
    return 0;
}

/* Per-layer stats line + add to per-frame totals. */
static void layer_stats(const char *tag)
{
    uint32_t useful_macs    = (uint32_t)N_PIXELS * (uint32_t)g_out_ch_total * (uint32_t)g_k_total;
    uint32_t compute_cycles = (g_cnt_sys > g_tile_count) ? (g_cnt_sys - g_tile_count) : g_cnt_sys;
    uint32_t pe_cycles      = compute_cycles * 64u;
    uint32_t util_x10000    = (pe_cycles > 0) ? (uint32_t)(((uint64_t)useful_macs * 10000u) / pe_cycles) : 0;
    printf("    %s: passes=%u tiles=%u cnt_sys=%u compute_cy=%u useful=%u util=%u.%02u%%\n",
           tag, g_pass_count, g_tile_count, g_cnt_sys, compute_cycles, useful_macs,
           util_x10000 / 100u, util_x10000 % 100u);
    f_cnt_sys        += g_cnt_sys;
    f_useful_macs    += useful_macs;
    f_compute_cycles += compute_cycles;
}

static int run_one_config(const srcnn_config_t *cfg)
{
    printf("\n========== [%s] ==========\n", cfg->name);
    f_cnt_sys = 0; f_useful_macs = 0; f_compute_cycles = 0;

    /* L1: 1 → l1_out, K=9 */
    if (run_hwpe_layer(cfg->w1, cfg->b1, cfg->l1_in, cfg->l1_out, 9, 1,
                       DDR_INPUT, DDR_OUT_A)) return -1;
    layer_stats("L1");

    /* L2: l1_out → l2_out, K=l1_out*9 */
    if (run_hwpe_layer(cfg->w2, cfg->b2, cfg->l1_out, cfg->l2_out, cfg->l1_out * 9, 2,
                       DDR_OUT_A, DDR_OUT_B)) return -1;
    layer_stats("L2");

    /* L3: l2_out → 1 (Mode B), K=l2_out*9 */
    if (run_hwpe_layer(cfg->w3, cfg->b3, cfg->l2_out, cfg->l3_out, cfg->l2_out * 9, 3,
                       DDR_OUT_B, DDR_OUT_A)) return -1;
    layer_stats("L3");

    /* Verify L3 output (DDR_OUT_A) vs cfg->golden */
    volatile int16_t *hw = (volatile int16_t *)DDR_OUT_A;
    int errors = 0, max_diff = 0;
    int64_t sum_diff = 0;
    for (int i = 0; i < N_PIXELS; i++) {
        int16_t v_hw = hw[i];
        int16_t v_gd = cfg->golden[i];
        int d = v_hw - v_gd;
        if (d < 0) d = -d;
        sum_diff += d;
        if (d > max_diff) max_diff = d;
        if (v_hw != v_gd) errors++;
    }

    /* Per-frame aggregate util */
    uint32_t pe_cycles_f = f_compute_cycles * 64u;
    uint32_t util_fx10000 = (pe_cycles_f > 0)
        ? (uint32_t)(((uint64_t)f_useful_macs * 10000u) / pe_cycles_f) : 0;

    printf("  HWPE out[0..4]=%d %d %d %d %d  Golden[0..4]=%d %d %d %d %d\n",
           hw[0], hw[1], hw[2], hw[3], hw[4],
           cfg->golden[0], cfg->golden[1], cfg->golden[2], cfg->golden[3], cfg->golden[4]);
    printf("  exact=%d/%d  max_diff=%d  mean_diff=%d.%02d\n",
           N_PIXELS - errors, N_PIXELS, max_diff,
           (int)(sum_diff / N_PIXELS), (int)((sum_diff * 100 / N_PIXELS) % 100));
    printf("  FRAME PE_UTIL = %u.%02u%%  (useful=%u PE-cycles=%u)\n",
           util_fx10000 / 100u, util_fx10000 % 100u, f_useful_macs, pe_cycles_f);
    printf("  >>> %s <<<\n", (max_diff <= 3) ? "PASS" : "FAIL");

    return (max_diff <= 3) ? 0 : -1;
}

#ifdef UHD_DEMO
/* ──────────────────────────────────────────────────────────────────────
 * UHD tile-driver mode.
 *
 * UHD frame (3840x2160) partitioned into 32x18 output tiles, each 120x120
 * (exactly divides UHD in both axes — zero boundary overhead).
 * Each tile uses a 126x126 input patch (= 120 output + 3-pixel border on
 * each side for 3 layers of 3x3 conv receptive field). SW extracts the
 * patch from DDR UHD input (with zero-pad at UHD image boundaries),
 * invokes the HWPE for a 126x126 "frame", and stitches the center 120x120
 * of the HWPE output back into DDR UHD output.
 *
 * Prerequisites: user pre-loads UHD_INPUT and UHD_GOLDEN in DDR3 via GDB.
 *   (gdb) restore data/uhd/input_3840x2160.bin          binary 0x80000000
 *   (gdb) restore data/uhd/golden_C<N>_3840x2160.bin    binary 0x82000000
 * ────────────────────────────────────────────────────────────────────── */
#define UHD_W         3840
#define UHD_H         2160
#define UHD_TILE_OUT  120      /* 120x120 output per HWPE invocation */
#define UHD_BORDER    3        /* 3-layer 3x3 conv receptive field */
#define UHD_TILE_IN   (UHD_TILE_OUT + 2 * UHD_BORDER)   /* 126 */

#ifndef UHD_CONFIG
#define UHD_CONFIG  0          /* 0..4 selects CONFIGS[] */
#endif

#define UHD_N_SPOTS  10           /* hardcoded "key" positions (corners, midpoints) */
#define UHD_PER_TILE_SAMPLES  1   /* additional SW-ref spot-checks per tile (PRNG-chosen) */
/* Total spot checks = UHD_N_SPOTS + 576 * UHD_PER_TILE_SAMPLES */

/* CPU-side synthetic input generator — deterministic pattern. Matches
   Python-side pattern if ever needed for external verification.

   Pattern: v = ((y * 13 + x * 7) >> 2) & 0xFF  — smooth gradient + cross. */
static inline int16_t synth_pixel(int y, int x) {
    return (int16_t)(((y * 13 + x * 7) >> 2) & 0xFF);
}

static void uhd_gen_input(void)
{
    volatile int16_t *ddr_in = (volatile int16_t *)UHD_INPUT;
    printf("[uhd] generating %dx%d procedural input to DDR... ", UHD_W, UHD_H);
    for (int y = 0; y < UHD_H; y++) {
        for (int x = 0; x < UHD_W; x++) {
            ddr_in[y * UHD_W + x] = synth_pixel(y, x);
        }
    }
    printf("done\n");
}

/* ─── CPU-side SW reference for one UHD output pixel ───
   Recursive: reproduces HWPE tile-driver's per-layer padding semantics.
   Tile resolved from (y, x); per-layer reach stays inside the 126x126 patch. */
static int16_t sw_patch_pix(int ty, int tx, int dy, int dx)
{
    /* out-of-patch → HWPE zero-padding at each layer */
    if (dy < 0 || dy >= UHD_TILE_IN || dx < 0 || dx >= UHD_TILE_IN) return 0;
    int uy = ty - UHD_BORDER + dy;
    int ux = tx - UHD_BORDER + dx;
    if (uy < 0 || uy >= UHD_H || ux < 0 || ux >= UHD_W) return 0;      /* UHD zero-fill */
#ifdef UHD_REAL
    volatile const int16_t *uhd_in = (volatile const int16_t *)UHD_INPUT;
    return uhd_in[uy * UHD_W + ux];
#else
    return synth_pixel(uy, ux);
#endif
}

static int16_t sw_clamp_i16(int32_t v) {
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return (int16_t)v;
}

static int16_t sw_L1(const srcnn_config_t *cfg, int ty, int tx, int dy, int dx, int oc)
{
    int32_t acc = 0;
    /* L1: in_ch = 1 */
    for (int ky = 0; ky < 3; ky++)
    for (int kx = 0; kx < 3; kx++) {
        int iy = dy + ky - 1;
        int ix = dx + kx - 1;
        int16_t v = sw_patch_pix(ty, tx, iy, ix);
        int16_t w = cfg->w1[(oc * cfg->l1_in + 0) * 9 + ky * 3 + kx];
        acc += (int32_t)v * (int32_t)w;
    }
    acc = (acc >> 8) + cfg->b1[oc];
    if (acc < 0) acc = 0;                /* ReLU */
    return sw_clamp_i16(acc);
}

static int16_t sw_L2(const srcnn_config_t *cfg, int ty, int tx, int dy, int dx, int oc)
{
    int32_t acc = 0;
    for (int ic = 0; ic < cfg->l1_out; ic++)
    for (int ky = 0; ky < 3; ky++)
    for (int kx = 0; kx < 3; kx++) {
        int iy = dy + ky - 1;
        int ix = dx + kx - 1;
        int16_t v = (iy < 0 || iy >= UHD_TILE_IN || ix < 0 || ix >= UHD_TILE_IN)
                    ? 0 : sw_L1(cfg, ty, tx, iy, ix, ic);
        int16_t w = cfg->w2[(oc * cfg->l1_out + ic) * 9 + ky * 3 + kx];
        acc += (int32_t)v * (int32_t)w;
    }
    acc = (acc >> 8) + cfg->b2[oc];
    if (acc < 0) acc = 0;
    return sw_clamp_i16(acc);
}

static int16_t sw_L3(const srcnn_config_t *cfg, int ty, int tx, int dy, int dx)
{
    int32_t acc = 0;
    for (int ic = 0; ic < cfg->l2_out; ic++)
    for (int ky = 0; ky < 3; ky++)
    for (int kx = 0; kx < 3; kx++) {
        int iy = dy + ky - 1;
        int ix = dx + kx - 1;
        int16_t v = (iy < 0 || iy >= UHD_TILE_IN || ix < 0 || ix >= UHD_TILE_IN)
                    ? 0 : sw_L2(cfg, ty, tx, iy, ix, ic);
        int16_t w = cfg->w3[(0 * cfg->l2_out + ic) * 9 + ky * 3 + kx];
        acc += (int32_t)v * (int32_t)w;
    }
    acc = (acc >> 8) + cfg->b3[0];
    return sw_clamp_i16(acc);            /* no ReLU for L3 */
}

/* SW reference for UHD output pixel (uy, ux). */
static int16_t sw_uhd_pixel(const srcnn_config_t *cfg, int uy, int ux)
{
    int ty = (uy / UHD_TILE_OUT) * UHD_TILE_OUT;
    int tx = (ux / UHD_TILE_OUT) * UHD_TILE_OUT;
    int dy = uy - ty + UHD_BORDER;
    int dx = ux - tx + UHD_BORDER;
    return sw_L3(cfg, ty, tx, dy, dx);
}

/* Compute the tile input patch. Two modes:
   - default (procedural): values computed from synth_pixel — no JTAG load needed.
   - UHD_REAL: read from DDR UHD_INPUT (user pre-loads via JTAG restore of real image). */
static void uhd_extract_patch(int ty, int tx)
{
    volatile int16_t *tile = (volatile int16_t *)DDR_INPUT;
#ifdef UHD_REAL
    volatile const int16_t *uhd_in = (volatile const int16_t *)UHD_INPUT;
#endif
    for (int dy = 0; dy < UHD_TILE_IN; dy++) {
        int uy = ty - UHD_BORDER + dy;
        for (int dx = 0; dx < UHD_TILE_IN; dx++) {
            int ux = tx - UHD_BORDER + dx;
            int16_t v = 0;
            if (uy >= 0 && uy < UHD_H && ux >= 0 && ux < UHD_W) {
#ifdef UHD_REAL
                v = uhd_in[uy * UHD_W + ux];
#else
                v = synth_pixel(uy, ux);
#endif
            }
            tile[dy * UHD_TILE_IN + dx] = v;
        }
    }
}

static void uhd_stitch_tile(int ty, int tx)
{
    /* HWPE output for this tile is 126x126 (in DDR_OUT_A after L3).
       Center 120x120 of HWPE output = SR for UHD (ty..ty+119, tx..tx+119).
       Write back to UHD_OUTPUT, clamping at UHD image boundary. */
    volatile const int16_t *hw_out  = (volatile const int16_t *)DDR_OUT_A;
    volatile int16_t       *uhd_out = (volatile int16_t *)UHD_OUTPUT;
    for (int dy = 0; dy < UHD_TILE_OUT; dy++) {
        int uy = ty + dy;
        if (uy >= UHD_H) break;
        for (int dx = 0; dx < UHD_TILE_OUT; dx++) {
            int ux = tx + dx;
            if (ux >= UHD_W) break;
            int hw_idx = (dy + UHD_BORDER) * UHD_TILE_IN + (dx + UHD_BORDER);
            uhd_out[uy * UHD_W + ux] = hw_out[hw_idx];
        }
    }
}

static int uhd_run_tile_sr(const srcnn_config_t *cfg)
{
    /* Run 3 layers on the 126x126 patch currently in DDR_INPUT.
       Output after L3 ends up in DDR_OUT_A (due to ping-pong A→B→A). */
    if (run_hwpe_layer(cfg->w1, cfg->b1, cfg->l1_in,  cfg->l1_out, 9,
                       1, DDR_INPUT, DDR_OUT_A)) return -1;
    if (run_hwpe_layer(cfg->w2, cfg->b2, cfg->l1_out, cfg->l2_out, cfg->l1_out * 9,
                       2, DDR_OUT_A, DDR_OUT_B)) return -1;
    if (run_hwpe_layer(cfg->w3, cfg->b3, cfg->l2_out, cfg->l3_out, cfg->l2_out * 9,
                       3, DDR_OUT_B, DDR_OUT_A)) return -1;
    return 0;
}

int main(void)
{
    const srcnn_config_t *cfg = &CONFIGS[UHD_CONFIG];
    printf("\n################ SRCNN UHD Tile Driver ################\n");
    printf("[cfg] config=%s  UHD=%dx%d  tile_out=%d  tile_in=%d  tiles=%d\n",
           cfg->name, UHD_W, UHD_H, UHD_TILE_OUT, UHD_TILE_IN,
           ((UHD_H + UHD_TILE_OUT - 1)/UHD_TILE_OUT) *
           ((UHD_W + UHD_TILE_OUT - 1)/UHD_TILE_OUT));

    /* All subsequent run_hwpe_layer calls use 126x126 frame. */
    set_frame_size(UHD_TILE_IN, UHD_TILE_IN);

#ifdef UHD_REAL
    /* Step 1: DDR-loaded real image (user restores input_3840x2160.bin via GDB). */
    volatile const int16_t *uhd_in = (volatile const int16_t *)UHD_INPUT;
    printf("[input] DDR (real image, JTAG-loaded). Must restore input.bin to 0x%08x first!\n", UHD_INPUT);
    printf("[chk] UHD in [0..7]=%d %d %d %d %d %d %d %d  [mid]=%d  [end]=%d\n",
           uhd_in[0], uhd_in[1], uhd_in[2], uhd_in[3],
           uhd_in[4], uhd_in[5], uhd_in[6], uhd_in[7],
           uhd_in[(UHD_H/2)*UHD_W + UHD_W/2],
           uhd_in[UHD_H*UHD_W - 1]);
#else
    /* Step 1: per-tile patch generated inline from synth_pixel(). No DDR fill needed. */
    printf("[input] procedural (synth_pixel) — no JTAG load, tile patches computed on-demand\n");
    printf("[chk] synth first 8: %d %d %d %d %d %d %d %d\n",
           synth_pixel(0,0), synth_pixel(0,1), synth_pixel(0,2), synth_pixel(0,3),
           synth_pixel(0,4), synth_pixel(0,5), synth_pixel(0,6), synth_pixel(0,7));
#endif

    /* Step 2: HWPE processes all 576 tiles — stitch covers the full UHD output. */
    int n_tiles_y = (UHD_H + UHD_TILE_OUT - 1) / UHD_TILE_OUT;
    int n_tiles_x = (UHD_W + UHD_TILE_OUT - 1) / UHD_TILE_OUT;
    int total = n_tiles_y * n_tiles_x;
    int idx = 0;

    /* Throughput measurement window: from just before the first tile to
       just after the last stitch. Covers extract + HWPE + stitch + loop overhead. */
    enable_mcycle();
    g_hwpe_cy_total = 0;
    uint64_t t_start = read_mcycle();

    for (int ty = 0; ty < UHD_H; ty += UHD_TILE_OUT) {
        for (int tx = 0; tx < UHD_W; tx += UHD_TILE_OUT) {
            idx++;
            if (idx % 30 == 0 || idx == 1 || idx == total)
                printf("  tile %d/%d  (ty=%d, tx=%d)\n", idx, total, ty, tx);
            uhd_extract_patch(ty, tx);
            if (uhd_run_tile_sr(cfg)) {
                printf("  TIMEOUT at tile (%d,%d)\n", ty, tx);
                return -1;
            }
            uhd_stitch_tile(ty, tx);
        }
    }

    uint64_t t_end = read_mcycle();
    uint64_t total_cy = t_end - t_start;
    uint64_t hwpe_cy  = g_hwpe_cy_total;
    uint64_t sw_cy    = (total_cy > hwpe_cy) ? (total_cy - hwpe_cy) : 0;

    /* 20 MHz soc_clk → 1 cycle = 50 ns, 20,000 cy = 1 ms. */
    uint32_t total_ms = (uint32_t)(total_cy / 20000u);
    uint32_t hwpe_ms  = (uint32_t)(hwpe_cy  / 20000u);
    uint32_t sw_ms    = (uint32_t)(sw_cy    / 20000u);
    uint32_t hwpe_pct = (total_cy > 0) ? (uint32_t)((hwpe_cy * 10000u) / total_cy) : 0;

    /* Pixel throughput:
         pix/s = total_pix / (total_ms / 1000) = total_pix * 1000 / total_ms
         Mpix/s = pix/s / 1e6 = total_pix / (total_ms * 1000)
         Mpix/s × 1000 = total_pix / total_ms   ← integer-friendly form. */
    uint32_t total_pix = (uint32_t)UHD_W * (uint32_t)UHD_H;
    uint32_t mpix_x1000 = (total_ms > 0) ? (total_pix / total_ms) : 0;
    /* fps × 1000 (so 0.025 fps prints as "0.025") */
    uint32_t fps_x1000 = (total_ms > 0) ? (uint32_t)(1000000u / total_ms) : 0;

    printf("\n################ UHD THROUGHPUT ################\n");
    printf("  config           : %s\n", cfg->name);
    printf("  frame size       : %dx%d  (tiles=%d)\n", UHD_W, UHD_H, total);
    printf("  total wallclock  : %u cycles  (%u ms @ 20MHz)\n",
           (uint32_t)total_cy, total_ms);
    printf("  HWPE active      : %u cycles  (%u ms)  [%u.%02u%%]\n",
           (uint32_t)hwpe_cy, hwpe_ms, hwpe_pct / 100u, hwpe_pct % 100u);
    printf("  SW overhead      : %u cycles  (%u ms)\n",
           (uint32_t)sw_cy, sw_ms);
    printf("  pixel throughput : %u.%03u Mpix/s\n",
           mpix_x1000 / 1000u, mpix_x1000 % 1000u);
    printf("  frame rate       : %u.%03u fps\n",
           fps_x1000 / 1000u, fps_x1000 % 1000u);

    /* Step 4: SW-reference spot-check — hardcoded "key" positions + per-tile PRNG.
       Each check is bit-exact recursion at one pixel (2K..200K MAC depending on cfg).
       Total = 10 key + 576 * UHD_PER_TILE_SAMPLES additional (defaults to 586 points). */
    printf("\n################ UHD VERIFY (SW ref) ################\n");
    int spot_pass = 0, spot_fail = 0, spot_max_diff = 0, n_total = 0;
    int fail_examples = 0;
    volatile const int16_t *hw = (volatile const int16_t *)UHD_OUTPUT;

    static const int key_uy[UHD_N_SPOTS] = {
        0,     0, 1079, 2159, 2159,  540,  800, 1200, 1800,  999 };
    static const int key_ux[UHD_N_SPOTS] = {
        0,  3839, 1920, 3839,    0, 1920, 2700,  500, 3000, 2501 };

    /* Key positions */
    printf("  [key positions]\n");
    for (int s = 0; s < UHD_N_SPOTS; s++) {
        int uy = key_uy[s], ux = key_ux[s];
        int16_t hw_val = hw[uy * UHD_W + ux];
        int16_t sw_val = sw_uhd_pixel(cfg, uy, ux);
        int d = hw_val - sw_val; if (d < 0) d = -d;
        if (d > spot_max_diff) spot_max_diff = d;
        printf("    pix(%4d,%4d)  HW=%6d  SW=%6d  diff=%d  %s\n",
               uy, ux, hw_val, sw_val, d, (d <= 3) ? "ok" : "MISMATCH");
        if (d <= 3) spot_pass++; else spot_fail++;
        n_total++;
    }

    /* Per-tile PRNG samples: 1 random pixel within each 120x120 tile.
       Simple LCG keyed by tile index → deterministic, reproducible. */
    printf("  [per-tile random — %d tiles * %d sample(s) each]\n",
           ((UHD_H+UHD_TILE_OUT-1)/UHD_TILE_OUT) *
           ((UHD_W+UHD_TILE_OUT-1)/UHD_TILE_OUT),
           UHD_PER_TILE_SAMPLES);
    uint32_t rnd = 0x12345678u;
    int last_print = 0;
    for (int ty = 0; ty < UHD_H; ty += UHD_TILE_OUT) {
        for (int tx = 0; tx < UHD_W; tx += UHD_TILE_OUT) {
            for (int s = 0; s < UHD_PER_TILE_SAMPLES; s++) {
                rnd = rnd * 1664525u + 1013904223u;
                int dy = (rnd >> 16) % UHD_TILE_OUT;
                rnd = rnd * 1664525u + 1013904223u;
                int dx = (rnd >> 16) % UHD_TILE_OUT;
                int uy = ty + dy;
                int ux = tx + dx;
                if (uy >= UHD_H || ux >= UHD_W) continue;

                int16_t hw_val = hw[uy * UHD_W + ux];
                int16_t sw_val = sw_uhd_pixel(cfg, uy, ux);
                int d = hw_val - sw_val; if (d < 0) d = -d;
                if (d > spot_max_diff) spot_max_diff = d;
                if (d <= 3) spot_pass++;
                else {
                    spot_fail++;
                    if (fail_examples < 10) {
                        printf("    MISMATCH pix(%d,%d) HW=%d SW=%d diff=%d\n",
                               uy, ux, hw_val, sw_val, d);
                        fail_examples++;
                    }
                }
                n_total++;
            }
        }
        /* Progress marker every 300 positions */
        if (n_total - last_print >= 300) {
            printf("    ...%d/%d checked\n", n_total, UHD_N_SPOTS +
                   ((UHD_H+UHD_TILE_OUT-1)/UHD_TILE_OUT) *
                   ((UHD_W+UHD_TILE_OUT-1)/UHD_TILE_OUT) * UHD_PER_TILE_SAMPLES);
            last_print = n_total;
        }
    }

    printf("\n################ UHD RESULT ################\n");
    printf("  config=%s  UHD=%dx%d  verified points=%d\n",
           cfg->name, UHD_W, UHD_H, n_total);
    printf("  pass=%d  fail=%d  max_diff=%d\n", spot_pass, spot_fail, spot_max_diff);
    printf("  HWPE UHD out[0..4]=%d %d %d %d %d\n", hw[0], hw[1], hw[2], hw[3], hw[4]);
    printf("  >>> %s <<<\n", (spot_fail == 0 && spot_max_diff <= 3) ? "UHD PASS" : "UHD FAIL");

    /* Hint for exhaustive host-side comparison + PNG generation. */
    printf("\n[output] HWPE UHD image at DDR 0x%08x, size=%d bytes (%d x %d int16 LE)\n",
           UHD_OUTPUT, UHD_W * UHD_H * 2, UHD_W, UHD_H);
    printf("  Dump via GDB:\n");
    printf("    (gdb) dump binary memory /tmp/uhd_hw_%s.bin 0x%08x 0x%08x\n",
           cfg->name, UHD_OUTPUT, UHD_OUTPUT + UHD_W * UHD_H * 2);
    return 0;
}

#else  /* !UHD_DEMO — original multi-config sweep */

#define N_CFG ((int)(sizeof(CONFIGS)/sizeof(CONFIGS[0])))

int main(void)
{
    printf("\n################ SRCNN %d-config Sweep ################\n", N_CFG);

    /* Copy shared input to DDR3 once */
    volatile int16_t *ddr_input = (volatile int16_t *)DDR_INPUT;
    for (int i = 0; i < N_PIXELS; i++) ddr_input[i] = srcnn_input[i];
    printf("[main] DDR input ready. input[0..7]=%d %d %d %d %d %d %d %d\n",
           ddr_input[0], ddr_input[1], ddr_input[2], ddr_input[3],
           ddr_input[4], ddr_input[5], ddr_input[6], ddr_input[7]);

    int pass_cnt = 0, fail_cnt = 0;
    for (int c = 0; c < N_CFG; c++) {
        if (run_one_config(&CONFIGS[c]) == 0) pass_cnt++;
        else                                    fail_cnt++;
    }

    printf("\n################ SWEEP SUMMARY ################\n");
    printf("  PASS=%d  FAIL=%d  (out of %d)\n", pass_cnt, fail_cnt, N_CFG);
    if (fail_cnt == 0) printf("  >>> ALL %d CONFIGS PASS <<<\n", N_CFG);
    else               printf("  >>> %d CONFIG(S) FAILED <<<\n", fail_cnt);

    return 0;
}
#endif  /* UHD_DEMO */
