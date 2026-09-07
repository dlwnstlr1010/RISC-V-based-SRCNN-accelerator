#!/usr/bin/env python3
"""Compare HWPE-produced UHD output (dumped from DDR via GDB) against
the Python reference golden, produce a 4-panel PNG figure, and report
exhaustive-pixel statistics.

Inputs:
  --hw   path to HWPE output bin (from GDB `dump binary memory`)
  --cfg  config id (C1..C5) — used to find input/golden paths
  --size optional W H (default 3840 2160)
  --out-dir  output dir for PNGs (default: data/uhd/figures/)

Defaults assume:
  input   = data/uhd/input_<W>x<H>.bin
  golden  = data/uhd/golden_<cfg>_<W>x<H>.bin

Outputs:
  <out>/uhd_<cfg>_input.png   grayscale LR-bicubic input
  <out>/uhd_<cfg>_hwpe.png    HWPE produced SR
  <out>/uhd_<cfg>_sw.png      Python reference SR
  <out>/uhd_<cfg>_diff.png    |HW - SW|, amplified ×16 for visibility
  <out>/uhd_<cfg>_4panel.png  concatenated side-by-side for paper figure
  stdout:  full-pixel statistics (exact count, max_diff, histogram)
"""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image


def load_i16(path: Path, shape) -> np.ndarray:
    arr = np.fromfile(path, dtype=np.int16)
    if arr.size != shape[0] * shape[1]:
        raise SystemExit(f"{path}: got {arr.size} int16, expected {shape[0]*shape[1]}")
    return arr.reshape(shape)


def save_gray(path: Path, arr, vmin=0, vmax=255):
    a = np.clip(arr, vmin, vmax).astype(np.uint8)
    Image.fromarray(a, mode="L").save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hw",      required=True, help="HWPE output .bin (GDB dumped)")
    ap.add_argument("--cfg",     required=True, choices=["C1", "C2", "C3", "C4", "C5"])
    ap.add_argument("--size",    nargs=2, type=int, default=[3840, 2160])
    ap.add_argument("--input",   default=None, help="override input.bin path")
    ap.add_argument("--golden",  default=None, help="override golden.bin path")
    ap.add_argument("--out-dir", default=None)
    args = ap.parse_args()

    W, H = args.size
    root = Path(__file__).resolve().parent.parent                 # data/
    input_bin  = Path(args.input)  if args.input  else root / "uhd" / f"input_{W}x{H}.bin"
    golden_bin = Path(args.golden) if args.golden else root / "uhd" / f"golden_{args.cfg}_{W}x{H}.bin"
    out_dir    = Path(args.out_dir) if args.out_dir else root / "uhd" / "figures"
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"[load] HWPE  : {args.hw}")
    print(f"[load] input : {input_bin}")
    print(f"[load] golden: {golden_bin}")
    hw     = load_i16(Path(args.hw),    (H, W))
    inp    = load_i16(input_bin,         (H, W))
    sw     = load_i16(golden_bin,        (H, W))

    # ── Exhaustive pixel statistics ─────────────────────────────
    diff    = hw.astype(np.int32) - sw.astype(np.int32)
    abs_d   = np.abs(diff)
    exact   = int(np.sum(diff == 0))
    total   = H * W
    max_d   = int(abs_d.max())
    mean_d  = float(abs_d.mean())
    pass_cnt = int(np.sum(abs_d <= 3))

    print(f"\n################ UHD EXHAUSTIVE COMPARE ################")
    print(f"  config        : {args.cfg}")
    print(f"  resolution    : {W} x {H}  ({total:,} pixels)")
    print(f"  exact match   : {exact:,} / {total:,}  ({exact/total*100:.4f}%)")
    print(f"  |diff| ≤ 3    : {pass_cnt:,} / {total:,}  ({pass_cnt/total*100:.4f}%)")
    print(f"  max_diff      : {max_d}")
    print(f"  mean_diff     : {mean_d:.4f}")
    # diff histogram (coarse)
    for thresh in [0, 1, 2, 3, 5, 10, 100]:
        n = int(np.sum(abs_d <= thresh))
        print(f"    |d| ≤ {thresh:3d}: {n:,} ({n/total*100:.4f}%)")

    verdict = "UHD PASS" if max_d <= 3 else "UHD FAIL"
    print(f"  >>> {verdict} <<<")

    # ── PNG outputs ─────────────────────────────────────────────
    tag = f"uhd_{args.cfg}_{W}x{H}"
    save_gray(out_dir / f"{tag}_input.png",  inp)
    save_gray(out_dir / f"{tag}_hwpe.png",   hw)
    save_gray(out_dir / f"{tag}_sw.png",     sw)
    # Amplified diff so any difference is visible
    diff_vis = np.clip(abs_d * 16, 0, 255).astype(np.uint8)
    Image.fromarray(diff_vis, mode="L").save(out_dir / f"{tag}_diff.png")

    # 4-panel side-by-side for paper figure
    labels = ["Input (bicubic)", "HWPE output", "SW reference", "|diff| × 16"]
    panels = [inp, hw, sw, diff_vis.astype(np.int32)]
    # Downscale each panel to fit (optional — keep native for highest quality)
    panel_imgs = [np.clip(p, 0, 255).astype(np.uint8) for p in panels]
    bar = np.full((H, 4), 255, dtype=np.uint8)            # 4-pixel white separator
    combined = np.concatenate(
        [panel_imgs[0], bar, panel_imgs[1], bar, panel_imgs[2], bar, panel_imgs[3]], axis=1
    )
    Image.fromarray(combined, mode="L").save(out_dir / f"{tag}_4panel.png")

    print(f"\n[save] PNGs → {out_dir}/{tag}_*.png")


if __name__ == "__main__":
    main()
