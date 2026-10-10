// Checks the IEC 61937 framer against FFmpeg's spdif muxer, byte for byte, and
// exercises its error paths. Built with plain gcc; see README.md.
//
//   test_iec61937 selftest
//   test_iec61937 ac3  <in.ac3>  <ref.spdif>
//   test_iec61937 eac3 <in.eac3> <ref.spdif>
//   test_iec61937 oneblock <in.eac3>   (fewer-block frames, checked without ffmpeg)

#include "MLIEC61937.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond, ...)                                  \
    do {                                                  \
        if (!(cond)) {                                    \
            failures++;                                   \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);   \
            printf(__VA_ARGS__);                          \
            printf("\n");                                 \
        }                                                 \
    } while (0)

static uint8_t *read_file(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        perror(path);
        exit(2);
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc(n > 0 ? (size_t)n : 1);
    if (buf == NULL || fread(buf, 1, (size_t)n, f) != (size_t)n) {
        fprintf(stderr, "cannot read %s\n", path);
        exit(2);
    }
    fclose(f);
    *size = (size_t)n;
    return buf;
}

// Compare produced bursts with the reference file as they appear. Returns the
// number of mismatching bursts.
typedef struct {
    const uint8_t *ref;
    size_t ref_size;
    size_t burst_bytes;
    size_t compared;
    size_t mismatched;
} Comparison;

static void compare_burst(Comparison *c, const uint8_t *burst) {
    size_t off = c->compared * c->burst_bytes;
    c->compared++;
    if (off + c->burst_bytes > c->ref_size) {
        c->mismatched++;
        printf("burst %zu: reference ends early\n", c->compared - 1);
        return;
    }
    if (memcmp(burst, c->ref + off, c->burst_bytes) != 0) {
        size_t i = 0;
        while (burst[i] == c->ref[off + i]) {
            i++;
        }
        c->mismatched++;
        if (c->mismatched <= 3) {
            printf("burst %zu differs at byte %zu: ours %02x ref %02x\n", c->compared - 1, i, burst[i], c->ref[off + i]);
        }
    }
}

static int run_stream(int eac3, const char *input_path, const char *ref_path) {
    size_t in_size, ref_size;
    uint8_t *in = read_file(input_path, &in_size);
    uint8_t *ref = read_file(ref_path, &ref_size);
    uint8_t burst[ML_IEC61937_EAC3_BURST_BYTES];
    ml_iec61937_eac3_state state;
    ml_iec61937_eac3_reset(&state);

    Comparison c = {ref, ref_size, eac3 ? ML_IEC61937_EAC3_BURST_BYTES : ML_IEC61937_AC3_BURST_BYTES, 0, 0};
    size_t frames = 0, off = 0, channels = 0, errors = 0;
    unsigned blocks = 0, bsmod = 0;
    while (off < in_size) {
        ml_iec61937_frame_info info;
        int rc = eac3 ? ml_iec61937_parse_eac3(in + off, in_size - off, &info)
                      : ml_iec61937_parse_ac3(in + off, in_size - off, &info);
        if (rc != ML_IEC61937_OK || off + info.frame_bytes > in_size) {
            printf("parse failed at offset %zu: %s\n", off, ml_iec61937_strerror(rc));
            errors++;
            break;
        }
        channels = info.channels;
        blocks = info.blocks;
        bsmod = info.bsmod;
        size_t out_len = 0;
        if (eac3) {
            rc = ml_iec61937_eac3_push(&state, in + off, info.frame_bytes, burst, sizeof(burst), &out_len);
        } else {
            rc = ml_iec61937_build_ac3_burst(in + off, info.frame_bytes, burst, sizeof(burst), &out_len);
        }
        if (rc != ML_IEC61937_OK) {
            printf("build failed at offset %zu: %s\n", off, ml_iec61937_strerror(rc));
            errors++;
            break;
        }
        if (out_len != 0) {
            CHECK(out_len == c.burst_bytes, "burst length %zu", out_len);
            compare_burst(&c, burst);
        }
        frames++;
        off += info.frame_bytes;
    }
    // ffmpeg writes one burst per complete group; a trailing partial group
    // produces nothing, same as here.
    size_t ref_bursts = ref_size / c.burst_bytes;
    printf("%s: frames=%zu (%u blocks, %zu channels, bsmod %u) bursts compared=%zu reference bursts=%zu mismatches=%zu errors=%zu ref_trailing_bytes=%zu\n",
           eac3 ? "eac3" : "ac3", frames, blocks, channels, bsmod, c.compared, ref_bursts, c.mismatched, errors,
           ref_size % c.burst_bytes);
    int ok = c.mismatched == 0 && errors == 0 && c.compared == ref_bursts && ref_size % c.burst_bytes == 0 && c.compared > 0;
    free(in);
    free(ref);
    return ok ? 0 : 1;
}

