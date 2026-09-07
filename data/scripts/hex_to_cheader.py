#!/usr/bin/env python3
"""Convert a config's hex files to a C header for the SRCNN test.

Usage:
    python hex_to_cheader.py --config C1
    python hex_to_cheader.py --config C2

Reads from `data/configs/<Cn>_*/` — expects w1.hex, b1.hex, w2.hex, b2.hex,
w3.hex, b3.hex, golden.hex; plus shared `data/input_150x150.hex`.

Writes `sw/regression_tests/tcdm_tests/srcnn_test/srcnn_data_<Cn>.h`.

Each hex file: one int16 value per line, hex or decimal; lines that are
empty or start with '#' are skipped.
"""
import argparse
import re
from pathlib import Path


CONFIGS = {
    "C1": dict(name="C1_1-4-4-1",   ch=[1,  4,  4, 1]),
    "C2": dict(name="C2_1-8-8-1",   ch=[1,  8,  8, 1]),
    "C3": dict(name="C3_1-16-16-1", ch=[1, 16, 16, 1]),
    "C4": dict(name="C4_1-4-8-1",   ch=[1,  4,  8, 1]),
    "C5": dict(name="C5_1-8-16-1",  ch=[1,  8, 16, 1]),
    "C6": dict(name="C6_1-11-15-1", ch=[1, 11, 15, 1]),
    "C7": dict(name="C7_1-9-13-1",  ch=[1,  9, 13, 1]),
}


def parse_hex_file(path: Path) -> list[int]:
    """Parse one int16 value per line. File format: bare hex (e.g. FFDD, 0057).
    Also accepts explicit 0x-prefix or signed decimal with leading +/- sign.

    NOTE: bare unsigned digits (e.g. "0057") are treated as HEX (→ 0x57 = 87),
    never decimal — because the user's fixed-point Q8.8 hex files use this form.
    Decimal values must be explicitly signed (e.g. "-35" or "+123") to avoid
    ambiguity with pure-digit hex strings."""
    vals = []
    for raw in path.read_text().splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith(("0x", "0X", "-0x", "-0X", "+0x", "+0X")):
            v = int(s, 16)
        elif s.startswith(("-", "+")):
            # explicit sign → decimal
            v = int(s)
        else:
            # bare hex (pure digits or with A-F letters)
            v = int(s, 16)
            if v & 0x8000:
                v -= 0x10000
        vals.append(v)
    return vals


def emit_array(name: str, values: list[int], width: int = 16) -> str:
    lines = [f"static const int16_t {name}[{len(values)}] = {{"]
    buf = []
    for i, v in enumerate(values):
        buf.append(f"{v:6d}")
        if len(buf) == width:
            lines.append("    " + ", ".join(buf) + ",")
            buf = []
    if buf:
        lines.append("    " + ", ".join(buf))
    lines.append("};")
    return "\n".join(lines)


def _golden_filename(size):
    W, H = size
    return f"golden_{W}x{H}.hex"


def _input_filename(size):
    W, H = size
    return f"input_{W}x{H}.hex"


def _load_config_arrays(cdir: Path, cfg: dict, size=(150, 150)) -> dict:
    """Load and sanity-check w/b/golden for one config directory."""
    golden_name = _golden_filename(size)
    need = ["w1.hex", "b1.hex", "w2.hex", "b2.hex", "w3.hex", "b3.hex", golden_name]
    missing = [f for f in need if not (cdir / f).exists()]
    if missing:
        raise SystemExit(f"missing in {cdir}: {', '.join(missing)}")
    arrays = {
        "w1":     parse_hex_file(cdir / "w1.hex"),
        "b1":     parse_hex_file(cdir / "b1.hex"),
        "w2":     parse_hex_file(cdir / "w2.hex"),
        "b2":     parse_hex_file(cdir / "b2.hex"),
        "w3":     parse_hex_file(cdir / "w3.hex"),
        "b3":     parse_hex_file(cdir / "b3.hex"),
        "golden": parse_hex_file(cdir / golden_name),
    }
    c_in, c1, c2, c_out = cfg["ch"]
    W, H = size
    expect = {
        "w1":     c_in * c1 * 9,
        "b1":     c1,
        "w2":     c1 * c2 * 9,
        "b2":     c2,
        "w3":     c2 * c_out * 9,
        "b3":     c_out,
        "golden": W * H,
    }
    for k, arr in arrays.items():
        if len(arr) != expect[k]:
            raise SystemExit(f"{cfg['name']}/{k}: got {len(arr)} values, expected {expect[k]}")
    return arrays


