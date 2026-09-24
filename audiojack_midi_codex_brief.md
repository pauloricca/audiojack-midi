# AudioJack MIDI — Codex Implementation Brief

## Goal

Build a small macOS utility that exposes a **virtual MIDI output port** and converts incoming MIDI messages into a stereo audio waveform suitable for direct connection:

**Mac headphone output → ordinary 3.5 mm TRS cable → hardware TRS MIDI IN**

No USB-MIDI interface, no adapter electronics.

This is an experimental / non-standard transport. It has already been proven to work on an M-Vave FM-1 using prerecorded WAV files.

---

## Proven test results

Target device:
- M-Vave FM-1
- MIDI channel: All
- Effects channel: 2
- TRS MIDI orientation that works corresponds to our **reversed L/R waveform polarity**

Audio transport:
- 96 kHz stereo PCM works
- 90–98% digital amplitude successfully produces valid MIDI notes
- 60% mostly produces corrupted MIDI / unintended Program Change messages
- 70% gives partial valid MIDI plus corruption
- 80%, 90%, and 98% successfully play simple scales

Known issue:
- In a longer stress-test WAV, F4 repeatedly gets stuck.
- Raising transport amplitude from 90% to 98% did not fix it.
- Replacing standard Note Off (`0x80 nn 00`) with Note On velocity zero (`0x90 nn 00`) caused *more* stuck notes in that particular prerecorded stress test.
- This suggests deterministic waveform / edge-alignment / byte-pattern effects rather than simple insufficient level.

Therefore the app should make physical-layer parameters easy to tweak live.

---

## MVP user experience

Launch app.

The app creates a CoreMIDI virtual destination named:

**AudioJack MIDI Out**

Any macOS MIDI-capable application can select this as an output.

Incoming MIDI bytes are serialized and emitted through the selected audio output.

UI can be extremely small:

- Audio output device dropdown
- Sample rate display / selector
- Output amplitude slider
- Polarity toggle:
  - Normal
  - Reversed
- Note-off encoding:
  - Standard `0x8n`
  - Note On velocity 0 `0x9n ... 00`
- Start / Stop output
- MIDI activity indicator
- Panic button
- Debug log

Defaults based on successful FM-1 testing:

- 96 kHz
- 90% amplitude
- Reversed polarity
- Standard Note Off

---

## CoreMIDI

Create a CoreMIDI virtual destination.

Suggested name:

`AudioJack MIDI Out`

Receive arbitrary incoming MIDI 1.0 messages.

Support at minimum:

- Note On
- Note Off
- CC
- Program Change
- Pitch Bend
- Channel Pressure
- Poly Aftertouch
- MIDI Clock
- Start / Continue / Stop
- SysEx eventually, but not required for first MVP

Preserve realtime MIDI messages correctly when interleaved with channel messages.

For the first version, MIDI 1.0 byte stream is enough.

---

## MIDI serial encoding

Encode MIDI as standard MIDI UART:

- 31,250 baud
- 8 data bits
- no parity
- 1 stop bit
- LSB first
- idle = logical 1
- start bit = logical 0

For each byte:

`start(0), d0, d1, d2, d3, d4, d5, d6, d7, stop(1)`

Do **not** round each MIDI bit to a fixed number of audio samples independently.

Use a fractional phase accumulator / absolute sample-time mapping so the average baud rate remains exactly 31,250 baud.

At 96 kHz:

`96000 / 31250 = 3.072 samples per bit`

The prerecorded proof-of-concept used absolute bit boundaries computed from time and rounded to sample indices.

---

## Stereo waveform

Working polarity from FM-1 tests:

For MIDI logical 0 / current-ON state:

- Left = `-amplitude`
- Right = `+amplitude`

For MIDI logical 1 / current-OFF state:

- Left = `0`
- Right = `0`

Default amplitude:

`0.90`

Allow adjustment roughly from 0.5 to 1.0.

Also provide a polarity toggle which swaps Left and Right.

Important:
The device responds only to the working polarity in our tests; opposite polarity produced no useful MIDI.

---

## Audio engine

Use CoreAudio / AVAudioEngine / AudioUnit — whichever gives reliable low-latency continuous stereo output and precise sample scheduling.

Requirements:

- preferably force / request 96 kHz output
- continuously render samples in real time
- keep an internal FIFO of serialized MIDI bits/messages
- avoid underruns
- preserve bit timing across audio buffer boundaries
- keep MIDI idle state at L=0, R=0 when no data is being sent

