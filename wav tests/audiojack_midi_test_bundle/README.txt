AudioJack MIDI proof-of-concept
===============================

Purpose
-------
These WAV files attempt to drive a TRS MIDI input directly from a laptop
stereo headphone output, with NO adapter electronics.

What the files send
-------------------
MIDI channel: all 16 channels (so the synth's receive-channel setting should not matter)
Notes: C4, E4, G4, C5
Velocity: 100
Pattern repeats at five increasing digital amplitudes:
  35%, 50%, 65%, 80%, 95%

Files
-----
audiojack_midi_96k_normal.wav
audiojack_midi_96k_reversed_LR.wav
audiojack_midi_192k_normal.wav
audiojack_midi_192k_reversed_LR.wav

Suggested first test
--------------------
1. Use the 96 kHz NORMAL file first.
2. In macOS Audio MIDI Setup, set Built-in Output / Headphones to 96,000 Hz
   if that rate is available.
3. Connect an ordinary stereo 3.5 mm TRS cable from the Mac headphone output
   to the synth's TRS MIDI IN.
4. Start with Mac output volume around 20-25%.
5. Play the WAV locally.
6. If nothing happens, gradually raise the Mac output volume.
7. If still nothing happens, try the reversed-L/R file.
8. If 96 kHz fails and the Mac output supports 192 kHz, repeat with the 192 kHz files.

Important
---------
This is deliberately outside the MIDI electrical specification. The WAV uses
the two audio channels as a differential source: for MIDI-current-ON periods,
L and R are driven in opposite directions; for OFF periods, both are zero.

The files contain increasing signal levels, so you do NOT need to begin with
the Mac at full volume. Stop playback if anything behaves strangely.

A successful test should sound like C-E-G-C from the synth.
