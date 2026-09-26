#!/usr/bin/env python3
"""
Volca Beats / AudioJack MIDI strategy tester.

Generates MIDI UART directly as stereo audio at 96 kHz and plays each
Volca Beats drum voice several times so different sample/timing strategies
can be compared on real hardware.

Dependencies:
    python3 -m pip install numpy sounddevice

Examples:
    python3 volca_audiojack_strategy_test.py --list-devices

    python3 volca_audiojack_strategy_test.py \
        --device "External Headphones" \
        --strategy fixed3-stop

    python3 volca_audiojack_strategy_test.py \
        --device "External Headphones" \
        --strategy fractional

    python3 volca_audiojack_strategy_test.py \
        --device "External Headphones" \
        --strategy tail

    python3 volca_audiojack_strategy_test.py \
        --device "External Headphones" \
        --strategy all

Important:
- Set the selected hardware output volume to 100%.
- Do not play other audio through the same physical output during the test.
- This deliberately sends Note On only. Volca drum voices do not need Note Off
  to retrigger, and omitting Note Off keeps the note-number experiment clean.
"""

from __future__ import annotations

import argparse
import math
import sys
import time
from dataclasses import dataclass

RATE = 96_000
BAUD = 31_250

# Korg Volca Beats note map.
# Volca Beats part order, matching Korg's part list / front-panel workflow:
# KICK, SNARE, LO TOM, HI TOM, CL HAT, OP HAT, CLAP, CLAVES, AGOGO, CRASH.
DRUMS = [
    ("kick", 36),
    ("snare", 38),
    ("low-tom", 43),
    ("high-tom", 50),
    ("closed-hat", 42),
    ("open-hat", 46),
    ("clap", 39),
    ("claves", 75),
    ("agogo", 67),
    ("crash", 49),
]

STRATEGIES = (
    "fixed3-stop",
    "fractional",
    "head",
    "tail",
    "both",
    "head-shape",
    "tail-shape",
)


@dataclass
class Slot:
    bit: int
    length: int
    byte_index: int
    frame_bit: int   # 0=START, 1..8=D0..D7, 9=STOP
    start: int = 0
    end: int = 0


def round_half_up(value: float) -> int:
    return int(math.floor(value + 0.5))


def uart_bits(byte: int) -> list[int]:
    """START(0), D0..D7 LSB-first, STOP(1)."""
    return [0] + [((byte >> i) & 1) for i in range(8)] + [1]


def fixed3_slots(message: list[int]) -> list[Slot]:
    """
    Match AudioJack MIDI's current 96 kHz scheme:

      START + D0..D7 = exactly 3 samples each.
      STOP absorbs the fractional byte-duration remainder.

    The fractional reservoir resets at the start of each MIDI message and
    continues across bytes within that message.
    """
    fraction = BAUD // 2
    slots: list[Slot] = []

    for byte_index, byte in enumerate(message):
        bits = uart_bits(byte)

        # START + 8 data bits.
        for frame_bit in range(9):
            slots.append(Slot(bits[frame_bit], 3, byte_index, frame_bit))

        # Same arithmetic as TransportCore.c.
        fraction += 10 * RATE
        byte_samples = fraction // BAUD
        fraction %= BAUD
        stop_samples = int(byte_samples - 9 * 3)

        slots.append(Slot(1, stop_samples, byte_index, 9))

    return slots


def fractional_slots(message: list[int]) -> list[Slot]:
    """
    Quantise the ideal MIDI bit grid to the nearest 96 kHz sample boundary.

    Unlike fixed3-stop, the occasional 4-sample interval appears where it is
    needed *inside* the UART stream rather than pushing all correction into STOP.

    Phase resets at the START of each MIDI message.
    """
    bits: list[tuple[int, int, int]] = []
    for byte_index, byte in enumerate(message):
        for frame_bit, bit in enumerate(uart_bits(byte)):
            bits.append((bit, byte_index, frame_bit))

    samples_per_bit = RATE / BAUD  # 3.072 at 96 kHz
    boundaries = [
        round_half_up(i * samples_per_bit)
        for i in range(len(bits) + 1)
    ]

    slots: list[Slot] = []
    for i, (bit, byte_index, frame_bit) in enumerate(bits):
        length = boundaries[i + 1] - boundaries[i]
        slots.append(Slot(bit, length, byte_index, frame_bit))

    return slots


def locate_slots(slots: list[Slot]) -> int:
    cursor = 0
    for slot in slots:
        slot.start = cursor
        cursor += slot.length
        slot.end = cursor
    return cursor


