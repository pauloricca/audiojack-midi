# AudioJack MIDI

A small native macOS utility that turns the **AudioJack MIDI Out** virtual MIDI destination into a 31,250-baud stereo audio waveform. Intended connection: **Mac headphone output → ordinary 3.5 mm TRS cable → hardware TRS MIDI IN**.

Experimental transport. This is not electrically compliant with the MIDI specification; compatibility is not guaranteed. The implementation follows the supplied FM-1 brief, but successful playback on physical hardware still needs to be verified.

## Build and launch

Requires macOS 13 or later and an installed Xcode toolchain. There are no third-party package dependencies.

```sh
./scripts/build-app.sh
open "dist/AudioJack MIDI.app"
```

The script builds for the current Mac's architecture and creates an ad-hoc signed local app. It is not a notarized distribution build. You can also open `Package.swift` in Xcode, or use `swift run AudioJackMIDI` during development.

```sh
./scripts/test.sh
```

The scripts place compiler caches in the project so they also work in restricted development environments.

## First FM-1 test

1. Connect the headphone output to the FM-1's TRS MIDI input. Set the FM-1 MIDI channel to All, as in the brief.
2. Open the app and select **External Headphones** (or the corresponding stereo headphone device). The app opens with output stopped.
3. Keep the defaults: **96 kHz, 90% amplitude, Reversed polarity, Standard Note Off, **5 ms minimum message interval**, 0 idle bits**.
4. Click **Start adapter**, expand **Test generator**, then choose **Single C4** or **Repeat C4 → E4 → G4 → C5**. Test notes default to channel 1; the channel picker affects only the built-in generator.
5. In a DAW or MIDI application, choose **AudioJack MIDI Out** as its MIDI output. The byte monitor shows input even while audio output is stopped; stopped input is discarded, never replayed on Start.
6. Use **PANIC** or **Command–.** if notes get stuck. It cancels tests, drops queued traffic, finishes the current UART byte, then sends CC123, CC120, and pitch-bend center on all 16 channels. Stop and Quit send Panic before releasing audio, waiting asynchronously for all 48 paced Panic messages and a short output-drain period. Large intervals therefore also lengthen Stop and Quit.

Digital amplitude does not set macOS hardware volume. Output voltage still depends on system volume and the headphone hardware. The waveform is intended for a TRS MIDI input, not normal listening. This app does not change the system default output device or volume. Other software using the same physical output can mix audio into the signal.

## Controls and diagnostics

The main view shows the virtual port, listening/receiving status while active, selected audio device, and transport settings summary. Tests and the byte monitor are collapsed by default. While stopped, the adapter explicitly shows Paused; the virtual MIDI port remains available.

- **Adapter settings** (collapsed by default): amplitude 50–99%, Normal/Reversed polarity, standard Note Off or Note On velocity zero, 0–4 idle bit-times between complete messages, and 96/192 kHz.
- **Minimum message interval**: editable start-to-start spacing in milliseconds, default **5 ms**, range **0–60,000 ms**, including fractional values. Press Return to apply; 0 disables pacing. The audio renderer enforces this for virtual-port input, built-in tests, and Panic. Natural silence counts toward the interval; bytes inside a message retain their UART timing. The idle-bit setting remains an independent minimum silence after a message; the two limits overlap rather than adding together.
- Amplitude, polarity, note-off mode, message interval, and idle spacing apply while running. Stop output before changing device or sample rate. Note-off mode is latched when each message begins.
- The app requests the selected device's nominal sample rate and verifies it before starting; it does not silently fall back to 44.1/48 kHz. The device's rate remains at the requested setting after Stop. Rate changes or device disappearance detected while running stop output and display an error.
- The **IN** monitor shows original incoming bytes; **TEST** shows generator bytes. Conversion occurs afterward. The monitor is bounded and sampled to keep the UI responsive; it is not a lossless recording. Input counts include generated test traffic, sent counts include Panic, and sent/queued/dropped counters reset when a new audio engine starts.
- Eight test sequences cover a single note, scale, chord, velocities, fast notes, programs, pitch bends, and stress. The stress sequence includes repeated F4 (MIDI note 65) and overlapping notes. It is a new diagnostic, not a reproduction of the unavailable original WAV.
- Starting another test cancels future callbacks from the preceding sequence, preserves bytes already accepted by the audio FIFO, and queues explicit Note Offs before the replacement. Outstanding Note Ons are counted per channel and pitch: two outstanding Note Ons produce two Note Offs. Interrupted pitch bends are centered. Test restarts do not use the emergency Panic path or discard queued Note Offs. Panic interrupts pending future timestamps too. If the FIFO fills, the entire incoming batch is rejected, the drop counter increases, tests are cancelled, and an automatic Panic is requested.

