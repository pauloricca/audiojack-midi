#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import math
from dataclasses import dataclass
from pathlib import Path

BLUE = "#0067ff"
RED = "#e22b2b"
BLACK = "#111111"
GRID = "#c8c8c8"

STRATEGIES = (
    "fixed3-stop",
    "fractional",
    "tail",
    "head",
    "both",
    "head-shape",
    "tail-shape",
)


@dataclass
class FrameBit:
    label: str
    value: int
    frame_index: int
    sample_start: int = 0
    sample_end: int = 0

    @property
    def duration(self) -> int:
        return self.sample_end - self.sample_start

    @property
    def debug_name(self) -> str:
        if self.frame_index == 0:
            return "START"
        if self.frame_index == 9:
            return "STOP"
        return f"D{self.frame_index - 1}"


@dataclass
class StrategyResult:
    frame: list[FrameBit]
    drive: list[float]
    highlights: set[int]
    notes: list[str]


def parse_bits(text: str) -> list[int]:
    cleaned = text.replace(",", " ").replace("_", " ").strip()
    tokens = list(cleaned) if " " not in cleaned and len(cleaned) == 8 else cleaned.split()
    if len(tokens) != 8 or any(t not in ("0", "1") for t in tokens):
        raise ValueError("bits must contain exactly eight 0/1 values, e.g. 01101001")
    return [int(t) for t in tokens]


def round_half_up(value: float) -> int:
    return int(math.floor(value + 0.5))


def make_frame(data_bits: list[int]) -> list[FrameBit]:
    values = [0] + data_bits + [1]
    labels = ["START"] + [str(x) for x in data_bits] + ["STOP"]
    return [FrameBit(label, value, i) for i, (label, value) in enumerate(zip(labels, values))]


def fractional_boundaries(count: int, sample_rate: int, baud: int) -> list[int]:
    spb = sample_rate / baud
    return [round_half_up(i * spb) for i in range(count + 1)]


def fixed3_stop_boundaries(sample_rate: int, baud: int) -> list[int]:
    if sample_rate != 96_000:
        return fractional_boundaries(10, sample_rate, baud)

    fraction = baud // 2
    fraction += 10 * sample_rate
    byte_samples = fraction // baud
    stop_samples = int(byte_samples - 27)

    durations = [3] * 9 + [stop_samples]
    out = [0]
    for duration in durations:
        out.append(out[-1] + duration)
    return out


def isolated_zero_frame_indexes(frame: list[FrameBit]) -> list[int]:
    values = [bit.value for bit in frame]
    return [
        i for i in range(1, 9)
        if values[i] == 0 and values[i - 1] == 1 and values[i + 1] == 1
    ]


def apply_strategy(
    data_bits: list[int],
    strategy: str,
    sample_rate: int,
    baud: int,
    shape_level: float,
) -> StrategyResult:
    frame = make_frame(data_bits)

    if sample_rate != 96_000 or strategy == "fractional":
        boundaries = fractional_boundaries(10, sample_rate, baud)
        effective_strategy = "fractional"
    else:
        boundaries = fixed3_stop_boundaries(sample_rate, baud)
        effective_strategy = strategy

    for bit, start, end in zip(frame, boundaries[:-1], boundaries[1:]):
        bit.sample_start = start
        bit.sample_end = end

    total_samples = boundaries[-1]
    drive = [0.0] * total_samples
    highlights: set[int] = set()
    notes: list[str] = []

    # MIDI logical 0 = current ON. MIDI logical 1 = current OFF.
    for bit in frame:
        if bit.value == 0:
            for sample in range(bit.sample_start, bit.sample_end):
                drive[sample] = 1.0

    # Mark timing cells that differ from the ordinary floor-sized audio cell.
    ordinary = max(1, int(math.floor(sample_rate / baud)))
    for bit in frame:
        delta = bit.duration - ordinary
        if delta > 0:
            for sample in range(bit.sample_end - delta, bit.sample_end):
                highlights.add(sample)
            notes.append(f"{bit.debug_name}: {bit.duration} samples (+{delta})")
        elif delta < 0:
            highlights.update(range(bit.sample_start, bit.sample_end))
            notes.append(f"{bit.debug_name}: {bit.duration} samples ({delta})")

    # Pulse shaping is a 96 kHz-only strategy, matching the app.
    if sample_rate == 96_000 and effective_strategy in (
        "tail", "head", "both", "head-shape", "tail-shape"
    ):
        for i in isolated_zero_frame_indexes(frame):
            bit = frame[i]

            if effective_strategy in ("head", "both", "head-shape"):
                sample = bit.sample_start - 1
                if sample >= 0:
                    drive[sample] = shape_level if effective_strategy == "head-shape" else 1.0
                    highlights.add(sample)
                    amount = f"{shape_level:g}× sample" if effective_strategy == "head-shape" else "1 sample"
                    notes.append(f"{bit.debug_name} head: {amount}")

            if effective_strategy in ("tail", "both", "tail-shape"):
                sample = bit.sample_end
                if sample < total_samples:
                    drive[sample] = shape_level if effective_strategy == "tail-shape" else 1.0
                    highlights.add(sample)
                    amount = f"{shape_level:g}× sample" if effective_strategy == "tail-shape" else "1 sample"
                    notes.append(f"{bit.debug_name} tail: {amount}")

    notes = list(dict.fromkeys(notes))
    if sample_rate != 96_000 and strategy != "fractional":
        notes.insert(0, f"{strategy} inactive at {sample_rate/1000:g} kHz; app uses fractional timing")

    return StrategyResult(frame, drive, highlights, notes)


