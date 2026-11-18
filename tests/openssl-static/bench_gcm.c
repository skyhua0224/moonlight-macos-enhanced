// Per-packet AES-128-GCM decrypt micro-benchmark through the same entry point the stream
// uses (PltDecryptMessage on a reused context, fresh IV and tag per packet). It links
// whichever libcrypto the build line names, so the same source measures the old
// OpenSSL.framework and the static trimmed libcrypto.
//
//   bench_gcm [packet_bytes] [seconds] [runs]      defaults: 1400 3 5
//
// 150 Mbit/s of 1400-byte packets is about 13400 packets per second; the "headroom"
// column says how many times faster than that rate the decrypt path runs on one core.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <openssl/crypto.h>
#include <openssl/rand.h>

#include "Limelight-internal.h"

// Limelight-internal.h routes the log callback through this context; the benchmark never logs.
ML_CONNECTION_CONTEXT gConnectionContext;

static double now(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static int cmp(const void* a, const void* b) {
    double x = *(const double*)a, y = *(const double*)b;
    return (x > y) - (x < y);
}

int main(int argc, char** argv) {
    int pkt = argc > 1 ? atoi(argv[1]) : 1400;
    double seconds = argc > 2 ? atof(argv[2]) : 3.0;
    int runs = argc > 3 ? atoi(argv[3]) : 5;

    // A pool of distinct (iv, tag, ciphertext) triples so the loop is not decrypting one
    // cache-hot packet forever.
    enum { POOL = 256 };
    unsigned char key[16];
    RAND_bytes(key, sizeof(key));
    unsigned char (*iv)[12] = malloc(POOL * 12);
    unsigned char (*tag)[16] = malloc(POOL * 16);
    unsigned char* ct = malloc((size_t)POOL * pkt);
    unsigned char* pt = malloc(pkt);
    PPLT_CRYPTO_CONTEXT enc = PltCreateCryptoContext();
    for (int i = 0; i < POOL; i++) {
        unsigned char plain[2048];
        RAND_bytes(plain, pkt); RAND_bytes(iv[i], 12);
        int outLen = 0;
        if (!PltEncryptMessage(enc, ALGORITHM_AES_GCM, 0, key, 16, iv[i], 12, tag[i], 16, plain, pkt, ct + (size_t)i * pkt, &outLen)) {
            fprintf(stderr, "encrypt failed\n"); return 1;
        }
    }
    PltDestroyCryptoContext(enc);

    PPLT_CRYPTO_CONTEXT dec = PltCreateCryptoContext();
    double rates[32];
    if (runs > 32) runs = 32;
    for (int r = 0; r < runs; r++) {
        long n = 0; int outLen = 0;
        double start = now(), end;
        do {
            for (int i = 0; i < 4096; i++) {
                int k = i & (POOL - 1);
                if (!PltDecryptMessage(dec, ALGORITHM_AES_GCM, 0, key, 16, iv[k], 12, tag[k], 16, ct + (size_t)k * pkt, pkt, pt, &outLen)) {
                    fprintf(stderr, "decrypt failed\n"); return 1;
                }
            }
            n += 4096;
            end = now();
        } while (end - start < seconds);
        rates[r] = n / (end - start);
    }
    qsort(rates, runs, sizeof(double), cmp);
    double med = rates[runs / 2];
    printf("%s | packet %d B | median %.0f pkt/s = %.0f ns/pkt = %.1f MB/s = %.0f Mbit/s | headroom over 150 Mbit/s: %.0fx | min %.0f max %.0f pkt/s\n",
           OpenSSL_version(OPENSSL_VERSION), pkt, med, 1e9 / med, med * pkt / 1e6, med * pkt * 8 / 1e6,
           med * pkt * 8 / 150e6, rates[0], rates[runs - 1]);
    PltDestroyCryptoContext(dec);
    return 0;
}
