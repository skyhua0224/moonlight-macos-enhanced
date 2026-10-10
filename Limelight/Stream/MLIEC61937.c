//
//  MLIEC61937.c
//  Moonlight for macOS
//

#include "MLIEC61937.h"

#include <string.h>

#define SYNCWORD_BYTE0 0x0B
#define SYNCWORD_BYTE1 0x77

// IEC 61937-1 burst preamble words Pa and Pb.
#define BURST_SYNC_PA 0xF872
#define BURST_SYNC_PB 0x4E1F

// ATSC A/52 table E1.4: bit rates of frmsizecod / 2. At 48 kHz a syncframe is
// bitrate * 2 sixteen-bit words, i.e. bitrate * 4 bytes.
static const uint16_t kAc3BitrateKbps[19] = {
    32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640,
};
static const uint8_t kFullBandwidthChannels[8] = {2, 1, 2, 3, 3, 4, 4, 5};
static const uint8_t kEac3BlocksPerFrame[4] = {1, 2, 3, 6};

static unsigned read_bits(const uint8_t *data, unsigned bit_pos, unsigned count) {
    unsigned value = 0;
    for (unsigned i = 0; i < count; i++, bit_pos++) {
        value = (value << 1) | ((data[bit_pos >> 3] >> (7 - (bit_pos & 7))) & 1u);
    }
    return value;
}

static void write_le16(uint8_t *dst, unsigned value) {
    dst[0] = (uint8_t)(value & 0xFF);
    dst[1] = (uint8_t)((value >> 8) & 0xFF);
}

static void write_preamble(uint8_t *dst, unsigned pc, unsigned pd) {
    write_le16(dst + 0, BURST_SYNC_PA);
    write_le16(dst + 2, BURST_SYNC_PB);
    write_le16(dst + 4, pc);
    write_le16(dst + 6, pd);
}

// The bitstream is defined as a sequence of 16-bit words with the first byte
// in the high half. A little-endian 16-bit stream therefore needs every pair
// of payload bytes swapped. An odd last byte goes to the high half of its word
// (zero in the low half), which after the swap leaves the byte in the second
// position of the pair.
static size_t copy_payload_le16(uint8_t *dst, const uint8_t *src, size_t len) {
    size_t i = 0;
    for (; i + 1 < len; i += 2) {
        dst[i] = src[i + 1];
        dst[i + 1] = src[i];
    }
    if (i < len) {
        dst[i] = 0;
        dst[i + 1] = src[i];
        i += 2;
    }
    return i;
}

int ml_iec61937_parse_ac3(const uint8_t *data, size_t len, ml_iec61937_frame_info *info) {
    if (data == NULL || info == NULL) {
        return ML_IEC61937_ERR_ARGUMENT;
    }
    // Bytes 0-7 cover sync, crc1, fscod/frmsizecod, bsid/bsmod and the start of
    // the bit stream information up to lfeon.
    if (len < 8) {
        return ML_IEC61937_ERR_TOO_SHORT;
    }
    if (data[0] != SYNCWORD_BYTE0 || data[1] != SYNCWORD_BYTE1) {
        return ML_IEC61937_ERR_SYNC;
    }

    const unsigned fscod = data[4] >> 6;
    const unsigned frmsizecod = data[4] & 0x3F;
    if (fscod == 3 || frmsizecod > 37) {
        return ML_IEC61937_ERR_HEADER;
    }
    const unsigned bsid = data[5] >> 3;
    if (bsid > 10) {
        // 11 to 16 is E-AC-3 (or a future syntax); not ours to frame as AC-3.
        return ML_IEC61937_ERR_HEADER;
    }
    if (fscod != 0) {
        return ML_IEC61937_ERR_UNSUPPORTED;
    }

    unsigned bit = 6 * 8;
    const unsigned acmod = read_bits(data, bit, 3);
    bit += 3;
    if ((acmod & 1u) && acmod != 1) {
        bit += 2; // cmixlev
    }
    if (acmod & 4u) {
        bit += 2; // surmixlev
    }
    if (acmod == 2) {
        bit += 2; // dsurmod
    }
    const unsigned lfeon = read_bits(data, bit, 1);

    info->frame_bytes = (size_t)kAc3BitrateKbps[frmsizecod >> 1] * 4;
    info->bsmod = data[5] & 0x7;
    info->blocks = 6;
    info->channels = kFullBandwidthChannels[acmod] + lfeon;
    return ML_IEC61937_OK;
}

