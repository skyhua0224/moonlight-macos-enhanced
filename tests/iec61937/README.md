# IEC 61937 framer test

Checks `Limelight/Stream/MLIEC61937.c` against FFmpeg's `spdif` muxer. The
framer is plain C, so this runs on any machine with `gcc` and an `ffmpeg` that
has the `ac3`/`eac3` encoders and the `spdif` muxer. Nothing here is part of
the Xcode project.

```sh
tests/iec61937/run.sh [work-dir]      # default work dir: /tmp/ml-spdif-test
```

The script does the following, which can also be run by hand:

```sh
SRC=Limelight/Stream
gcc -std=c99 -Wall -Wextra -Werror -O2 -fsanitize=address,undefined \
    -I$SRC -o test_iec61937 tests/iec61937/test_iec61937.c $SRC/MLIEC61937.c
./test_iec61937 selftest          # error paths, accumulation, pause burst

# AC-3: encode, split into syncframes with our parser, build bursts, compare
ffmpeg -f lavfi -i "anoisesrc=d=4:c=pink:r=48000" -ac 6 -ar 48000 -c:a ac3 -b:a 640k -f ac3 in.ac3
ffmpeg -i in.ac3 -c copy -f spdif ref.spdif
./test_iec61937 ac3 in.ac3 ref.spdif

# E-AC-3: the same with the eac3 encoder
ffmpeg -f lavfi -i "anoisesrc=d=4:c=pink:r=48000" -ac 6 -ar 48000 -c:a eac3 -b:a 384k -f eac3 in.eac3
ffmpeg -i in.eac3 -c copy -f spdif ref.spdif
./test_iec61937 eac3 in.eac3 ref.spdif

# E-AC-3 frames with fewer than six blocks (accumulation)
./test_iec61937 oneblock in.eac3
```

`run.sh` repeats the comparison for 5.1, stereo and mono, a spread of bit rates
and non-zero `bsmod` values (`-audio_service_type`). The program exits non-zero
on any mismatch, a different burst count, or a trailing partial burst in the
reference.

The `oneblock` case is not compared with FFmpeg: it cannot remux a stream whose
`numblkscod` was rewritten. The test rewrites the headers itself and compares
with a naive second implementation of the burst layout instead.
