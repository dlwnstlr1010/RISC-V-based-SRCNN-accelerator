#!/usr/bin/env python3
"""Generate UHD test-set for the SRCNN HWPE 'arbitrary-resolution' demo.

Pipeline:
  1. Fetch a public-domain grayscale source image (or use --src path).
  2. Bicubic-resize to TARGET resolution (default 3840x2160, UHD 4K).
  3. Quantize pixel values to int16 (0..255 range stored as int16 LE) → input.bin.
  4. For each selected config (C1..C5), run **bit-exact HW-equivalent inference**
     using the Q8.8 int16 weight/bias hex files that the HWPE loads, and save
     the resulting 3840x2160 int16 output → golden_Cn.bin.

Bit-exact means:
  • MACs are int32 accumulators (input_int × weight_int, both stored as is).
  • After the K-long MAC, right-shift by 8 (FIXED_BITS=8, arithmetic >>), add bias.
  • Apply ReLU for L1/L2 (not L3, which is the final reconstruction).
  • Clamp to int16 [-32768, 32767].

Outputs land in data/uhd/:
  input_3840x2160.bin
  golden_C1.bin ... golden_C5.bin
  (plus a small README.txt noting provenance)

Usage:
  python gen_uhd_testset.py                 # bicubic from data/srcnn_input.png
  python gen_uhd_testset.py --src some.png  # custom source image
  python gen_uhd_testset.py --download      # fetch DIV2K val 0801 (CC-BY)
  python gen_uhd_testset.py --config C1     # only one config
  python gen_uhd_testset.py --size 1024 1024   # custom resolution
"""
import argparse
import os
import sys
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image


CONFIGS = {
    "C1": dict(name="C1_1-4-4-1",   ch=[1,  4,  4, 1]),
    "C2": dict(name="C2_1-8-8-1",   ch=[1,  8,  8, 1]),
    "C3": dict(name="C3_1-16-16-1", ch=[1, 16, 16, 1]),
    "C4": dict(name="C4_1-4-8-1",   ch=[1,  4,  8, 1]),
    "C5": dict(name="C5_1-8-16-1",  ch=[1,  8, 16, 1]),
    "C6": dict(name="C6_1-11-15-1", ch=[1, 11, 15, 1]),
    "C7": dict(name="C7_1-9-13-1",  ch=[1,  9, 13, 1]),
}

FIXED_BITS = 8         # Q8.8 fixed-point right-shift between layers
PE_INT16_MIN = -32768
PE_INT16_MAX = 32767


# ──────────────────────────────────────────────────────────────────────────
# hex loader (matches data/scripts/hex_to_cheader.py's parse_hex_file rules)
# ──────────────────────────────────────────────────────────────────────────
def load_hex_int16(path: Path) -> np.ndarray:
    vals = []
    for raw in path.read_text().splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith(("0x", "0X", "-0x", "-0X", "+0x", "+0X")):
            v = int(s, 16)
        elif s.startswith(("-", "+")):
            v = int(s)
        else:
            v = int(s, 16)
            if v & 0x8000:
                v -= 0x10000
        vals.append(v)
    return np.asarray(vals, dtype=np.int32)


def load_config_tensors(cdir: Path, cfg):
    """Returns (w1, b1, w2, b2, w3, b3) as int32 numpy arrays with PyTorch-style
    [Cout, Cin, 3, 3] and [Cout] shapes."""
    c_in, c1, c2, c_out = cfg["ch"]
    w1 = load_hex_int16(cdir / "w1.hex").reshape(c1, c_in, 3, 3)
    b1 = load_hex_int16(cdir / "b1.hex").reshape(c1)
    w2 = load_hex_int16(cdir / "w2.hex").reshape(c2, c1, 3, 3)
    b2 = load_hex_int16(cdir / "b2.hex").reshape(c2)
    w3 = load_hex_int16(cdir / "w3.hex").reshape(c_out, c2, 3, 3)
    b3 = load_hex_int16(cdir / "b3.hex").reshape(c_out)
    return w1, b1, w2, b2, w3, b3