int ml_iec61937_parse_eac3(const uint8_t *data, size_t len, ml_iec61937_frame_info *info) {
    if (data == NULL || info == NULL) {
        return ML_IEC61937_ERR_ARGUMENT;
    }
    if (len < 6) {
        return ML_IEC61937_ERR_TOO_SHORT;
    }
    if (data[0] != SYNCWORD_BYTE0 || data[1] != SYNCWORD_BYTE1) {
        return ML_IEC61937_ERR_SYNC;
    }

    const unsigned strmtyp = data[2] >> 6;
    const unsigned substreamid = (data[2] >> 3) & 0x7;
    const unsigned frmsiz = ((data[2] & 0x7u) << 8) | data[3];
    const unsigned fscod = data[4] >> 6;
    const unsigned bsid = data[5] >> 3;

    if (strmtyp == 3 || bsid < 11 || bsid > 16) {
        return ML_IEC61937_ERR_HEADER;
    }
    const size_t frame_bytes = ((size_t)frmsiz + 1) * 2;
    if (frame_bytes < 8) {
        return ML_IEC61937_ERR_HEADER;
    }
    // Dependent substreams belong in the same burst as their independent frame,
    // which the host does not produce; a non-zero substream id likewise.
    if (strmtyp == 1 || substreamid != 0) {
        return ML_IEC61937_ERR_UNSUPPORTED;
    }
    // fscod 1 and 2 are 44.1 and 32 kHz; 3 selects a reduced rate in fscod2.
    if (fscod != 0) {
        return ML_IEC61937_ERR_UNSUPPORTED;
    }

    const unsigned numblkscod = (data[4] >> 4) & 0x3;
    const unsigned acmod = (data[4] >> 1) & 0x7;
    const unsigned lfeon = data[4] & 0x1;

    info->frame_bytes = frame_bytes;
    info->bsmod = 0;
    info->blocks = kEac3BlocksPerFrame[numblkscod];
    info->channels = kFullBandwidthChannels[acmod] + lfeon;
    return ML_IEC61937_OK;
}

int ml_iec61937_build_ac3_burst(const uint8_t *frame, size_t frame_len,
                                uint8_t *out, size_t out_cap, size_t *out_len) {
    if (frame == NULL || out == NULL || out_len == NULL) {
        return ML_IEC61937_ERR_ARGUMENT;
    }
    *out_len = 0;

    ml_iec61937_frame_info info;
    int status = ml_iec61937_parse_ac3(frame, frame_len, &info);
    if (status != ML_IEC61937_OK) {
        return status;
    }
    if (frame_len < info.frame_bytes) {
        return ML_IEC61937_ERR_TOO_SHORT;
    }
    if (frame_len > info.frame_bytes) {
        return ML_IEC61937_ERR_LENGTH;
    }
    if (info.frame_bytes + ML_IEC61937_PREAMBLE_BYTES > ML_IEC61937_AC3_BURST_BYTES) {
        return ML_IEC61937_ERR_OVERFLOW;
    }
    if (out_cap < ML_IEC61937_AC3_BURST_BYTES) {
        return ML_IEC61937_ERR_BUFFER;
    }

    // Pc: data type in bits 0-4, bitstream mode in bits 8-10, the rest zero.
    // Pd counts the payload in bits (rounded up to whole words).
    const size_t padded = (info.frame_bytes + 1) & ~(size_t)1;
    write_preamble(out, ML_IEC61937_DATA_TYPE_AC3 | (info.bsmod << 8), (unsigned)(padded * 8));
    const size_t written = copy_payload_le16(out + ML_IEC61937_PREAMBLE_BYTES, frame, info.frame_bytes);
    memset(out + ML_IEC61937_PREAMBLE_BYTES + written, 0,
           ML_IEC61937_AC3_BURST_BYTES - ML_IEC61937_PREAMBLE_BYTES - written);
    *out_len = ML_IEC61937_AC3_BURST_BYTES;
    return ML_IEC61937_OK;
}

