//
//  MLIEC61937.h
//  Moonlight for macOS
//
//  IEC 61937 framing for AC-3 and E-AC-3 bitstream passthrough. Pure C with no
//  platform headers so it can be compiled and tested anywhere (tests/iec61937).
//
//  The output is what a CoreAudio device in the "cac3" / "cec3" physical format
//  expects: interleaved stereo 16-bit little-endian words, where one data burst
//  fills exactly one audio frame period of the carrier stream.
//

#ifndef MLIEC61937_H
#define MLIEC61937_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A burst occupies one audio frame period of the carrier, as stereo 16-bit
// frames: AC-3 is 1536 frames at 48 kHz, E-AC-3 is 6144 frames at 192 kHz.
#define ML_IEC61937_AC3_BURST_BYTES 6144
#define ML_IEC61937_EAC3_BURST_BYTES 24576
#define ML_IEC61937_PREAMBLE_BYTES 8

// Largest syncframes the formats can express. Both also have to fit a burst.
#define ML_IEC61937_AC3_MAX_FRAME_BYTES 2560
#define ML_IEC61937_EAC3_MAX_FRAME_BYTES 4096
#define ML_IEC61937_EAC3_BLOCKS_PER_BURST 6

#define ML_IEC61937_DATA_TYPE_NULL 0x00
#define ML_IEC61937_DATA_TYPE_AC3 0x01
#define ML_IEC61937_DATA_TYPE_PAUSE 0x03
#define ML_IEC61937_DATA_TYPE_EAC3 0x15

enum {
    ML_IEC61937_OK = 0,
    ML_IEC61937_ERR_ARGUMENT = -1,    // NULL pointer or zero size
    ML_IEC61937_ERR_TOO_SHORT = -2,   // not enough bytes for the header or the frame
    ML_IEC61937_ERR_SYNC = -3,        // missing 0x0B77
    ML_IEC61937_ERR_HEADER = -4,      // reserved or inconsistent header fields
    ML_IEC61937_ERR_UNSUPPORTED = -5, // valid frame the carrier cannot express (rate, dependent substream)
    ML_IEC61937_ERR_LENGTH = -6,      // input is longer than the frame its header announces
    ML_IEC61937_ERR_OVERFLOW = -7,    // payload does not fit the burst, or more than 6 blocks
    ML_IEC61937_ERR_BUFFER = -8       // output buffer too small
};

typedef struct {
    size_t frame_bytes;   // syncframe length announced by the header
    unsigned bsmod;       // AC-3 bitstream mode, carried in bits 8-10 of Pc (0 for E-AC-3)
    unsigned blocks;      // audio blocks in the frame (6 for AC-3)
    unsigned channels;    // full-bandwidth channels plus LFE, for logs only
} ml_iec61937_frame_info;

// Validate one syncframe at the start of data. Only the 48 kHz variants are
// accepted: the carrier formats the burst is built for run at 48 kHz (AC-3) and
// 4x48 kHz (E-AC-3). Both functions read the header only; the caller checks
// the length separately (the builders do).
int ml_iec61937_parse_ac3(const uint8_t *data, size_t len, ml_iec61937_frame_info *info);
int ml_iec61937_parse_eac3(const uint8_t *data, size_t len, ml_iec61937_frame_info *info);

// Build one AC-3 burst of ML_IEC61937_AC3_BURST_BYTES. frame must be exactly
// one syncframe. *out_len receives the burst size.
int ml_iec61937_build_ac3_burst(const uint8_t *frame, size_t frame_len,
                                uint8_t *out, size_t out_cap, size_t *out_len);

// E-AC-3 needs 6 audio blocks per burst. The host normally sends 6-block
// frames (one per burst); frames with fewer blocks are collected until 6 are
// present. A fresh state is all zero bytes or ml_iec61937_eac3_reset().
typedef struct {
    uint8_t payload[ML_IEC61937_EAC3_BURST_BYTES - ML_IEC61937_PREAMBLE_BYTES];
    size_t length;
    unsigned blocks;
} ml_iec61937_eac3_state;

void ml_iec61937_eac3_reset(ml_iec61937_eac3_state *state);

// Adds one syncframe. When the sixth block arrives the burst is written to out
// and *out_len is ML_IEC61937_EAC3_BURST_BYTES; before that *out_len is 0 and
// the return value is still ML_IEC61937_OK. On any error the state is reset,
// because a partial group can no longer be completed in sync.
int ml_iec61937_eac3_push(ml_iec61937_eac3_state *state, const uint8_t *frame, size_t frame_len,
                          uint8_t *out, size_t out_cap, size_t *out_len);

// Fill out[0..size) with a stream the receiver treats as "no audio, stay
// locked": a Pause burst (data type 3, Pd = 0) at the start of every period
// bytes, zeros in between. period == 0 or period > size produces zeros only.
// size and period should be multiples of 4 (one stereo frame).
int ml_iec61937_build_pause(uint8_t *out, size_t out_cap, size_t size, size_t period);

const char *ml_iec61937_strerror(int code);

#ifdef __cplusplus
}
#endif

#endif
