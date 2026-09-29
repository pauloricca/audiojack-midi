#!/usr/bin/env python3
from __future__ import annotations

import argparse
import math
from pathlib import Path


def parse_bits(text: str) -> list[int]:
    cleaned = text.replace(",", " ").replace("_", " ").strip()
    parts = cleaned.split()

    if len(parts) > 1:
        raw = "".join(parts)
    else:
        raw = cleaned.replace(" ", "")

    if not raw:
        raise ValueError("No bits supplied.")
    if any(ch not in "01" for ch in raw):
        raise ValueError("Bits must contain only 0 and 1.")

    return [int(ch) for ch in raw]


def parse_samples_arg(text: str, expected_len: int) -> list[int]:
    raw = text.replace(",", " ").split()
    values = [int(x) for x in raw]
    if len(values) != expected_len:
        raise ValueError(
            f"--samples must contain exactly {expected_len} values "
            f"(got {len(values)})."
        )
    if any(v <= 0 for v in values):
        raise ValueError("All sample durations must be positive integers.")
    return values


def rounded_sample_lengths(n_cols: int, sample_rate: float, baud: float) -> list[int]:
    samples_per_bit = sample_rate / baud
    boundaries = [round(i * samples_per_bit) for i in range(n_cols + 1)]
    return [boundaries[i + 1] - boundaries[i] for i in range(n_cols)]


def parse_comp_cols(text: str | None, labels: list[str]) -> set[int]:
    if not text:
        return set()

    tokens = [t.strip() for t in text.replace(",", " ").split() if t.strip()]
    label_map = {label.upper(): i for i, label in enumerate(labels)}

    result: set[int] = set()
    for token in tokens:
        t = token.upper()
        if t in label_map:
            result.add(label_map[t])
        elif t.startswith("D") and t[1:].isdigit():
            idx = 1 + int(t[1:])  # START is 0, D0 starts at 1
            if not (0 <= idx < len(labels)):
                raise ValueError(f"Comp column out of range: {token}")
            result.add(idx)
        elif t.isdigit():
            idx = int(t)
            if not (0 <= idx < len(labels)):
                raise ValueError(f"Comp column out of range: {token}")
            result.add(idx)
        else:
            raise ValueError(
                f"Unrecognised comp column '{token}'. "
                f"Use START, STOP, D0..D7, or numeric indices."
            )
    return result