void ml_iec61937_eac3_reset(ml_iec61937_eac3_state *state) {
    if (state != NULL) {
        state->length = 0;
        state->blocks = 0;
    }
}

int ml_iec61937_eac3_push(ml_iec61937_eac3_state *state, const uint8_t *frame, size_t frame_len,
                          uint8_t *out, size_t out_cap, size_t *out_len) {
    if (state == NULL || frame == NULL || out == NULL || out_len == NULL) {
        return ML_IEC61937_ERR_ARGUMENT;
    }
    *out_len = 0;

    ml_iec61937_frame_info info;
    int status = ml_iec61937_parse_eac3(frame, frame_len, &info);
    if (status == ML_IEC61937_OK) {
        if (frame_len < info.frame_bytes) {
            status = ML_IEC61937_ERR_TOO_SHORT;
        } else if (frame_len > info.frame_bytes) {
            status = ML_IEC61937_ERR_LENGTH;
        } else if (state->blocks + info.blocks > ML_IEC61937_EAC3_BLOCKS_PER_BURST ||
                   state->length + info.frame_bytes > sizeof(state->payload)) {
            status = ML_IEC61937_ERR_OVERFLOW;
        }
    }
    if (status != ML_IEC61937_OK) {
        // A group with a hole or a misfit can never be completed in sync.
        ml_iec61937_eac3_reset(state);
        return status;
    }

    memcpy(state->payload + state->length, frame, info.frame_bytes);
    state->length += info.frame_bytes;
    state->blocks += info.blocks;
    if (state->blocks < ML_IEC61937_EAC3_BLOCKS_PER_BURST) {
        return ML_IEC61937_OK;
    }

    if (out_cap < ML_IEC61937_EAC3_BURST_BYTES) {
        ml_iec61937_eac3_reset(state);
        return ML_IEC61937_ERR_BUFFER;
    }
    // Unlike AC-3, Pd counts bytes for E-AC-3.
    write_preamble(out, ML_IEC61937_DATA_TYPE_EAC3, (unsigned)state->length);
    const size_t written = copy_payload_le16(out + ML_IEC61937_PREAMBLE_BYTES, state->payload, state->length);
    memset(out + ML_IEC61937_PREAMBLE_BYTES + written, 0,
           ML_IEC61937_EAC3_BURST_BYTES - ML_IEC61937_PREAMBLE_BYTES - written);
    ml_iec61937_eac3_reset(state);
    *out_len = ML_IEC61937_EAC3_BURST_BYTES;
    return ML_IEC61937_OK;
}

int ml_iec61937_build_pause(uint8_t *out, size_t out_cap, size_t size, size_t period) {
    if (out == NULL || size == 0) {
        return ML_IEC61937_ERR_ARGUMENT;
    }
    if (period != 0 && period < ML_IEC61937_PREAMBLE_BYTES) {
        return ML_IEC61937_ERR_ARGUMENT;
    }
    if (out_cap < size) {
        return ML_IEC61937_ERR_BUFFER;
    }
    memset(out, 0, size);
    if (period != 0) {
        for (size_t offset = 0; offset + ML_IEC61937_PREAMBLE_BYTES <= size; offset += period) {
            write_preamble(out + offset, ML_IEC61937_DATA_TYPE_PAUSE, 0);
        }
    }
    return ML_IEC61937_OK;
}

const char *ml_iec61937_strerror(int code) {
    switch (code) {
    case ML_IEC61937_OK: return "ok";
    case ML_IEC61937_ERR_ARGUMENT: return "invalid argument";
    case ML_IEC61937_ERR_TOO_SHORT: return "frame is shorter than its header announces";
    case ML_IEC61937_ERR_SYNC: return "missing sync word";
    case ML_IEC61937_ERR_HEADER: return "invalid header fields";
    case ML_IEC61937_ERR_UNSUPPORTED: return "unsupported stream variant";
    case ML_IEC61937_ERR_LENGTH: return "data is longer than one frame";
    case ML_IEC61937_ERR_OVERFLOW: return "frame does not fit the burst";
    case ML_IEC61937_ERR_BUFFER: return "output buffer too small";
    default: return "unknown error";
    }
}