def isolated_zero_slots(slots: list[Slot]) -> list[int]:
    """
    Return indexes of *data* bits that are isolated logical zeroes:

        1, 0, 1

    Detection is intentionally byte-local and applies only to D0..D7.
    START is not considered a candidate.
    """
    by_byte: dict[int, list[int]] = {}
    for index, slot in enumerate(slots):
        by_byte.setdefault(slot.byte_index, []).append(index)

    result: list[int] = []

    for indexes in by_byte.values():
        # Each normal UART byte has START,D0..D7,STOP => 10 entries.
        if len(indexes) != 10:
            continue

        bits = [slots[i].bit for i in indexes]

        # Local frame positions 1..8 are data bits.
        for local in range(1, 9):
            if bits[local] == 0 and bits[local - 1] == 1 and bits[local + 1] == 1:
                result.append(indexes[local])

    return result


def message_drive(
    message: list[int],
    strategy: str,
    shape_level: float,
) -> "object":
    """
    Return one-dimensional 0..1 current-drive samples.

    0.0 = MIDI current OFF / both audio channels at zero.
    1.0 = full MIDI current ON / differential audio output.
    """
    import numpy as np

    if strategy == "fractional":
        slots = fractional_slots(message)
    else:
        slots = fixed3_slots(message)

    total = locate_slots(slots)
    drive = np.zeros(total, dtype=np.float32)

    # First render the ordinary UART values.
    for slot in slots:
        if slot.bit == 0:
            drive[slot.start:slot.end] = 1.0

    if strategy in ("head", "tail", "both", "head-shape", "tail-shape"):
        candidates = isolated_zero_slots(slots)

        for slot_index in candidates:
            slot = slots[slot_index]

            # One sample stolen from / shaped into the preceding logical 1.
            if strategy in ("head", "both", "head-shape") and slot.start > 0:
                if strategy == "head-shape":
                    drive[slot.start - 1] = shape_level
                else:
                    drive[slot.start - 1] = 1.0

            # One sample extended / shaped into the following logical 1.
            if strategy in ("tail", "both", "tail-shape") and slot.end < len(drive):
                if strategy == "tail-shape":
                    drive[slot.end] = shape_level
                else:
                    drive[slot.end] = 1.0

    return drive


def stereo_from_drive(drive, amplitude: float, wiring: str):
    """
    Convert current-drive samples to stereo audio.

    Type A:
        logical 0/current ON -> Tip/Left = -A, Ring/Right = +A

    Type B swaps polarity.
    """
    import numpy as np

    if wiring == "a":
        left = -drive * amplitude
        right = drive * amplitude
    else:
        left = drive * amplitude
        right = -drive * amplitude

    return np.column_stack((left, right)).astype(np.float32, copy=False)


def silence(ms: float):
    import numpy as np

    frames = round_half_up(RATE * ms / 1000.0)
    return np.zeros((frames, 2), dtype=np.float32)


def build_test(
    strategy: str,
    repeats: int,
    hit_gap_ms: float,
    voice_gap_ms: float,
    channel: int,
    velocity: int,
    amplitude: float,
    wiring: str,
    shape_level: float,
):
    import numpy as np

    chunks = [silence(100)]

    status = 0x90 | (channel - 1)

    for name, note in DRUMS:
        bits = "".join(str((note >> i) & 1) for i in range(8))
        print(
            f"  {name:10s} note={note:3d} 0x{note:02X} "
            f"D0..D7={bits}",
            flush=True,
        )

        for _ in range(repeats):
            # Note-On only: status, note number, velocity.
            message = [status, note, velocity]
            drive = message_drive(message, strategy, shape_level)
            chunks.append(stereo_from_drive(drive, amplitude, wiring))
            chunks.append(silence(hit_gap_ms))

        chunks.append(silence(voice_gap_ms))

    chunks.append(silence(150))
    return np.concatenate(chunks, axis=0)


def resolve_device(sd, device_arg: str | None):
    if device_arg is None:
        return None

    try:
        return int(device_arg)
    except ValueError:
        return device_arg


