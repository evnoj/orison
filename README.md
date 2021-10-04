# orison
An isomorphic keyboard and pattern recorder for norns and grid using the PolySub engine.

### isomorphic keyboard
Columns 2-16 are a playing surface where notes increase in semitones on the x axis and 4ths on the y axis. The lit notes are C, with the more brightly lit notes being middle C.

You can transpose the range of the grid using (1,1) and (1,2).

### parameter control
The lit parameters on the screen are the ones currently controlled by the encoders. Press key 3 to switch which parameters are being controlled.

Control metronome functions by holding down key 2. While holding key 2:
	- key 3 toggles metronome tick
	- encoder 1 controls the bpm of the internal clock
	- encoders 2 and 3 control the division of the metronome tick
	- holding key 1 and turning encoder 1 controls tick volume

### pattern recording
(1,3) and (1,4) control patterns 1 and 2, respectively. While holding (1,7), press one of the pattern keys to arm that pattern for recording. Recording will begin as soon as you press a note. Press the pattern button again to stop recording and start looping the pattern. The pattern button will now start and stop the pattern.

You can control the speed of a pattern with the "px tf" parameters displayed on the screen.

To record a pattern synced to the internal clock, hold (1,6) instead of (1,7) when starting a recording. When a pattern is synced to the clock, you have control over the numerator and divisor of a time multiplier to achieve synchronized tempo changing.

### note holding
The hold button(1,8), when pressed, will hold all notes currently being pressed down, so that you can release them and they will continue to sound until you press the hold button again. To add to the notes currently being held, press (1,7) and the hold button and press any notes you want to add. To release only some notes, do the same but press currently held notes.