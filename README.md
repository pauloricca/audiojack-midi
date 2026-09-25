# AudioJack MIDI

A macOS utility that creates **AudioJack MIDI Out**, a virtual MIDI destination, and sends its MIDI data through an audio output. Connect a headphone jack to compatible MIDI hardware without a separate MIDI interface.

Use a normal 3.5 mm stereo TRS cable for a TRS MIDI input, or a correctly wired 3.5 mm TRS-to-5-pin-DIN MIDI cable for a DIN input. Type A and Type B wiring are supported.

## Download

Version **0.1.10**, for **macOS 12 Monterey or later**:

- [Apple silicon](website/downloads/AudioJack-MIDI-0.1.10-arm64.zip)
- [Intel](website/downloads/AudioJack-MIDI-0.1.10-x86_64.zip)

Unzip and move **AudioJack MIDI.app** to Applications. The app is ad-hoc signed, not notarized. If macOS blocks it, try opening it once, then choose **Open Anyway** in **System Settings → Privacy & Security**. On Monterey, use **System Preferences → Security & Privacy → General**. Confirm **Open**, and enter your login password if asked. Only approve a copy you trust. [Apple’s instructions](https://support.apple.com/en-gb/102445).

## Use

1. Connect the audio output to your instrument’s MIDI input.
2. Select the audio device and TRS wiring type. Set that device’s volume to 100% and unmute it.
3. Click **Start adapter** and follow **Calibration** to set signal level and message spacing. Match the test channel to your instrument.
4. Select **AudioJack MIDI Out** as the MIDI output in your DAW or MIDI app.

**Testing** sends notes and other MIDI messages without a DAW. **Panic** (⌘.) stops stuck notes on all channels. Stop and Quit also send Panic. MIDI received while paused is discarded.

## Compatibility

- The audio output must support **96 or 192 kHz stereo**. The app checks the selected rate before starting.
- This transport is not electrically MIDI compliant. Reliability depends on output voltage, cable wiring and receiving hardware; calibrate and test your setup. Large SysEx transfers have not been validated on hardware.
- Connect to a **MIDI input**, not headphones or speakers. Other software playing through the same output can interfere with the signal.
- The app does not change your system’s default output or volume. It changes the selected device’s sample rate, which remains set after stopping.

## Build

Requires an Xcode command-line toolchain with Swift 5.9 or later. No third-party dependencies.

```sh
./scripts/build-app.sh arm64
./scripts/build-app.sh x86_64
./scripts/test.sh
```

Apps are written to `dist/<architecture>/AudioJack MIDI.app`; versioned ZIPs go to `website/downloads/`. Both builds target macOS 12. Without an argument, the build script uses the current Mac’s architecture. For development, open `Package.swift` in Xcode or run `swift run AudioJackMIDI`.

Automated tests cover MIDI parsing, waveform timing, message pacing, Panic, test playback and CoreMIDI loopback. They do not establish compatibility with a particular physical instrument or replace testing on Monterey and Intel hardware.

[Source and issues](https://github.com/pauloricca/audiojack-midi)