# ──────────────────────────────────────────────────────────────────────────
# Integer conv2d matching HWPE arithmetic bit-exactly.
# Input/weight/bias all int32. Output int32 (post-shift, post-bias, post-clamp).
# ──────────────────────────────────────────────────────────────────────────
def int_conv2d(x, w, b, apply_relu):
    """
    x: int32 [C_in, H, W]
    w: int32 [C_out, C_in, 3, 3]
    b: int32 [C_out]
    Returns int32 [C_out, H, W] clamped to int16 range.
    Zero-padding of 1 pixel around input (same as HWPE cur_is_pad).
    """
    import torch
    import torch.nn.functional as F

    # Promote int32 values to float32 — exact for abs values < 2^24, safe here.
    xt = torch.from_numpy(x).to(torch.float32).unsqueeze(0)   # [1, C_in, H, W]
    wt = torch.from_numpy(w).to(torch.float32)
    out_f = F.conv2d(xt, wt, bias=None, padding=1)            # [1, C_out, H, W]
    out_i64 = out_f.to(torch.int64).squeeze(0).numpy()        # [C_out, H, W]
    # Arithmetic >> FIXED_BITS (handles negatives correctly in numpy int).
    shifted = out_i64 >> FIXED_BITS
    shifted = shifted + b.reshape(-1, 1, 1).astype(np.int64)
    if apply_relu:
        shifted = np.maximum(shifted, 0)
    shifted = np.clip(shifted, PE_INT16_MIN, PE_INT16_MAX)
    return shifted.astype(np.int32)


def run_srcnn_int(x_in, cfg_tensors):
    """Run the 3-layer SRCNN using the loaded HW-hex tensors. x_in: int32 [H,W].
    Returns int16 [H,W] matching HWPE output for this config.

    NOTE: each layer uses zero-padding at the INPUT-TO-THIS-CALL boundary.
    For tile-based inference, caller is responsible for composing the input
    patch so that boundary behavior matches the HWPE tile driver (i.e., a
    single SRCNN call per tile, with tile-edge zero-padding at every layer)."""
    w1, b1, w2, b2, w3, b3 = cfg_tensors
    x0 = x_in.reshape(1, *x_in.shape).astype(np.int32)
    x1 = int_conv2d(x0, w1, b1, apply_relu=True)
    x2 = int_conv2d(x1, w2, b2, apply_relu=True)
    x3 = int_conv2d(x2, w3, b3, apply_relu=False)
    return x3[0].astype(np.int16)


def run_srcnn_tiled(uhd_in, cfg_tensors, tile_out=150, border=3):
    """Tile-based SRCNN matching the HWPE tile driver's behavior exactly.
    Each 156x156 patch is processed as an independent image; at every layer
    the padding is applied at the PATCH boundary (not the full-image boundary).
    UHD-image-boundary regions inside the patch are filled with zeros before
    the first layer (same as hwpe_extract_patch in test.c).
    """
    H, W = uhd_in.shape
    tile_in = tile_out + 2 * border
    uhd_out = np.zeros_like(uhd_in, dtype=np.int16)

    n_y = (H + tile_out - 1) // tile_out
    n_x = (W + tile_out - 1) // tile_out
    total = n_y * n_x
    idx = 0
    for ty in range(0, H, tile_out):
        for tx in range(0, W, tile_out):
            idx += 1
            if idx % 30 == 0 or idx == 1 or idx == total:
                print(f"      tile {idx}/{total}  (ty={ty}, tx={tx})")
            # Extract patch with zero-fill at UHD boundary (vectorized)
            patch = np.zeros((tile_in, tile_in), dtype=np.int32)
            y0, y1 = max(0, ty - border), min(H, ty - border + tile_in)
            x0, x1 = max(0, tx - border), min(W, tx - border + tile_in)
            dy0 = y0 - (ty - border)
            dx0 = x0 - (tx - border)
            patch[dy0:dy0 + (y1 - y0), dx0:dx0 + (x1 - x0)] = uhd_in[y0:y1, x0:x1]

            # Full SRCNN on 156x156 patch (layer padding at patch boundary)
            out = run_srcnn_int(patch, cfg_tensors)

            # Stitch center tile_out × tile_out back, clamping at UHD bounds
            uy_end = min(ty + tile_out, H)
            ux_end = min(tx + tile_out, W)
            dy_len = uy_end - ty
            dx_len = ux_end - tx
            uhd_out[ty:uy_end, tx:ux_end] = out[border:border + dy_len,
                                                 border:border + dx_len]
    return uhd_out


# ──────────────────────────────────────────────────────────────────────────
# Image fetch/prep
# ──────────────────────────────────────────────────────────────────────────
DIV2K_URL = (
    # DIV2K validation HR image #0801 (2K, CC-BY-4.0). Ideally ~2040x1404.
    "https://data.vision.ee.ethz.ch/cvl/DIV2K/validation_release/"
    "DIV2K_valid_HR/0801.png"
)