def esc(text: str) -> str:
    return html.escape(text, quote=True)


def svg_text(x, y, text, size=26, weight="normal", anchor="middle", fill=BLACK):
    return (
        f'<text x="{x:.2f}" y="{y:.2f}" text-anchor="{anchor}" '
        f'font-family="Arial, Helvetica, sans-serif" font-size="{size}" '
        f'font-weight="{weight}" fill="{fill}">{esc(text)}</text>'
    )


def step_path(values: list[float], x0: float, dx: float, y_for_value) -> str:
    if not values:
        return ""
    parts = [f"M {x0:.2f} {y_for_value(values[0]):.2f}"]
    for i, value in enumerate(values):
        x_left = x0 + i * dx
        x_right = x_left + dx
        if i > 0 and values[i - 1] != value:
            parts.append(f"L {x_left:.2f} {y_for_value(value):.2f}")
        parts.append(f"L {x_right:.2f} {y_for_value(value):.2f}")
    return " ".join(parts)


def draw_highlight_overlay(values, highlighted, x0, dx, y_for_value):
    out = []
    for i in sorted(highlighted):
        if not 0 <= i < len(values):
            continue
        x_left = x0 + i * dx
        x_right = x_left + dx
        y = y_for_value(values[i])
        out.append(
            f'<line x1="{x_left:.2f}" y1="{y:.2f}" x2="{x_right:.2f}" y2="{y:.2f}" '
            f'stroke="{RED}" stroke-width="4" stroke-linecap="square"/>'
        )
        if i > 0 and values[i - 1] != values[i]:
            out.append(
                f'<line x1="{x_left:.2f}" y1="{y_for_value(values[i - 1]):.2f}" '
                f'x2="{x_left:.2f}" y2="{y:.2f}" stroke="{RED}" stroke-width="4"/>'
            )
        if i + 1 < len(values) and values[i + 1] != values[i]:
            out.append(
                f'<line x1="{x_right:.2f}" y1="{y:.2f}" '
                f'x2="{x_right:.2f}" y2="{y_for_value(values[i + 1]):.2f}" '
                f'stroke="{RED}" stroke-width="4"/>'
            )
    return out


