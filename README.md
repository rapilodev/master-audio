# masterAudio.pl

master given audio file to -20dB RMS

```
This uses sox, ffmpeg and others to make both channels same loudness.
If target duration is given the file will be cut to the given duration.
Afterwards ffmpeg dynnorm is used to equalize loudness to -20dB RMS with a dynamic range of 6 dB. 
Files will be written to mp3 format.

--input PATH      source audio file
--output PATH     target audio file
--duration VALUE  target audio duration in seconds
--ffmpeg PATH     path to ffmpeg (requires version>=3.1)
--tempDir PATH    path to temporary directory, defaut is /tmp
--verbose LEVEL   verbose level
```
# masterAudioDaemon.pl

Frequently check audio files in a directory for given loudness and duration.
If files are too loud or long, they will be mastered using masterAudio.pl.
This uses calcms database to read and write metadata.
Mastered files will be written to <file>.master.mp3.