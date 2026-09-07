#!/usr/bin/env python3
"""Generate a single-frame input + 5-config golden in hex format, matching
hex_to_cheader.py's parse rules (bare 4-digit hex, one value per line,
two's complement for negatives).

Writes:
  data/input_<W>x<H>.hex
  data/configs/C<n>_*/golden_<W>x<H>.hex   (for each of C1..C5)

Reuses the bit-exact integer SRCNN pipeline from gen_uhd_testset.py
(int_conv2d with >>8 after MAC, +bias, ReLU for L1/L2).

Usage:
  python3 gen_smallframe_hex.py --size 120 120
  python3 gen_smallframe_hex.py --size 120 120 --src path/to/image.png
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# Reuse the bit-exact pipeline from gen_uhd_testset.py
sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_uhd_testset import (  # type: ignore
    CONFIGS, load_config_tensors, int_conv2d, run_srcnn_int
)


def to_u16_hex(v: int) -> str:
    """Convert signed int16 to 4-char uppercase hex (two's complement)."""
    return f"{(v & 0xFFFF):04X}"


def save_hex(path: Path, arr: np.ndarray):
    flat = arr.astype(np.int32).flatten()
    path.write_text("\n".join(to_u16_hex(int(v)) for v in flat) + "\n")
    print(f"  [save] {path}  ({len(flat)} values)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", nargs=2, type=int, default=[120, 120],
                    help="target W H (default 120 120)")
    ap.add_argument("--src", default=None,
                    help="source image (default: data/srcnn_input.png)")
    args = ap.parse_args()

    W, H = args.size
    root = Path(__file__).resolve().parent.parent   # .../data
    src = Path(args.src) if args.src else (root / "srcnn_input.png")
    if not src.exists():
        raise SystemExit(f"source image not found: {src}")

    print(f"[img] source {src}  → bicubic {W}x{H}")
    img = Image.open(src).convert("L").resize((W, H), Image.BICUBIC)
    x_in = np.asarray(img, dtype=np.int32)
    print(f"      shape={x_in.shape}  min={x_in.min()}  max={x_in.max()}")

    input_hex = root / f"input_{W}x{H}.hex"
    save_hex(input_hex, x_in.astype(np.int16))

    for cid, cfg in CONFIGS.items():
        cdir = root / "configs" / cfg["name"]
        if not cdir.exists():
            print(f"[skip] {cid}: dir missing ({cdir})")
            continue
        print(f"\n[{cid}] {cfg['name']}  channels={cfg['ch']}")
        tensors = load_config_tensors(cdir, cfg)
        y_out = run_srcnn_int(x_in, tensors)       # int16 [H, W]
        golden_hex = cdir / f"golden_{W}x{H}.hex"
        save_hex(golden_hex, y_out)
        print(f"       first 8 out: {y_out.flatten()[:8].tolist()}")
        print(f"       min={y_out.min()}  max={y_out.max()}")

    print(f"\n[done] generated {W}x{H} input + 5 golden hex files.")


if __name__ == "__main__":
    main()