// ffmpeg's muxer cannot be fed a stream whose headers were rewritten (its parser
// then fails to find the sample rate), so the expected bursts for fewer-block
// frames are built here by a deliberately naive second implementation of the
// layout that the 6-block comparison against ffmpeg has already confirmed:
// Pa Pb Pc(0x15) Pd(bytes), payload words byte-swapped, zero padded.
static void naive_eac3_burst(const uint8_t *payload, size_t len, uint8_t *out) {
    memset(out, 0, ML_IEC61937_EAC3_BURST_BYTES);
    const uint16_t words[4] = {0xF872, 0x4E1F, 0x0015, (uint16_t)len};
    for (int i = 0; i < 4; i++) {
        out[2 * i] = (uint8_t)(words[i] & 0xFF);
        out[2 * i + 1] = (uint8_t)(words[i] >> 8);
    }
    for (size_t i = 0; i < len; i++) {
        out[8 + (i ^ 1)] = payload[i];
    }
}

// Rewrites each 6-block frame of a real stream to a one-block header and feeds
// them to the framer; six of them must produce the burst of their concatenation.
static int run_oneblock(const char *input_path) {
    size_t size;
    uint8_t *buf = read_file(input_path, &size);
    uint8_t burst[ML_IEC61937_EAC3_BURST_BYTES], expected[ML_IEC61937_EAC3_BURST_BYTES];
    uint8_t group[ML_IEC61937_EAC3_BURST_BYTES];
    ml_iec61937_eac3_state state;
    ml_iec61937_eac3_reset(&state);
    size_t off = 0, frames = 0, bursts = 0, mismatches = 0, group_len = 0, early = 0;
    while (off < size) {
        ml_iec61937_frame_info info;
        if (ml_iec61937_parse_eac3(buf + off, size - off, &info) != ML_IEC61937_OK) {
            return 2;
        }
        buf[off + 4] &= (uint8_t)~0x30; // numblkscod = 0: one block per frame
        memcpy(group + group_len, buf + off, info.frame_bytes);
        group_len += info.frame_bytes;
        size_t out_len = 0;
        int rc = ml_iec61937_eac3_push(&state, buf + off, info.frame_bytes, burst, sizeof(burst), &out_len);
        frames++;
        off += info.frame_bytes;
        if (rc != ML_IEC61937_OK) {
            printf("push failed: %s\n", ml_iec61937_strerror(rc));
            return 1;
        }
        if (frames % 6 != 0) {
            early += out_len != 0;
            continue;
        }
        naive_eac3_burst(group, group_len, expected);
        bursts++;
        mismatches += out_len != sizeof(burst) || memcmp(burst, expected, sizeof(burst)) != 0;
        group_len = 0;
    }
    printf("eac3 one block per frame: frames=%zu bursts compared=%zu mismatches=%zu early_bursts=%zu\n",
           frames, bursts, mismatches, early);
    free(buf);
    return (mismatches == 0 && early == 0 && bursts > 0) ? 0 : 1;
}

// Hand-built frame headers for the negative and edge cases. The payload content
// is irrelevant to the framer.
static void make_ac3(uint8_t *f, unsigned fscod, unsigned frmsizecod, unsigned bsid, unsigned bsmod, size_t *len) {
    unsigned kbps[19] = {32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640};
    *len = (size_t)kbps[(frmsizecod >> 1) > 18 ? 18 : (frmsizecod >> 1)] * 4;
    memset(f, 0xA5, *len);
    f[0] = 0x0B;
    f[1] = 0x77;
    f[4] = (uint8_t)((fscod << 6) | frmsizecod);
    f[5] = (uint8_t)((bsid << 3) | bsmod);
    f[6] = (uint8_t)(7u << 5); // acmod 3/2
    f[7] = 0x00;
}

static void make_eac3(uint8_t *f, unsigned frmsiz, unsigned numblkscod) {
    size_t len = ((size_t)frmsiz + 1) * 2;
    memset(f, 0x5A, len);
    f[0] = 0x0B;
    f[1] = 0x77;
    f[2] = (uint8_t)(frmsiz >> 8);
    f[3] = (uint8_t)frmsiz;
    f[4] = (uint8_t)((0u << 6) | (numblkscod << 4) | (7u << 1) | 1u);
    f[5] = (uint8_t)(16u << 3);
}