Do not restart the audio engine for every MIDI message.

---

## Important timing detail

A prerecorded WAV produced deterministic stuck-note behavior for one specific message pattern.

Therefore do not make assumptions that MIDI event spacing is irrelevant.

Keep:
- exact continuous UART timing while transmitting a message
- accurate message ordering
- idle gaps determined by real incoming MIDI timing

It may be useful to optionally enforce a tiny minimum inter-message idle period for debugging.

Add an advanced parameter:

`Inter-message idle bits: 0–4`

Default: `0`

This may be useful if the FM-1's optocoupler / audio coupling benefits from a short recovery interval.

---

## Debug / experimental controls

Put these under an “Advanced” disclosure:

### Sample rate
- 96 kHz default
- 192 kHz if hardware supports it

### Amplitude
- 0.50–0.99
- default 0.90

### Polarity
- Normal
- Reversed
- default Reversed

### Note Off representation
- Standard `0x8n`
- Note On velocity 0
- default Standard

### Inter-message idle
- 0–4 MIDI bit-times

### Byte monitor
Show incoming bytes in hex, e.g.

`90 3C 64`
`80 3C 00`

Optional second monitor showing the actual serialized waveform / bit pattern would be helpful.

---

## Panic button

Very important during development.

When clicked, send on all 16 channels:

- CC123 All Notes Off
- CC120 All Sound Off
- Pitch Bend center

Optionally also emit Note Off for all 128 notes on all channels.

Because this transport may occasionally corrupt a Note Off, Panic should be easy to reach.

---

## Test mode

Include a built-in test generator so the app can be tested without a DAW.

Buttons:

- Single C4
- C major scale
- C major chord
- Velocity test
- Fast-note test
- Program Change test
- Pitch-bend test
- Stress test

Also include a repeating diagnostic:

C4 → E4 → G4 → C5

This matches the successful prerecorded WAV test.

---

## Architecture suggestion

Keep the physical layer separate from CoreMIDI.

Suggested components:

### `MIDIVirtualPort`
Receives MIDI packets from CoreMIDI.

### `MIDISerializer`
Converts MIDI packets/messages into an ordered raw MIDI byte stream.

### `UARTEncoder`
Converts bytes into 31,250-baud 8N1 logical bits.

### `AudioBitstreamRenderer`
Turns logical UART state into stereo PCM samples using:
- exact phase accumulator
- amplitude
- polarity
- sample rate

### `AudioOutputEngine`
Feeds the rendered samples to CoreAudio continuously.

### `AppState`
Owns configuration and diagnostics.

This separation is important because we will probably iterate on the physical-layer encoding.

---

## First implementation milestone

Do not build a polished app first.

Milestone 1 should simply:

1. Create `AudioJack MIDI Out`
2. Receive Note On / Note Off from CoreMIDI
3. Render at 96 kHz
4. Reversed polarity
5. 90% amplitude
6. Send to headphone output
7. Successfully play notes on the FM-1

Once that works, add the UI and other MIDI messages.

---

## Safety / limitations

This is intentionally outside the official MIDI electrical specification.

The app should display a small warning such as:

> Experimental transport. AudioJack MIDI drives a TRS MIDI input from a headphone output and is not electrically compliant with the MIDI specification. Compatibility is not guaranteed.

Do not claim universal compatibility.

Likely compatibility depends on:
- headphone-output voltage
- output coupling/filtering
- device optocoupler/input circuit
- sample rate
- volume/amplitude
- TRS MIDI polarity/type

---

## Nice future features

- Auto-calibration wizard
- Send known test sequence and let user report success/failure
- Device profiles
- TRS Type A / B presets
- 192 kHz high-reliability mode
- MIDI file playback
- SysEx support
- Menu-bar mode
- Windows implementation using virtual MIDI + WASAPI
- Linux implementation via ALSA/JACK/PipeWire

---

## Current hypothesis to keep in mind

The transport is proven viable, but deterministic stuck-note behavior in one prerecorded stress test suggests the analogue path may have pattern-sensitive edge distortion.

The real-time app itself is a useful experiment because:
- real MIDI event timing will differ from the fixed WAV stress pattern
- parameter changes can be tested instantly
- sample rate, amplitude, polarity, idle spacing, and Note Off format can be adjusted live

Do not over-engineer around the stuck-F artifact before testing the real-time path.
