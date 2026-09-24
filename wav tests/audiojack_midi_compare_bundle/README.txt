AudioJack MIDI comparison test
==============================

File 1:
  stress_90pct_noteon_zero_off.wav
  - 90% amplitude
  - Note Off encoded as Note On with velocity 0 (0x90 nn 00)

File 2:
  stress_98pct_standard_noteoff.wav
  - 98% amplitude
  - Original standard Note Off encoding (0x80 nn 00)

Everything else is kept the same as the previous stress test:
  - 96 kHz stereo PCM
  - reversed L/R polarity
  - MIDI channel 1
  - same program changes, velocity notes, chords, fast run,
    CC sweeps, pitch bend, MIDI clock, dense chords

What to compare:
  - Does F still stick in the first velocity sequence?
  - Are there any other stuck notes?
  - Are there unexpected preset changes outside the intentional opening section?
  - Does 98% improve the original note-off reliability?
  - Does velocity-0 Note Off eliminate the problem at 90%?