def _write_single(args, root: Path):
    cfg   = CONFIGS[args.config]
    cdir  = root / "configs" / cfg["name"]
    size  = tuple(args.size)
    W, H  = size
    inp   = Path(args.input_hex) if args.input_hex else (root / _input_filename(size))
    if not inp.exists():
        raise SystemExit(f"missing input: {inp}")
    out   = Path(args.out) if args.out else (
        root.parent / "pulpissimo/sw/regression_tests/tcdm_tests/srcnn_test"
        / f"srcnn_data_{args.config}.h"
    )
    arr = _load_config_arrays(cdir, cfg, size)
    arr["input"] = parse_hex_file(inp)
    if len(arr["input"]) != W * H:
        raise SystemExit(f"input: got {len(arr['input'])} values, expected {W*H}")

    header = [
        f"/* Auto-generated from {cdir.relative_to(root.parent)}. Do not edit by hand. */",
        f"/* Config: {cfg['name']}  channels={cfg['ch']} */",
        f"#ifndef SRCNN_DATA_{args.config}_H",
        f"#define SRCNN_DATA_{args.config}_H",
        "#include <stdint.h>",
        "",
    ]
    name_map = {"w1":"srcnn_w1", "b1":"srcnn_b1", "w2":"srcnn_w2", "b2":"srcnn_b2",
                "w3":"srcnn_w3", "b3":"srcnn_b3", "input":"srcnn_input", "golden":"srcnn_golden"}
    for k in ("w1","b1","w2","b2","w3","b3","input","golden"):
        header.append(emit_array(name_map[k], arr[k]))
        header.append("")
    header.append(f"#endif /* SRCNN_DATA_{args.config}_H */")

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(header) + "\n")
    print(f"wrote {out}  ({sum(len(v) for v in arr.values())} int16 values)")


def _write_all(args, root: Path):
    """Emit one combined header containing all N configs + shared input,
    exposing a `CONFIGS[N]` struct array for runtime iteration."""
    size = tuple(args.size)
    W, H = size
    inp = Path(args.input_hex) if args.input_hex else (root / _input_filename(size))
    if not inp.exists():
        raise SystemExit(f"missing input: {inp}")
    input_vals = parse_hex_file(inp)
    if len(input_vals) != W * H:
        raise SystemExit(f"input: got {len(input_vals)} values, expected {W*H}")

    out = Path(args.out) if args.out else (
        root.parent / "pulpissimo/sw/regression_tests/tcdm_tests/srcnn_test"
        / "srcnn_data_all.h"
    )

    cfg_arrays = {}
    for cid, cfg in CONFIGS.items():
        cdir = root / "configs" / cfg["name"]
        cfg_arrays[cid] = _load_config_arrays(cdir, cfg, size)

    header = [
        f"/* Auto-generated combined header for all {len(CONFIGS)} SRCNN configs. Do not edit by hand. */",
        "#ifndef SRCNN_DATA_ALL_H",
        "#define SRCNN_DATA_ALL_H",
        "#include <stdint.h>",
        "",
        "typedef struct {",
        "    const char *name;",
        "    int l1_in, l1_out, l2_out, l3_out;",
        "    const int16_t *w1; int w1_n;",
        "    const int16_t *b1; int b1_n;",
        "    const int16_t *w2; int w2_n;",
        "    const int16_t *b2; int b2_n;",
        "    const int16_t *w3; int w3_n;",
        "    const int16_t *b3; int b3_n;",
        "    const int16_t *golden;",
        "} srcnn_config_t;",
        "",
    ]
    # Shared input
    header.append(emit_array("srcnn_input", input_vals))
    header.append("")

    # Per-config arrays
    for cid, arr in cfg_arrays.items():
        suf = "_" + cid
        for k in ("w1","b1","w2","b2","w3","b3","golden"):
            header.append(emit_array(f"srcnn_{k}{suf}", arr[k]))
            header.append("")

    header.append(f"static const srcnn_config_t CONFIGS[{len(CONFIGS)}] = {{")
    for cid, cfg in CONFIGS.items():
        c_in, c1, c2, c_out = cfg["ch"]
        arr = cfg_arrays[cid]
        suf = "_" + cid
        header.append(
            f"    {{ \"{cfg['name']}\", {c_in}, {c1}, {c2}, {c_out}, "
            f"srcnn_w1{suf}, {len(arr['w1'])}, srcnn_b1{suf}, {len(arr['b1'])}, "
            f"srcnn_w2{suf}, {len(arr['w2'])}, srcnn_b2{suf}, {len(arr['b2'])}, "
            f"srcnn_w3{suf}, {len(arr['w3'])}, srcnn_b3{suf}, {len(arr['b3'])}, "
            f"srcnn_golden{suf} }},"
        )
    header.append("};")
    header.append("")
    header.append("#endif /* SRCNN_DATA_ALL_H */")

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(header) + "\n")
    total_int16 = len(input_vals) + sum(sum(len(v) for v in a.values()) for a in cfg_arrays.values())
    print(f"wrote {out}  ({total_int16} int16 values, ~{total_int16*2//1024} KB)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", choices=list(CONFIGS.keys()),
                    help="emit single-config header (srcnn_data_<C>.h)")
    ap.add_argument("--all", action="store_true",
                    help="emit combined header with all configs (srcnn_data_all.h)")
    ap.add_argument("--input-hex", default=None,
                    help="override path to shared input hex (default: data/input_<W>x<H>.hex)")
    ap.add_argument("--out", default=None, help="override output header path")
    ap.add_argument("--size", nargs=2, type=int, default=[120, 120],
                    help="frame W H (default 120 120 — reads input_<W>x<H>.hex, golden_<W>x<H>.hex)")
    args = ap.parse_args()

    if not args.config and not args.all:
        ap.error("must specify --config <CN> or --all")
    if args.config and args.all:
        ap.error("--config and --all are mutually exclusive")

    root = Path(__file__).resolve().parent.parent
    if args.all:
        _write_all(args, root)
    else:
        _write_single(args, root)


if __name__ == "__main__":
    main()
