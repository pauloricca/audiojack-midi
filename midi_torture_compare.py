#!/usr/bin/env python3
"""
AudioJack MIDI torture-test comparator.

Usage:
    python3 midi_torture_compare.py
        -> lists MIDI output devices only; sends nothing.

    python3 midi_torture_compare.py 2
        -> sends the torture test to MIDI output device index 2.

Dependencies:
    pip install mido python-rtmidi
"""

import argparse
import math
import random
import sys
import time

try:
    import mido
except ImportError:
    print("Missing dependency: mido")
    print("Install with: pip install mido python-rtmidi")
    sys.exit(1)


def list_outputs():
    names = mido.get_output_names()
    if not names:
        print("No MIDI output devices found.")
        return []

    print("Available MIDI output devices:")
    for i, name in enumerate(names):
        print(f"  [{i}] {name}")
    return names


def sleep_s(seconds):
    if seconds > 0:
        time.sleep(seconds)


def note_on(port, n, v=100, ch=0):
    port.send(mido.Message("note_on", note=n & 127, velocity=v & 127, channel=ch))


def note_off(port, n, ch=0):
    port.send(mido.Message("note_off", note=n & 127, velocity=0, channel=ch))


def cc(port, c, v, ch=0):
    port.send(mido.Message("control_change", control=c & 127, value=v & 127, channel=ch))


def pc(port, p, ch=0):
    port.send(mido.Message("program_change", program=p & 127, channel=ch))


def bend(port, value14, ch=0):
    value14 = max(0, min(16383, value14))
    port.send(mido.Message("pitchwheel", pitch=value14 - 8192, channel=ch))


def pressure(port, v, ch=0):
    port.send(mido.Message("aftertouch", value=v & 127, channel=ch))


def poly_pressure(port, n, v, ch=0):
    port.send(mido.Message("polytouch", note=n & 127, value=v & 127, channel=ch))


def test_1_note_velocity_matrix(port):
    print("1/11 Note + velocity matrix")
    for vel in [1, 8, 16, 32, 64, 96, 120, 127]:
        for n in range(48, 73):
            note_on(port, n, vel)
            sleep_s(.025)
            note_off(port, n)
            sleep_s(.008)


def test_2_identical_note_stacks(port):
    print("2/11 Repeated identical-note stacks")
    for n in [60, 65, 67]:
        for depth in [2, 3, 4, 6]:
            for _ in range(depth):
                note_on(port, n, 100)
                sleep_s(.008)
            sleep_s(.05)
            for _ in range(depth):
                note_off(port, n)
                sleep_s(.008)
            sleep_s(.04)


def test_3_dense_chords_and_clusters(port):
    print("3/11 Dense chords + clusters")
    chords = [
        [48, 55, 60, 64, 67, 72],
        [50, 57, 62, 65, 69, 74],
        [52, 59, 64, 67, 71, 76],
        list(range(60, 68)),
        [48, 52, 55, 59, 62, 65, 69, 72],
    ]
    for _ in range(3):
        for chord in chords:
            for n in chord:
                note_on(port, n, 100)
            sleep_s(.12)
            for n in reversed(chord):
                note_off(port, n)
            sleep_s(.04)


def test_4_fast_and_random_traffic(port):
    print("4/11 Fast chromatic + deterministic random traffic")
    for delay in [.02, .012, .008]:
        seq = list(range(36, 85)) + list(range(84, 35, -1))
        for n in seq:
            note_on(port, n, 90)
            sleep_s(delay)
            note_off(port, n)
            sleep_s(.003)

    rng = random.Random(12345)
    for _ in range(350):
        n = rng.randrange(36, 85)
        v = rng.randrange(1, 128)
        note_on(port, n, v)
        sleep_s(.006 + rng.random() * .012)
        note_off(port, n)
        sleep_s(.002)


def test_5_overlapping_arpeggios(port):
    print("5/11 Overlapping arpeggios")
    active = []
    for i in range(220):
        n = 48 + (i * 7) % 36
        note_on(port, n, 40 + (i * 13) % 88)
        active.append(n)
        if len(active) > 7:
            note_off(port, active.pop(0))
        sleep_s(.012)
    while active:
        note_off(port, active.pop(0))
        sleep_s(.004)


def test_6_cc_flood(port):
    print("6/11 CC flood")
    for ctrl in [1, 2, 7, 10, 11, 64, 71, 74]:
        vals = list(range(0, 128, 4)) + list(range(127, -1, -4))
        for v in vals:
            cc(port, ctrl, v)
            sleep_s(.003)

    cc(port, 7, 100)
    cc(port, 10, 64)
    cc(port, 11, 127)
    cc(port, 64, 0)