def escape_xml(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def draw_vertical_grid(xs: list[float], y1: float, y2: float, stroke: str, width: float) -> str:
    parts = []
    for x in xs:
        parts.append(
            f'<line x1="{x:.3f}" y1="{y1:.3f}" x2="{x:.3f}" y2="{y2:.3f}" '
            f'stroke="{stroke}" stroke-width="{width}"/>'
        )
    return "".join(parts)


def draw_segmented_waveform(
    levels: list[int],
    boundaries_x: list[float],
    high_y: float,
    low_y: float,
    normal_color: str,
    comp_color: str,
    comp_cols: set[int],
    stroke_width: float = 3.0,
) -> str:
    """
    Draw each horizontal cell as its own segment so compensation cells can be red.
    Draw vertical transitions at boundaries.
    levels is 0/1 per column.
    """
    assert len(boundaries_x) == len(levels) + 1

    def y_for(level: int) -> float:
        return high_y if level == 1 else low_y

    parts: list[str] = []

    # horizontal segments
    for i, level in enumerate(levels):
        color = comp_color if i in comp_cols else normal_color
        y = y_for(level)
        x1 = boundaries_x[i]
        x2 = boundaries_x[i + 1]
        parts.append(
            f'<line x1="{x1:.3f}" y1="{y:.3f}" x2="{x2:.3f}" y2="{y:.3f}" '
            f'stroke="{color}" stroke-width="{stroke_width}" '
            f'stroke-linecap="square"/>'
        )

    # vertical transitions
    for i in range(len(levels) - 1):
        if levels[i] != levels[i + 1]:
            color = comp_color if (i in comp_cols or (i + 1) in comp_cols) else normal_color
            x = boundaries_x[i + 1]
            y1 = y_for(levels[i])
            y2 = y_for(levels[i + 1])
            parts.append(
                f'<line x1="{x:.3f}" y1="{y1:.3f}" x2="{x:.3f}" y2="{y2:.3f}" '
                f'stroke="{color}" stroke-width="{stroke_width}" '
                f'stroke-linecap="square"/>'
            )

    return "".join(parts)


def make_svg(
    bits: list[int],
    out_path: Path,
    sample_rate: float = 96_000.0,
    baud: float = 31_250.0,
    width: int = 1400,
    height: int = 760,
    samples: list[int] | None = None,
    comp_cols: set[int] | None = None,
) -> None:
    comp_cols = comp_cols or set()

    # Framed byte: START + data bits + STOP
    framed_bits = [0] + bits + [1]
    labels = ["START"] + [str(b) for b in bits] + ["STOP"]
    n_cols = len(framed_bits)

    if samples is None:
        samples = rounded_sample_lengths(n_cols, sample_rate, baud)

    if len(samples) != n_cols:
        raise ValueError("samples length must match number of framed columns")

    bit_us = 1_000_000.0 / baud
    sample_us = 1_000_000.0 / sample_rate

    # Ideal MIDI timing boundaries
    midi_boundaries_us = [i * bit_us for i in range(n_cols + 1)]

    # Actual audio timing boundaries from sample counts
    sample_boundaries = [0]
    for n in samples:
        sample_boundaries.append(sample_boundaries[-1] + n)
    audio_boundaries_us = [s * sample_us for s in sample_boundaries]

    total_us = max(midi_boundaries_us[-1], audio_boundaries_us[-1])

    # Layout
    margin_left = 90
    margin_right = 30
    margin_top = 40
    margin_bottom = 40

    plot_left = margin_left
    plot_right = width - margin_right
    plot_width = plot_right - plot_left

    label_y = 80

    midi_grid_top = 120
    midi_grid_bottom = 320

    l_grid_top = 370
    l_grid_bottom = 560

    r_grid_top = 590
    r_grid_bottom = 780 - margin_bottom

    def x_of_time(t_us: float) -> float:
        return plot_left + (t_us / total_us) * plot_width

    # MIDI boundaries x positions
    midi_xs = [x_of_time(t) for t in midi_boundaries_us]

    # Audio boundaries x positions
    audio_xs = [x_of_time(t) for t in audio_boundaries_us]

    # Sample grid x positions for lower rows
    max_sample_index = sample_boundaries[-1]
    sample_grid_xs = [x_of_time(i * sample_us) for i in range(max_sample_index + 1)]

    # Waveform levels
    # MIDI row: classic UART-style display: 1 high, 0 low
    midi_levels = framed_bits

    # L/R rows:
    # 0 bit -> L high / R low
    # 1 bit -> L low  / R high
    l_levels = [1 if b == 0 else 0 for b in framed_bits]
    r_levels = [0 if b == 0 else 1 for b in framed_bits]

    # Row y positions
    midi_high = 150
    midi_low = 260

    l_high = 430
    l_low = 510

    r_high = 650
    r_low = 730

    # Colors
    black = "#000000"
    blue = "#1f6fff"
    red = "#ff1e1e"
    midi_grid = "#9a9a9a"
    audio_grid = "#d3d3d3"

    svg_parts: list[str] = []

    # header
    svg_parts.append(
        f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg"
     width="{width}" height="{height}"
     viewBox="0 0 {width} {height}">
<rect x="0" y="0" width="{width}" height="{height}" fill="white"/>'''
    )

    # top labels
    for i, label in enumerate(labels):
        cx = (midi_xs[i] + midi_xs[i + 1]) / 2
        svg_parts.append(
            f'<text x="{cx:.3f}" y="{label_y:.3f}" text-anchor="middle" '
            f'font-family="Helvetica, Arial, sans-serif" font-size="24" fill="{black}">'
            f'{escape_xml(label)}</text>'
        )

    # row labels
    row_label_style = 'font-family="Helvetica, Arial, sans-serif" font-size="28" fill="black"'
    svg_parts.append(f'<text x="18" y="245" {row_label_style}>MIDI</text>')
    svg_parts.append(f'<text x="42" y="505" font-family="Helvetica, Arial, sans-serif" font-size="28" fill="{blue}">L</text>')
    svg_parts.append(f'<text x="42" y="725" font-family="Helvetica, Arial, sans-serif" font-size="28" fill="{blue}">R</text>')

    # grids
    svg_parts.append(draw_vertical_grid(midi_xs, midi_grid_top, midi_grid_bottom, midi_grid, 1.3))
    svg_parts.append(draw_vertical_grid(sample_grid_xs, l_grid_top, l_grid_bottom, audio_grid, 1.0))
    svg_parts.append(draw_vertical_grid(sample_grid_xs, r_grid_top, r_grid_bottom, audio_grid, 1.0))

    # waveforms
    svg_parts.append(
        draw_segmented_waveform(
            midi_levels, midi_xs,
            high_y=midi_high, low_y=midi_low,
            normal_color=black, comp_color=red,
            comp_cols=set(),  # keep ideal MIDI row black
            stroke_width=3.2,
        )
    )

    svg_parts.append(
        draw_segmented_waveform(
            l_levels, audio_xs,
            high_y=l_high, low_y=l_low,
            normal_color=blue, comp_color=red,
            comp_cols=comp_cols,
            stroke_width=3.2,
        )
    )

    svg_parts.append(
        draw_segmented_waveform(
            r_levels, audio_xs,
            high_y=r_high, low_y=r_low,
            normal_color=blue, comp_color=red,
            comp_cols=comp_cols,
            stroke_width=3.2,
        )
    )

    svg_parts.append("</svg>")

    out_path.write_text("".join(svg_parts), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate an SVG showing an ideal MIDI byte and sampled L/R waveforms."
    )
    parser.add_argument(
        "bits",
        help='Data bits only, e.g. "00101001" or "0 0 1 0 1 0 0 1"',
    )
    parser.add_argument(
        "-o", "--output",
        default="midi_byte.svg",
        help="Output SVG file (default: midi_byte.svg)",
    )
    parser.add_argument(
        "--sample-rate",
        type=float,
        default=96_000.0,
        help="Audio sample rate in Hz (default: 96000)",
    )
    parser.add_argument(
        "--baud",
        type=float,
        default=31_250.0,
        help="UART/MIDI baud rate (default: 31250)",
    )
    parser.add_argument(
        "--samples",
        help=(
            "Explicit sample lengths for START + data bits + STOP. "
            'Example for one byte: "3 3 3 3 3 3 3 3 3 4"'
        ),
    )
    parser.add_argument(
        "--comp",
        help=(
            "Columns to highlight red on L/R rows. "
            "Use START, STOP, D0..D7, or numeric indices. "
            'Example: --comp STOP or --comp "D4 STOP"'
        ),
    )
    parser.add_argument(
        "--width",
        type=int,
        default=1400,
        help="SVG width (default: 1400)",
    )
    parser.add_argument(
        "--height",
        type=int,
        default=760,
        help="SVG height (default: 760)",
    )

    args = parser.parse_args()

    bits = parse_bits(args.bits)
    labels = ["START"] + [str(b) for b in bits] + ["STOP"]

    if args.samples:
        samples = parse_samples_arg(args.samples, len(labels))
    else:
        samples = None

    comp_cols = parse_comp_cols(args.comp, labels)

    make_svg(
        bits=bits,
        out_path=Path(args.output),
        sample_rate=args.sample_rate,
        baud=args.baud,
        width=args.width,
        height=args.height,
        samples=samples,
        comp_cols=comp_cols,
    )

    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