def strategy_description(strategy: str) -> str:
    return {
        "fixed3-stop":
            "current AudioJack scheme: 3-sample START/data, correction in STOP",
        "fractional":
            "nearest-sample ideal bit grid: distribute 3/4-sample correction through stream",
        "head":
            "extend isolated 0 one full sample earlier",
        "tail":
            "extend isolated 0 one full sample later",
        "both":
            "extend isolated 0 one full sample on both sides",
        "head-shape":
            "add a partial-amplitude sample before isolated 0",
        "tail-shape":
            "add a partial-amplitude sample after isolated 0",
    }[strategy]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Play Volca Beats drums through headphone-jack MIDI using selectable timing strategies."
    )
    parser.add_argument(
        "--strategy",
        choices=(*STRATEGIES, "all"),
        default="fixed3-stop",
        help="Waveform/timing strategy to test (default: fixed3-stop).",
    )
    parser.add_argument(
        "--device",
        help='sounddevice output device index or name, e.g. "External Headphones".',
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="List audio devices and exit.",
    )
    parser.add_argument(
        "--channel",
        type=int,
        default=1,
        help="MIDI channel 1-16 (default: 1).",
    )
    parser.add_argument(
        "--velocity",
        type=int,
        default=100,
        help="Note-On velocity 1-127 (default: 100).",
    )
    parser.add_argument(
        "--repeats",
        type=int,
        default=5,
        help="Hits per drum voice (default: 5).",
    )
    parser.add_argument(
        "--hit-gap-ms",
        type=float,
        default=70.0,
        help="Silence after each hit in ms (default: 70).",
    )
    parser.add_argument(
        "--voice-gap-ms",
        type=float,
        default=180.0,
        help="Extra silence between drum voices in ms (default: 180).",
    )
    parser.add_argument(
        "--strategy-gap-ms",
        type=float,
        default=1000.0,
        help="Pause between strategies when using --strategy all (default: 1000).",
    )
    parser.add_argument(
        "--amp",
        type=float,
        default=1.0,
        help="Digital peak amplitude 0..1 (default: 1.0).",
    )
    parser.add_argument(
        "--wiring",
        choices=("a", "b"),
        default="a",
        help="TRS MIDI wiring/polarity: a or b (default: a).",
    )
    parser.add_argument(
        "--shape-level",
        type=float,
        default=0.5,
        help="Partial sample level for *-shape strategies, 0..1 (default: 0.5).",
    )

    args = parser.parse_args()

    if not 1 <= args.channel <= 16:
        parser.error("--channel must be 1..16")
    if not 1 <= args.velocity <= 127:
        parser.error("--velocity must be 1..127")
    if args.repeats < 1:
        parser.error("--repeats must be >= 1")
    if not 0.0 < args.amp <= 1.0:
        parser.error("--amp must be > 0 and <= 1")
    if not 0.0 <= args.shape_level <= 1.0:
        parser.error("--shape-level must be between 0 and 1")
    if args.hit_gap_ms < 0 or args.voice_gap_ms < 0 or args.strategy_gap_ms < 0:
        parser.error("gap values must be >= 0")

    try:
        import numpy as np  # noqa: F401
        import sounddevice as sd
    except ImportError:
        print(
            "Missing dependency. Install with:\n"
            "  python3 -m pip install numpy sounddevice",
            file=sys.stderr,
        )
        return 2

    if args.list_devices:
        print(sd.query_devices())
        return 0

    device = resolve_device(sd, args.device)

    strategies = STRATEGIES if args.strategy == "all" else (args.strategy,)

    print(f"Sample rate: {RATE} Hz")
    print(f"MIDI baud:  {BAUD}")
    print(f"Amplitude:  {args.amp:.3f}")
    print(f"Wiring:     Type {args.wiring.upper()}")
    print(f"Channel:    {args.channel}")
    print(f"Repeats:    {args.repeats}")
    print()
    print("Make sure the physical output volume is 100% and no other audio is playing.")
    print()

    # Open once so --strategy all does not repeatedly tear down/reopen CoreAudio.
    try:
        with sd.OutputStream(
            samplerate=RATE,
            channels=2,
            dtype="float32",
            device=device,
            blocksize=0,
        ) as stream:
            for index, strategy in enumerate(strategies):
                if index:
                    gap = silence(args.strategy_gap_ms)
                    stream.write(gap)
                    time.sleep(0.05)

                print("=" * 72)
                print(f"STRATEGY: {strategy}")
                print(strategy_description(strategy))
                print("=" * 72)

                audio = build_test(
                    strategy=strategy,
                    repeats=args.repeats,
                    hit_gap_ms=args.hit_gap_ms,
                    voice_gap_ms=args.voice_gap_ms,
                    channel=args.channel,
                    velocity=args.velocity,
                    amplitude=args.amp,
                    wiring=args.wiring,
                    shape_level=args.shape_level,
                )

                stream.write(audio)
                print()

    except Exception as exc:
        print(f"Audio output failed: {exc}", file=sys.stderr)
        print(
            "\nTry --list-devices and pass the headphone output explicitly with --device.",
            file=sys.stderr,
        )
        return 1

    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
