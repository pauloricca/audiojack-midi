AudioJack MIDI Stress Test — 90% amplitude, 96 kHz
==================================================

FM-1 settings expected:
  MIDI channel: All
  Effects channel: 2

Signal:
  Reversed L/R polarity (the orientation that worked)
  MIDI channel 1
  31,250 baud UART encoded as stereo PCM
  90% digital amplitude

Sequence:
  1. Intentional Program Changes: 0, 5, 12, 31, 63, 1
  2. Single notes with velocities 20, 50, 80, 110, 127
  3. Several chords
  4. Fast note run
  5. CC1 modulation sweep while holding C4
  6. CC7 volume changes (restored to 100)
  7. Pitch-bend sweep while holding E4
  8. MIDI Start + 96 MIDI Clock messages + Stop
  9. Dense repeated four-note chords
  10. CC123 All Notes Off cleanup

What to watch for:
  - Preset changes should happen ONLY right at the beginning.
  - Notes/chords should sound clean and consistent.
  - If the FM-1 responds to CC1 or pitch bend, those changes should be smooth.
  - Unexpected preset changes later mean corrupted status bytes.
  - Stuck notes or random behaviour mean decoding is not fully reliable yet.
