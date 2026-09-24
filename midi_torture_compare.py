#!/usr/bin/env python3
"""
AudioJack MIDI torture-test comparator.

Usage:
    python3 midi_torture_compare.py
        -> lists MIDI output devices only; sends nothing.

    python3 midi_torture_compare.py 2
        -> sends the torture test to MIDI output device index 2.

    python3 midi_torture_compare.py 2 --tests 12 13
        -> runs only the slow CC flood and CC1/bend isolation diagnostics.

    python3 midi_torture_compare.py 2 --tests 14
        -> sweeps CC1 spacing from 30 ms down to 1 ms, five seconds per stage.

    python3 midi_torture_compare.py 2 --tests 15
        -> compares note-message spacing at the same rates as test 14.

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
    print("1/15 Note + velocity matrix")
    for vel in [1, 8, 16, 32, 64, 96, 120, 127]:
        for n in range(48, 73):
            note_on(port, n, vel)
            sleep_s(.025)
            note_off(port, n)
            sleep_s(.008)


def test_2_identical_note_stacks(port):
    print("2/15 Repeated identical-note stacks")
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
    print("3/15 Dense chords + clusters")
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
    print("4/15 Fast chromatic + deterministic random traffic")
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
    print("5/15 Overlapping arpeggios")
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
    print("6/15 CC flood")
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
    print("7/15 Bend + CC + pressure interleaving")
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
    print("8/15 Program-change barrage")
    for p in list(range(0, 32)) + [63, 64, 95, 127, 0]:
        pc(port, p)
        sleep_s(.035)


def test_9_realtime_and_notes(port):
    print("9/15 MIDI realtime + notes")
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
    print("10/15 All 16 MIDI channels")
    for ch in range(16):
        n = 48 + ch
        note_on(port, n, 70 + (ch * 3) % 50, ch)
        sleep_s(.018)
        note_off(port, n, ch)
        sleep_s(.006)


def test_11_dense_mixed_bursts(port):
    print("11/15 Final dense mixed-message bursts")
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



def diagnostic_send(port, message, started):
    """Log intended bytes and elapsed time; this is not a receiver capture."""
    raw = " ".join(f"{byte:02X}" for byte in message.bytes())
    print(f"  +{time.monotonic() - started:7.3f}s  {raw:<8}  {message}", flush=True)
    port.send(message)


def test_12_slow_cc_flood(port):
    print("12/15 Slow CC flood — same sweep as test 6, 30 ms spacing", flush=True)
    started = time.monotonic()
    for ctrl in [1, 2, 7, 10, 11, 64, 71, 74]:
        print(f"  Controller {ctrl}", flush=True)
        vals = list(range(0, 128, 4)) + list(range(127, -1, -4))
        for value in vals:
            diagnostic_send(port, mido.Message("control_change", channel=0,
                            control=ctrl, value=value), started)
            sleep_s(.030)

    print("  Restore volume, pan, expression and sustain", flush=True)
    for ctrl, value in [(7, 100), (10, 64), (11, 127), (64, 0)]:
        diagnostic_send(port, mido.Message("control_change", channel=0,
                        control=ctrl, value=value), started)
        sleep_s(.030)


def test_13_cc1_and_bend_isolation(port):
    print("13/15 CC1 and pitch-bend isolation — no intentional program changes", flush=True)
    started = time.monotonic()

    def send(message):
        diagnostic_send(port, message, started)
        sleep_s(.030)

    print("  A: CC1 ONLY, every value up/down; no notes or bends", flush=True)
    for value in list(range(128)) + list(range(126, -1, -1)):
        send(mido.Message("control_change", channel=0, control=1, value=value))

    print("  Pause for 2 seconds; next phase begins with a held C4", flush=True)
    sleep_s(2)
    print("  B: PITCH BEND ONLY during held C4; no CC or pressure", flush=True)
    # Center before starting the note. The sweep uses the exact bend values from
    # tests 7 and 11, so failures can be compared without interleaved CC traffic.
    send(mido.Message("pitchwheel", channel=0, pitch=0))
    try:
        send(mido.Message("note_on", channel=0, note=60, velocity=100))
        print("  B1: Sine bends from test 7, slowed to 30 ms", flush=True)
        for i in range(180):
            value = round(8192 + 7000 * math.sin(i / 179 * math.pi * 8))
            send(mido.Message("pitchwheel", channel=0, pitch=value - 8192))
        print("  B2: Bend values from test 11, slowed to 30 ms", flush=True)
        for rep in range(30):
            send(mido.Message("pitchwheel", channel=0, pitch=(rep * 997) % 16384 - 8192))
    finally:
        print("  End isolated sweep: release C4 and center bend", flush=True)
        send(mido.Message("note_off", channel=0, note=60, velocity=0))
        send(mido.Message("pitchwheel", channel=0, pitch=0))
    sleep_s(2)



def test_14_cc1_spacing_sweep(port):
    print("14/15 CC1 spacing sweep — five seconds per stage", flush=True)
    print("  Watch for the FIRST unexpected preset change; later stages may inherit the fault.", flush=True)
    print("  Spacing is the requested sleep after each send; actual timing may be slower.", flush=True)
    # Repeat the same CC1 values as test 6 and restart the pattern at each stage.
    values = list(range(0, 128, 4)) + list(range(127, -1, -4))
    for spacing_ms in [30, 25, 20, 15, 10, 8, 6, 5, 4, 3, 2, 1]:
        print(f"\n  CC1 spaced at {spacing_ms} ms — 5 seconds", flush=True)
        started = time.monotonic()
        count = 0
        while time.monotonic() - started < 5.0:
            cc(port, 1, values[count % len(values)])
            count += 1
            # Never catch up with a burst if the OS wakes us late.
            sleep_s(spacing_ms / 1000)
        elapsed = time.monotonic() - started
        print(f"  Sent {count} messages in {elapsed:.2f}s "
              f"({elapsed * 1000 / count:.2f} ms/message average, including final wait)", flush=True)



def test_15_note_spacing_sweep(port):
    print("15/15 Note spacing sweep — five seconds per stage", flush=True)
    print("  Alternating C4 Note On (velocity 100) / standard Note Off (velocity 0).", flush=True)
    print("  Spacing applies after EVERY message, not after each on/off pair.", flush=True)
    print("  Start with the device recovered from earlier failures; watch for the FIRST fault.", flush=True)
    print("  Spacing is the requested sleep; short notes may sound like clicks or a buzz.", flush=True)
    for spacing_ms in [30, 25, 20, 15, 10, 8, 6, 5, 4, 3, 2, 1]:
        print(f"\n  Notes spaced at {spacing_ms} ms — 5 seconds", flush=True)
        started = time.monotonic()
        count = 0
        active = False
        try:
            while time.monotonic() - started < 5.0:
                # Finish each pair even if the five-second boundary falls between
                # its messages. No overlapping notes, CC, bends or preset changes.
                active = True
                note_on(port, 60, 100)
                count += 1
                sleep_s(spacing_ms / 1000)
                note_off(port, 60)
                active = False
                count += 1
                sleep_s(spacing_ms / 1000)
        finally:
            if active:
                note_off(port, 60)
        elapsed = time.monotonic() - started
        print(f"  Sent {count} messages in {elapsed:.2f}s "
              f"({elapsed * 1000 / count:.2f} ms/message average, including final wait)", flush=True)


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
    parser.add_argument(
        "--tests", nargs="+", type=int, choices=range(1, 16),
        metavar="N", help="Run only these test numbers in the given order (1–15). Default: all.",
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

            tests = [
                test_1_note_velocity_matrix,
                test_2_identical_note_stacks,
                test_3_dense_chords_and_clusters,
                test_4_fast_and_random_traffic,
                test_5_overlapping_arpeggios,
                test_6_cc_flood,
                test_7_bend_cc_and_pressure,
                test_8_program_changes,
                test_9_realtime_and_notes,
                test_10_all_channels,
                test_11_dense_mixed_bursts,
                test_12_slow_cc_flood,
                test_13_cc1_and_bend_isolation,
                test_14_cc1_spacing_sweep,
                test_15_note_spacing_sweep,
            ]
            for number in args.tests or range(1, len(tests) + 1):
                tests[number - 1](port)
            print("\nSelected tests finished; final cleanup is disabled", flush=True)
            cleanup_all_notes(port)

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