## Implementation

- `MIDIVirtualPort`: CoreMIDI MIDI 1.0 virtual destination, with variable-length packet traversal and copies made inside the receive callback. Uses the byte-stream API deliberately for this MIDI 1.0 MVP.
- `MIDISerializer`: incremental byte-stream parsing, running-status expansion, channel/system message lengths, interleaved realtime preservation, optional Note Off conversion, and basic streaming SysEx passthrough.
- `TransportCore`: a C11 single-producer/single-consumer FIFO of 65,536 bytes, UART state machine, and stereo renderer. All producer access is serialized by `Transport`; the audio callback allocates nothing, takes no locks, logs nothing, and never calls Swift.
- `AudioOutputEngine`: a persistent CoreAudio HAL output unit bound to the chosen device, using two noninterleaved Float32 channels at its verified nominal rate.
- `AppState` / `TestGenerator`: native SwiftUI controls, diagnostics, transport lifecycle, and cancellable test scheduling.

Each UART byte is start 0, eight LSB-first data bits, stop 1. Reversed polarity maps logical 0 to L = −A / R = +A; logical 1 is silence. Normal swaps the two channels.

At **96 kHz**, START and each of the eight data bits are always **exactly 3 samples**. STOP is 3 or 4 samples, using a fractional byte-duration accumulator so contiguous bytes average **30.72 samples (320 µs)**. Each byte starts a fresh fixed-width active-bit clock; fractional correction is confined to the logical-1 STOP/idle region. Over 25 contiguous bytes, 18 have a four-sample STOP and 7 have a three-sample STOP. The STOP/idle remainder survives audio buffer boundaries and resets after an actual idle interval. Optional inter-message idle still adds 0–4 nominal bit-times, with rounding confined to silence.

This is an experiment to address the reported deterministic F4 release failure; hardware success is not yet verified. **192 kHz remains unchanged**, using absolute rounded bit boundaries with its original fractional bit accumulator.

CoreMIDI host timestamps are retained. Bytes are not started before their timestamp; late/immediate input starts as soon as the audio callback can consume it. FIFO arrival order wins when callers submit conflicting/out-of-order timestamps; this is not a sequencer that reorders events. Traffic above the configured message rate accumulates latency: the default 5 ms interval allows at most 200 messages/second, spreading out chords and dense controller traffic. The UART limit of 3,125 bytes/second also applies. Long SysEx messages are not split by the interval, and real-time bytes embedded within an unfinished message retain their position without an added gap. Audio hardware buffering adds latency, and wall-clock test-generator scheduling is not a hard realtime clock.

Use one logical MIDI stream at a time when sending fragmented messages or SysEx. The built-in generator and multiple clients should not inject channel messages into another sender's unfinished message. SysEx passthrough is included, but reliable large transfers over the physical connection are not validated.

## Validation

Automated tests cover:

- At 96 kHz, every byte value at every STOP accumulator phase is checked sample-by-sample: fixed three-sample START/data, three/four-sample STOP, and correct average byte duration. Existing stress-generator byte patterns, including F4 Note Off, use the same invariant. At 192 kHz, the original absolute rounded bit timing remains covered.
- Identical output across irregular audio buffer splits, silence, future timestamps, polarity, amplitude, and idle spacing. Message-interval tests verify start-to-start pacing, live changes, disabling, long intervals, byte preservation, fragmented messages, embedded real-time bytes, and completion of paced Panic output.
- Atomic overflow rejection and Panic decoding on all channels, including finishing an in-progress byte and bypassing future traffic.
- Running status, packet fragmentation, realtime interleaving, Note Off conversion, channel/system lengths, and SysEx.
- Balanced generator note-on/off pairs and F4 stress coverage. Restart regression tests cover every scale event boundary, 20 rapid Single C4 restarts decoded from the actual waveform, duplicate same-pitch voices, channel isolation, stale callback rejection, and interrupted pitch bends.
- A software CoreMIDI loopback with multiple variable-sized packets, including a packet longer than 256 bytes; no audio is emitted by this test.

The app has also been launched and its device picker, virtual-port readiness, and default controls inspected. Physical PCM output, headphone voltage, and FM-1 note reliability require the connected-hardware test above. The known F4 failure is not claimed to be fixed.

Apple API references: [CoreMIDI virtual destinations](https://developer.apple.com/documentation/coremidi/mididestinationcreate(_:_:_:_:_:)) and [HAL output device selection](https://developer.apple.com/documentation/audiotoolbox/kaudiooutputunitproperty_currentdevice).
