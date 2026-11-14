# DualSense Bluetooth audio player

This small macOS command-line helper enumerates a Bluetooth DualSense
(VID `0x054c`, PID `0x0ce6`), checks that a matching device is present, and
writes a 48 kHz stereo Opus stream through the Bluetooth HID audio report.
With no argument it generates a 30-second melody. A 16-bit PCM WAV or AIFF
path may be supplied as the first argument; the helper resamples it to 48 kHz
and duplicates mono input to stereo.

The protocol path follows the repository records
`ds5-gcsman-bt-audio-20261107` §§2–3, `ds5-dongle-audio-20261107` §§3–4,
`ds5-rfc6716-20261107` §§2.1.4, 2.1.8 and 3.1, and
`ds5-opus-api-20261107`. The helper emits the measured `0x39/547` double-frame
layout, 200-byte CBR Opus packets, per-report sequence and the `0xa2` CRC.
The `0x35/334` layout remains deliberately disabled until a current device
probe provides a complete, independently checked layout.

The pad plays each 0x39 slot for 21.333 ms, not the 20 ms inside two Opus
frames (ds5-gcsman-bt-audio-20261107, confirmed by ds5-dongle-audio-20261107
resampling 512 frames to 480). This player therefore reads 1024 source frames
per report and time-compresses each 512-frame half to 480 encoder frames
before Opus. That is the 512:480, or 16:15, pre-compensation. Without it the
speaker plays about a semitone flat. This helper has no haptic input, so the
two 64-byte haptic blocks stay zero; the application fills them from the host
PCM and can switch to a 142-byte 0x32 report when the speaker is off.

The helper uses Apple's asynchronous `IOHIDDeviceSetReportWithCallback` path,
keeps at most eight output reports, starts with a two-report jitter buffer,
drops stale queued audio, and uses a monotonic Mach clock for the 21.333 ms
report deadlines. Each report logs the call and completion times; the final
summary reports achieved audio reports per second, underruns, and dropped
frames. A jack transition read from the 0x31 input report refreshes the 0x31
control report before the next audio packet, so the control path and the
0x13/0x16 audio sub-packet change together.

The source is compiled on macOS with the repository's `ds5-core` C source and
the same libopus build used by the application. One possible command from the
repository root is:

```sh
clang -O2 -Wall -Wextra -Werror \
  tools/ds5-bt-audio/ds5_bt_audio.c \
  core/interaction/ds5-core/src/ds5_core.c \
  -Icore/interaction/ds5-core/include \
  -I/path/to/opus/include -L/path/to/opus/lib -lopus \
  -framework CoreFoundation -framework IOKit \
  -o "$HOME/tmp/ds5-bt-audio"
```

Before running it on a real device, confirm the pad is connected over
Bluetooth and that no stream is active. The program logs every output report,
its size and report ID, and exits without writing if no matching Bluetooth
device is present.