def fetch_div2k(dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() and dst.stat().st_size > 100_000:
        print(f"[fetch] already present: {dst}")
        return
    print(f"[fetch] downloading DIV2K 0801 → {dst}")
    try:
        urllib.request.urlretrieve(DIV2K_URL, dst)
    except Exception as e:
        raise SystemExit(f"download failed: {e}")


def prep_input(src_path: Path, target_wh) -> np.ndarray:
    img = Image.open(src_path).convert("L")
    print(f"[img]  source {src_path} size={img.size} → bicubic {target_wh}")
    img = img.resize(target_wh, Image.BICUBIC)
    arr = np.asarray(img, dtype=np.int32)   # [H, W] values 0..255
    return arr


# ──────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=None,
                    help="source image (default: data/srcnn_input.png or downloaded DIV2K)")
    ap.add_argument("--download", action="store_true",
                    help="download DIV2K 0801 as source if no --src")
    ap.add_argument("--size", nargs=2, type=int, default=[3840, 2160],
                    help="target W H (default 3840 2160 = UHD 4K)")
    ap.add_argument("--config", choices=list(CONFIGS.keys()), default=None,
                    help="generate golden for only one config (default: all 5)")
    ap.add_argument("--out-dir", default=None,
                    help="output dir (default: data/uhd/)")
    ap.add_argument("--whole", action="store_true",
                    help="run SRCNN as a single whole-frame pass (NOT matching HWPE tile driver).")
    ap.add_argument("--tile", type=int, default=120,
                    help="tile-out size for tile-based SRCNN (default 120 to match HWPE UHD_TILE_OUT)")
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent   # .../data
    out_dir = Path(args.out_dir) if args.out_dir else (root / "uhd")
    out_dir.mkdir(parents=True, exist_ok=True)

    # Resolve source
    if args.src:
        src = Path(args.src)
    elif args.download:
        src = out_dir / "_div2k_0801.png"
        fetch_div2k(src)
    else:
        src = root / "srcnn_input.png"
    if not src.exists():
        raise SystemExit(f"source image not found: {src}")

    W, H = args.size
    target_wh = (W, H)

    # ── Step 1: prep input & save ───────────────────────────────
    x_in = prep_input(src, target_wh)              # [H, W] int32 (0..255)
    print(f"[img]  array shape={x_in.shape} min={x_in.min()} max={x_in.max()}")
    input_bin = out_dir / f"input_{W}x{H}.bin"
    x_in.astype(np.int16).tofile(input_bin)
    print(f"[save] {input_bin}  ({input_bin.stat().st_size/1024/1024:.1f} MB, int16 LE)")

    # ── Step 2: per-config inference → golden ───────────────────
    # Mode: tile-based (matches HWPE tile driver bit-exactly) by default.
    # Single full-image pass is kept as an option via --whole (for reference).
    cfg_ids = [args.config] if args.config else list(CONFIGS.keys())
    for cid in cfg_ids:
        cfg = CONFIGS[cid]
        cdir = root / "configs" / cfg["name"]
        if not cdir.exists():
            print(f"[skip] {cid}: config dir missing ({cdir})")
            continue
        print(f"\n[{cid}] {cfg['name']} channels={cfg['ch']}")
        tensors = load_config_tensors(cdir, cfg)
        if args.whole:
            print(f"      whole-frame SRCNN (per-layer padding at UHD boundary)")
            y_out = run_srcnn_int(x_in, tensors)
        else:
            print(f"      tile-based SRCNN (tile_out={args.tile}, matches HWPE tile driver)")
            y_out = run_srcnn_tiled(x_in, tensors, tile_out=args.tile)
        golden_bin = out_dir / f"golden_{cid}_{W}x{H}.bin"
        y_out.tofile(golden_bin)
        print(f"[save] {golden_bin}  ({golden_bin.stat().st_size/1024/1024:.1f} MB)")
        print(f"       first 10 pix: {y_out[0, :10].tolist()}")
        print(f"       min={y_out.min()}  max={y_out.max()}  mean={y_out.mean():.1f}")

    # README
    readme = out_dir / "README.txt"
    readme.write_text(
        f"Generated by gen_uhd_testset.py\n"
        f"source image : {src}\n"
        f"target size  : {W} x {H}\n"
        f"format       : int16 little-endian, one pixel per 2 bytes, row-major\n"
        f"input file   : input_{W}x{H}.bin  ({W*H*2} bytes)\n"
        f"golden files : golden_Cn_{W}x{H}.bin, per config, same size\n"
        f"\n"
        f"Load into board DDR (GDB example):\n"
        f"  (gdb) restore /path/to/input_{W}x{H}.bin binary 0x80000000\n"
        f"  (gdb) restore /path/to/golden_C1_{W}x{H}.bin binary 0x84000000\n"
    )
    print(f"\n[done] outputs in {out_dir}")


if __name__ == "__main__":
    main()