def test_7_bend_cc_and_pressure(port):
    print("7/11 Bend + CC + pressure interleaving")
    held = [48, 55, 60, 64, 67]
    for n in held:
        note_on(port, n, 100)

    for i in range(180):
        x = i / 179
        bend(port, round(8192 + 7000 * math.sin(x * math.pi * 8)))
        cc(port, 1, round(63.5 + 63.5 * math.sin(x * math.pi * 13)))
        pressure(port, round(63.5 + 63.5 * math.sin(x * math.pi * 5)))
        if i % 6 == 0:
            poly_pressure(port, 60, (i * 11) % 128)
        sleep_s(.006)

    for n in held:
        note_off(port, n)
    bend(port, 8192)
    cc(port, 1, 0)
    pressure(port, 0)
    sleep_s(.15)


def test_8_program_changes(port):
    print("8/11 Program-change barrage")
    for p in list(range(0, 32)) + [63, 64, 95, 127, 0]:
        pc(port, p)
        sleep_s(.035)


def test_9_realtime_and_notes(port):
    print("9/11 MIDI realtime + notes")
    for clocks_per_sec in [48, 96]:
        port.send(mido.Message("start"))
        for i in range(clocks_per_sec * 3):
            port.send(mido.Message("clock"))
            if i % 12 == 0:
                note_on(port, 60 + (i // 12) % 12, 90)
            if i % 12 == 6:
                note_off(port, 60 + (i // 12) % 12)
            sleep_s(max(.001, 1 / clocks_per_sec - .00032))
        port.send(mido.Message("stop"))
        sleep_s(.1)


def test_10_all_channels(port):
    print("10/11 All 16 MIDI channels")
    for ch in range(16):
        n = 48 + ch
        note_on(port, n, 70 + (ch * 3) % 50, ch)
        sleep_s(.018)
        note_off(port, n, ch)
        sleep_s(.006)


def test_11_dense_mixed_bursts(port):
    print("11/11 Final dense mixed-message bursts")
    for rep in range(30):
        ns = [
            48 + (rep * 3) % 24,
            55 + (rep * 5) % 20,
            60 + (rep * 7) % 18,
            72,
        ]
        for n in ns:
            note_on(port, n, 127)

        cc(port, 1, (rep * 17) % 128)
        bend(port, (rep * 997) % 16384)
        sleep_s(.035)

        for n in ns:
            note_off(port, n)
        sleep_s(.008)

    bend(port, 8192)
    cc(port, 1, 0)


def cleanup_all_notes(port):
    print("Cleanup: CC120/123 + triple 128-note sweep across all 16 channels")
    for ch in range(16):
        cc(port, 120, 0, ch)
        cc(port, 123, 0, ch)
        bend(port, 8192, ch)

    for _ in range(3):
        for ch in range(16):
            for n in range(128):
                note_off(port, n, ch)

    sleep_s(1.5)


def main():
    parser = argparse.ArgumentParser(
        description="List MIDI outputs, or send the AudioJack torture sequence to one by index."
    )
    parser.add_argument(
        "index",
        nargs="?",
        type=int,
        help="MIDI output device index. If omitted, only lists devices.",
    )
    args = parser.parse_args()

    names = list_outputs()

    if args.index is None:
        print("\nNo device index supplied: nothing was sent.")
        print("Run again with an index, e.g.: python3 midi_torture_compare.py 1")
        return

    if not names:
        sys.exit(1)

    if args.index < 0 or args.index >= len(names):
        print(f"\nInvalid index {args.index}. Valid range: 0..{len(names)-1}")
        sys.exit(2)

    name = names[args.index]
    print(f"\nSelected [{args.index}] {name}")
    print("Opening MIDI output and beginning torture test...")

    try:
        with mido.open_output(name) as port:
            started = time.monotonic()
            print("\nStarting MEGA torture test...")
            print("Ctrl-C will abort.\n")
            sleep_s(1.0)

            test_1_note_velocity_matrix(port)
            # test_2_identical_note_stacks(port)
            # test_3_dense_chords_and_clusters(port)
            # test_4_fast_and_random_traffic(port)
            # test_5_overlapping_arpeggios(port)
            # test_6_cc_flood(port)
            # test_7_bend_cc_and_pressure(port)
            # test_8_program_changes(port)
            # test_9_realtime_and_notes(port)
            # test_10_all_channels(port)
            # test_11_dense_mixed_bursts(port)
            # cleanup_all_notes(port)

            elapsed = time.monotonic() - started
            print(f"\nFinished in {elapsed:.1f}s.")
            print("If the device is now catatonic, congratulations: comparison achieved. 😂")
    except KeyboardInterrupt:
        print("\n\nAborted by user.")
        print("Attempting a small emergency panic...")
        try:
            with mido.open_output(name) as panic_port:
                for ch in range(16):
                    cc(panic_port, 120, 0, ch)
                    cc(panic_port, 123, 0, ch)
        except Exception:
            pass
        sys.exit(130)
    except Exception as e:
        print(f"\nMIDI error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