def make_svg(
    data_bits: list[int],
    strategy: str,
    sample_rate: int = 96_000,
    baud: int = 31_250,
    wiring: str = "a",
    shape_level: float = 0.5,
    width: int = 1600,
    height: int = 900,
) -> str:
    result = apply_strategy(data_bits, strategy, sample_rate, baud, shape_level)
    frame = result.frame
    drive = result.drive

    left_margin = 92
    right_margin = 58
    plot_width = width - left_margin - right_margin

    midi_top = 155
    midi_low = 280
    midi_grid_top = 120
    midi_grid_bottom = 345

    l_base = 515
    r_base = 720
    amplitude_px = 72
    audio_grid_top = 405
    audio_grid_bottom = 800

    total_samples = len(drive)
    sample_dx = plot_width / total_samples
    bit_dx = plot_width / 10.0

    # Type A default: current ON => L=-A, R=+A. Type B swaps them.
    polarity = -1.0 if wiring.lower() == "a" else 1.0
    left_values = [polarity * d for d in drive]
    right_values = [-polarity * d for d in drive]

    def y_l(v):
        return l_base - v * amplitude_px

    def y_r(v):
        return r_base - v * amplitude_px

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="white"/>',
        svg_text(width - right_margin, 54, f"strategy: {strategy}", size=18, anchor="end", fill="#555555"),
    ]

    # Ideal MIDI bit grid + labels.
    for i, bit in enumerate(frame):
        x = left_margin + i * bit_dx
        lines.append(
            f'<line x1="{x:.2f}" y1="{midi_grid_top}" x2="{x:.2f}" y2="{midi_grid_bottom}" '
            f'stroke="#aaaaaa" stroke-width="1"/>'
        )
        lines.append(svg_text(x + bit_dx / 2, 82, bit.label, size=25))
    x_end = left_margin + 10 * bit_dx
    lines.append(
        f'<line x1="{x_end:.2f}" y1="{midi_grid_top}" x2="{x_end:.2f}" y2="{midi_grid_bottom}" '
        f'stroke="#aaaaaa" stroke-width="1"/>'
    )

    def midi_y(value):
        return midi_top if value else midi_low

    lines.append(
        f'<path d="{step_path([b.value for b in frame], left_margin, bit_dx, midi_y)}" '
        f'fill="none" stroke="{BLACK}" stroke-width="4" stroke-linejoin="miter" stroke-linecap="square"/>'
    )
    lines.append(svg_text(left_margin - 16, 265, "MIDI", size=30, anchor="end", weight="bold"))

    # Pale-red sample bands for every automatic strategy adjustment.
    for sample in sorted(result.highlights):
        x = left_margin + sample * sample_dx
        lines.append(
            f'<rect x="{x:.2f}" y="{audio_grid_top}" width="{sample_dx:.2f}" '
            f'height="{audio_grid_bottom - audio_grid_top}" fill="{RED}" opacity="0.055"/>'
        )

    # Audio sample grid.
    for sample in range(total_samples + 1):
        x = left_margin + sample * sample_dx
        lines.append(
            f'<line x1="{x:.2f}" y1="{audio_grid_top}" x2="{x:.2f}" y2="{audio_grid_bottom}" '
            f'stroke="{GRID}" stroke-width="1"/>'
        )

    # 0 V baselines.
    for y in (l_base, r_base):
        lines.append(
            f'<line x1="{left_margin}" y1="{y}" x2="{left_margin + plot_width}" y2="{y}" '
            f'stroke="#dddddd" stroke-width="1"/>'
        )

    # Actual AudioJack L/R signal.
    lines.append(
        f'<path d="{step_path(left_values, left_margin, sample_dx, y_l)}" fill="none" '
        f'stroke="{BLUE}" stroke-width="4" stroke-linejoin="miter" stroke-linecap="square"/>'
    )
    lines.append(
        f'<path d="{step_path(right_values, left_margin, sample_dx, y_r)}" fill="none" '
        f'stroke="{BLUE}" stroke-width="4" stroke-linejoin="miter" stroke-linecap="square"/>'
    )
    lines.extend(draw_highlight_overlay(left_values, result.highlights, left_margin, sample_dx, y_l))
    lines.extend(draw_highlight_overlay(right_values, result.highlights, left_margin, sample_dx, y_r))

    lines.append(svg_text(left_margin - 28, l_base + 10, "L", size=30, anchor="end", fill=BLUE))
    lines.append(svg_text(left_margin - 28, r_base + 10, "R", size=30, anchor="end", fill=BLUE))

    summary = "red = " + ("; ".join(result.notes) if result.notes else "no strategy adjustment in this byte")
    lines.append(svg_text(left_margin, 850, summary, size=17, anchor="start", fill="#555555"))
    lines.append("</svg>")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Draw ideal MIDI timing and AudioJack L/R waveform.")
    parser.add_argument(
        "bits", nargs="?", default="01101001",
        help='8 data bits, e.g. 01101001 or "0 1 1 0 1 0 0 1"',
    )
    parser.add_argument("--strategy", choices=STRATEGIES, default="tail")
    parser.add_argument("--sample-rate", type=int, default=96_000)
    parser.add_argument("--baud", type=int, default=31_250)
    parser.add_argument("--wiring", choices=("a", "b"), default="a")
    parser.add_argument("--shape-level", type=float, default=0.5)
    parser.add_argument("--width", type=int, default=1600)
    parser.add_argument("--height", type=int, default=900)
    parser.add_argument("--output", "-o", default="midi-waveform.svg")
    args = parser.parse_args()

    if args.sample_rate <= 0 or args.baud <= 0:
        parser.error("sample rate and baud must be positive")
    if not 0 <= args.shape_level <= 1:
        parser.error("--shape-level must be between 0 and 1")

    try:
        bits = parse_bits(args.bits)
    except ValueError as exc:
        parser.error(str(exc))

    Path(args.output).write_text(
        make_svg(
            bits,
            args.strategy,
            args.sample_rate,
            args.baud,
            args.wiring,
            args.shape_level,
            args.width,
            args.height,
        ),
        encoding="utf-8",
    )
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