static void selftest(void) {
    static uint8_t frame[4096], out[ML_IEC61937_EAC3_BURST_BYTES];
    size_t len, out_len;

    // AC3 happy path with a bsmod and the last bytes of the payload.
    make_ac3(frame, 0, 36, 8, 5, &len); // 640 kbps, bsmod 5
    CHECK(ml_iec61937_build_ac3_burst(frame, len, out, sizeof(out), &out_len) == ML_IEC61937_OK && out_len == 6144, "ac3 build");
    CHECK(out[0] == 0x72 && out[1] == 0xF8 && out[2] == 0x1F && out[3] == 0x4E, "Pa/Pb little endian");
    CHECK(out[4] == 0x01 && out[5] == 0x05, "Pc: type 1, bsmod 5 in bits 8-10 (got %02x %02x)", out[4], out[5]);
    CHECK(out[6] == (len * 8 & 0xFF) && out[7] == (len * 8 >> 8), "Pd in bits");
    CHECK(out[8] == frame[1] && out[9] == frame[0], "payload byte swap");

    // Errors: truncation, bad sync, trailing data, small output, wrong rate.
    CHECK(ml_iec61937_build_ac3_burst(frame, len - 2, out, sizeof(out), &out_len) == ML_IEC61937_ERR_TOO_SHORT, "short frame");
    CHECK(ml_iec61937_build_ac3_burst(frame, 4, out, sizeof(out), &out_len) == ML_IEC61937_ERR_TOO_SHORT, "short header");
    CHECK(ml_iec61937_build_ac3_burst(frame, len + 2, out, sizeof(out), &out_len) == ML_IEC61937_ERR_LENGTH, "long frame");
    CHECK(ml_iec61937_build_ac3_burst(frame, len, out, 6143, &out_len) == ML_IEC61937_ERR_BUFFER, "small output");
    CHECK(ml_iec61937_build_ac3_burst(NULL, len, out, sizeof(out), &out_len) == ML_IEC61937_ERR_ARGUMENT, "null input");
    frame[0] = 0;
    CHECK(ml_iec61937_build_ac3_burst(frame, len, out, sizeof(out), &out_len) == ML_IEC61937_ERR_SYNC, "bad sync");
    make_ac3(frame, 1, 36, 8, 0, &len);
    CHECK(ml_iec61937_parse_ac3(frame, len, &(ml_iec61937_frame_info){0}) == ML_IEC61937_ERR_UNSUPPORTED, "44.1 kHz");
    make_ac3(frame, 3, 36, 8, 0, &len);
    CHECK(ml_iec61937_parse_ac3(frame, len, &(ml_iec61937_frame_info){0}) == ML_IEC61937_ERR_HEADER, "fscod 3");
    make_ac3(frame, 0, 38, 8, 0, &len);
    CHECK(ml_iec61937_parse_ac3(frame, 2560, &(ml_iec61937_frame_info){0}) == ML_IEC61937_ERR_HEADER, "frmsizecod 38");
    make_ac3(frame, 0, 36, 16, 0, &len);
    CHECK(ml_iec61937_parse_ac3(frame, len, &(ml_iec61937_frame_info){0}) == ML_IEC61937_ERR_HEADER, "E-AC3 bsid in AC3 parser");

    // E-AC3: 6-block frame is one burst; Pd is in bytes.
    ml_iec61937_eac3_state st;
    ml_iec61937_eac3_reset(&st);
    make_eac3(frame, 767, 3); // 1536 bytes
    CHECK(ml_iec61937_eac3_push(&st, frame, 1536, out, sizeof(out), &out_len) == ML_IEC61937_OK && out_len == 24576, "eac3 6 blocks");
    CHECK(out[4] == 0x15 && out[5] == 0x00 && out[6] == (1536 & 0xFF) && out[7] == (1536 >> 8), "eac3 Pc/Pd");

    // Accumulation: 3 x 2 blocks, then 6 x 1 block.
    make_eac3(frame, 99, 1); // 200 bytes, 2 blocks
    CHECK(ml_iec61937_eac3_push(&st, frame, 200, out, sizeof(out), &out_len) == 0 && out_len == 0, "acc 1/3");
    CHECK(ml_iec61937_eac3_push(&st, frame, 200, out, sizeof(out), &out_len) == 0 && out_len == 0, "acc 2/3");
    CHECK(ml_iec61937_eac3_push(&st, frame, 200, out, sizeof(out), &out_len) == 0 && out_len == 24576, "acc 3/3");
    CHECK(out[6] == (600 & 0xFF) && out[7] == (600 >> 8), "accumulated Pd = 600 bytes");
    CHECK(out[8 + 600] == 0 && out[24575] == 0, "zero padding");
    // Overflow: 2 + 6 blocks, state must reset.
    CHECK(ml_iec61937_eac3_push(&st, frame, 200, out, sizeof(out), &out_len) == 0 && out_len == 0, "overflow setup");
    make_eac3(frame, 99, 3); // 6 blocks on top of 2
    CHECK(ml_iec61937_eac3_push(&st, frame, 200, out, sizeof(out), &out_len) == ML_IEC61937_ERR_OVERFLOW, "block overflow");
    CHECK(st.blocks == 0 && st.length == 0, "state reset after overflow");
    // 3 x 2 blocks of the largest frame is 12288 bytes and still fits.
    make_eac3(frame, 2047, 1); // 4096 bytes, 2 blocks
    for (int i = 0; i < 3; i++) {
        int rc = ml_iec61937_eac3_push(&st, frame, 4096, out, sizeof(out), &out_len);
        CHECK(rc == ML_IEC61937_OK, "max frames rc %d", rc);
    }
    CHECK(out_len == 24576, "max frames burst");
    // A single 6-block frame of the maximum size does not fit the burst.
    make_eac3(frame, 2047, 3);
    CHECK(ml_iec61937_eac3_push(&st, frame, 4096, out, sizeof(out), &out_len) == ML_IEC61937_OK && out_len == 24576, "4096-byte frame fits");
    CHECK(ml_iec61937_eac3_push(&st, frame, 4095, out, sizeof(out), &out_len) == ML_IEC61937_ERR_TOO_SHORT, "eac3 short");
    // Dependent substream and 48 kHz only.
    make_eac3(frame, 99, 3);
    frame[2] |= 0x40;
    CHECK(ml_iec61937_eac3_push(&st, frame, 200, out, sizeof(out), &out_len) == ML_IEC61937_ERR_UNSUPPORTED, "dependent substream");
    make_eac3(frame, 99, 3);
    frame[4] |= 0x40;
    CHECK(ml_iec61937_eac3_push(&st, frame, 200, out, sizeof(out), &out_len) == ML_IEC61937_ERR_UNSUPPORTED, "44.1 kHz eac3");
    make_eac3(frame, 99, 3);
    CHECK(ml_iec61937_eac3_push(&st, frame, 200, out, 24575, &out_len) == ML_IEC61937_ERR_BUFFER, "eac3 small output");

    // Pause bursts.
    CHECK(ml_iec61937_build_pause(out, sizeof(out), 6144, 6144) == ML_IEC61937_OK, "pause build");
    CHECK(out[0] == 0x72 && out[1] == 0xF8 && out[2] == 0x1F && out[3] == 0x4E && out[4] == 0x03 && out[5] == 0 && out[6] == 0 && out[7] == 0, "pause preamble");
    CHECK(memcmp(out + 8, out + 9, 6144 - 9) == 0 && out[8] == 0, "pause is zero beyond the preamble");
    CHECK(ml_iec61937_build_pause(out, 100, 6144, 6144) == ML_IEC61937_ERR_BUFFER, "pause small output");
    CHECK(ml_iec61937_build_pause(out, sizeof(out), 6144, 3) == ML_IEC61937_ERR_ARGUMENT, "pause bad period");
    CHECK(ml_iec61937_build_pause(out, sizeof(out), 64, 0) == ML_IEC61937_OK && out[0] == 0 && out[63] == 0, "pause silence");

    printf("selftest: %s\n", failures == 0 ? "ok" : "FAILED");
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "selftest") == 0) {
        selftest();
        return failures == 0 ? 0 : 1;
    }
    if (argc == 4 && strcmp(argv[1], "ac3") == 0) {
        return run_stream(0, argv[2], argv[3]);
    }
    if (argc == 4 && strcmp(argv[1], "eac3") == 0) {
        return run_stream(1, argv[2], argv[3]);
    }
    if (argc == 3 && strcmp(argv[1], "oneblock") == 0) {
        return run_oneblock(argv[2]);
    }
    fprintf(stderr, "usage: see tests/iec61937/README.md\n");
    return 2;
}
