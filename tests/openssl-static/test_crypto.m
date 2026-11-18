// Exercises every libcrypto feature the app relies on against the static libcrypto
// build (scripts/build_openssl.sh): certificate and key generation, PKCS#12 import into
// the Security framework, pairing signatures, AES-GCM / CBC / ECB, HMAC, SHA and RAND.
// Known-answer vectors come from FIPS 180, FIPS 197, RFC 2202, RFC 4231 and the GCM
// specification; CBC and ECB are cross-checked against CommonCrypto, and the PKCS#12 and
// signature paths against the Security framework.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCryptor.h>
#import <Security/Security.h>

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/x509.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/crypto.h>

#import "CryptoManager.h"
#include "PlatformCrypto.h"
#include "mkcert.h"

// CryptoManager.m logs through the app logger and reaches the key helpers through
// class methods that are private to the implementation file.
void Log(LogLevel level, NSString* fmt, ...) { (void)level; (void)fmt; }

@interface CryptoManager (TestAccess)
+ (NSData*)getKeyFromCertKeyPair:(CertKeyPair*)certKeyPair;
+ (NSData*)getP12FromCertKeyPair:(CertKeyPair*)certKeyPair;
+ (NSData*)getCertFromCertKeyPair:(CertKeyPair*)certKeyPair;
@end

static int failures = 0;
static int checks = 0;

#define CHECK(cond, ...) do { \
    checks++; \
    if (!(cond)) { failures++; printf("FAIL  %s:%d  %s  ", __FILE__, __LINE__, #cond); printf(__VA_ARGS__); printf("\n"); } \
} while (0)

static NSData* hex(const char* s) {
    NSMutableData* d = [NSMutableData data];
    while (s[0] && s[1]) {
        unsigned int b; sscanf(s, "%2x", &b);
        uint8_t v = (uint8_t)b; [d appendBytes:&v length:1];
        s += 2;
    }
    return d;
}

static NSData* bytes(const void* p, size_t n) { return [NSData dataWithBytes:p length:n]; }

static NSData* repeated(uint8_t v, size_t n) {
    NSMutableData* d = [NSMutableData dataWithLength:n];
    memset(d.mutableBytes, v, n);
    return d;
}

static const char* kEcCert =
"-----BEGIN CERTIFICATE-----\n"
"MIIBeDCCAR+gAwIBAgIUX3HSrWXPjY1PgznLZl7Q1B7qw5YwCgYIKoZIzj0EAwIw\n"
"EjEQMA4GA1UEAwwHRUMgSG9zdDAeFw0yNjExMTgwNTMyMDdaFw0zNjExMTUwNTMy\n"
"MDdaMBIxEDAOBgNVBAMMB0VDIEhvc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNC\n"
"AAT3JvQYKO3nhKh/kaxWA6NOaLaLjGg+l9OyfVF93VqsgrOomSb80+8u04LoqSwM\n"
"oiKEmT0H9K72Di7jWthxftaIo1MwUTAdBgNVHQ4EFgQUgqn2qjgczqqLFYeYLXtJ\n"
"/uAC6OIwHwYDVR0jBBgwFoAUgqn2qjgczqqLFYeYLXtJ/uAC6OIwDwYDVR0TAQH/\n"
"BAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiAiNYVokCsL8UwlOI/icum5aqJyh9Ht\n"
"KNoAMnzfCqhBmAIgQqpF7p4o3tG92DAmi2BciZCn1C6AaV+jShGqWR4pnHM=\n"
"-----END CERTIFICATE-----\n";

static void testHashes(CryptoManager* cm) {
    NSData* abc = [@"abc" dataUsingEncoding:NSASCIIStringEncoding];
    CHECK([[cm SHA1HashData:abc] isEqualToData:hex("a9993e364706816aba3e25717850c26c9cd0d89d")], "SHA-1");
    CHECK([[cm SHA256HashData:abc] isEqualToData:hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")], "SHA-256");
    NSData* salted = [@"saltPIN" dataUsingEncoding:NSASCIIStringEncoding];
    CHECK([[cm createAESKeyFromSaltSHA1:salted] length] == 16, "SHA-1 key length");
    CHECK([[cm createAESKeyFromSaltSHA256:salted] isEqualToData:[[cm SHA256HashData:salted] subdataWithRange:NSMakeRange(0, 16)]], "SHA-256 key");

    // RFC 4231 test case 1 and RFC 2202 test case 1.
    unsigned char out[EVP_MAX_MD_SIZE]; unsigned int n = 0;
    NSData* key = repeated(0x0b, 20); NSData* msg = [@"Hi There" dataUsingEncoding:NSASCIIStringEncoding];
    HMAC(EVP_sha256(), key.bytes, (int)key.length, msg.bytes, msg.length, out, &n);
    CHECK(n == 32 && [bytes(out, n) isEqualToData:hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")], "HMAC-SHA256");
    HMAC(EVP_sha1(), key.bytes, (int)key.length, msg.bytes, msg.length, out, &n);
    CHECK(n == 20 && [bytes(out, n) isEqualToData:hex("b617318655057264e28bc0b6fb378c8ef146be00")], "HMAC-SHA1");
}

static void testEcb(CryptoManager* cm) {
    // FIPS 197 appendix C.1.
    NSData* key = hex("000102030405060708090a0b0c0d0e0f");
    NSData* pt = hex("00112233445566778899aabbccddeeff");
    NSData* ct = [cm aesEncrypt:pt withKey:key];
    CHECK([ct isEqualToData:hex("69c4e0d86a7b0430d8cdb78070b4c55a")], "AES-128-ECB KAT");
    CHECK([[cm aesDecrypt:ct withKey:key] isEqualToData:pt], "AES-128-ECB round trip");

    // Multi-block against CommonCrypto.
    NSMutableData* big = [NSMutableData dataWithLength:64];
    RAND_bytes(big.mutableBytes, 64);
    NSMutableData* ref = [NSMutableData dataWithLength:64]; size_t moved = 0;
    CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode, key.bytes, 16, NULL, big.bytes, 64, ref.mutableBytes, 64, &moved);
    CHECK([[cm aesEncrypt:big withKey:key] isEqualToData:ref], "AES-ECB vs CommonCrypto");
}

static void testCbcGcm(void) {
    // A crypto context is bound to one cipher and one key, as in the stream code.
    PPLT_CRYPTO_CONTEXT enc = PltCreateCryptoContext();
    PPLT_CRYPTO_CONTEXT dec = PltCreateCryptoContext();
    unsigned char key[16], iv[16];
    RAND_bytes(key, 16); RAND_bytes(iv, 16);

    // AES-CBC with PKCS#7 padding, as the audio stream and RTSP use it.
    for (int len = 3; len <= 66; len += 7) {
        NSMutableData* pt = [NSMutableData dataWithLength:len];
        RAND_bytes(pt.mutableBytes, len);
        unsigned char out[128]; int outLen = 0;
        NSMutableData* padded = [NSMutableData dataWithLength:ROUND_TO_PKCS7_PADDED_LEN(len + 1)];
        memcpy(padded.mutableBytes, pt.bytes, len);
        bool ok = PltEncryptMessage(enc, ALGORITHM_AES_CBC, CIPHER_FLAG_RESET_IV | CIPHER_FLAG_PAD_TO_BLOCK_SIZE,
                                    key, 16, iv, 16, NULL, 0, padded.mutableBytes, len, out, &outLen);
        CHECK(ok && outLen == (int)padded.length, "CBC encrypt len=%d", len);
        NSMutableData* ref = [NSMutableData dataWithLength:padded.length]; size_t moved = 0;
        CCCryptorStatus st = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key, 16, iv, pt.bytes, len, ref.mutableBytes, ref.length, &moved);
        CHECK(st == kCCSuccess && moved == (size_t)outLen && memcmp(ref.bytes, out, moved) == 0, "CBC vs CommonCrypto len=%d", len);
        unsigned char back[128]; int backLen = 0;
        ok = PltDecryptMessage(dec, ALGORITHM_AES_CBC, CIPHER_FLAG_RESET_IV | CIPHER_FLAG_FINISH,
                               key, 16, iv, 16, NULL, 0, out, outLen, back, &backLen);
        CHECK(ok && backLen == len && memcmp(back, pt.bytes, len) == 0, "CBC decrypt len=%d", len);
    }

    PltDestroyCryptoContext(enc);
    PltDestroyCryptoContext(dec);
    enc = PltCreateCryptoContext();
    dec = PltCreateCryptoContext();

    // AES-128-GCM, test case 3 of the GCM specification.
    NSData* gkey = hex("feffe9928665731c6d6a8f9467308308");
    NSData* giv = hex("cafebabefacedbaddecaf888");
    NSData* gpt = hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72"
                      "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255");
    NSData* gct = hex("42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e"
                      "21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985");
    NSData* gtag = hex("4d5c2af327cd64a62cf35abd2ba6fab4");
    unsigned char tag[16]; unsigned char out[64]; int outLen = 0;
    bool ok = PltEncryptMessage(enc, ALGORITHM_AES_GCM, 0, (unsigned char*)gkey.bytes, 16, (unsigned char*)giv.bytes, 12,
                                tag, 16, (unsigned char*)gpt.bytes, 64, out, &outLen);
    CHECK(ok && outLen == 64 && memcmp(out, gct.bytes, 64) == 0 && memcmp(tag, gtag.bytes, 16) == 0, "GCM encrypt KAT");
    unsigned char back[64]; int backLen = 0;
    ok = PltDecryptMessage(dec, ALGORITHM_AES_GCM, 0, (unsigned char*)gkey.bytes, 16, (unsigned char*)giv.bytes, 12,
                           (unsigned char*)gtag.bytes, 16, (unsigned char*)gct.bytes, 64, back, &backLen);
    CHECK(ok && backLen == 64 && memcmp(back, gpt.bytes, 64) == 0, "GCM decrypt KAT");

    // A flipped ciphertext bit or tag bit must be rejected.
    NSMutableData* bad = [gct mutableCopy]; ((unsigned char*)bad.mutableBytes)[10] ^= 1;
    ok = PltDecryptMessage(dec, ALGORITHM_AES_GCM, 0, (unsigned char*)gkey.bytes, 16, (unsigned char*)giv.bytes, 12,
                           (unsigned char*)gtag.bytes, 16, (unsigned char*)bad.bytes, 64, back, &backLen);
    CHECK(!ok, "GCM rejects tampered ciphertext");
    NSMutableData* badTag = [gtag mutableCopy]; ((unsigned char*)badTag.mutableBytes)[0] ^= 1;
    ok = PltDecryptMessage(dec, ALGORITHM_AES_GCM, 0, (unsigned char*)gkey.bytes, 16, (unsigned char*)giv.bytes, 12,
                           (unsigned char*)badTag.bytes, 16, (unsigned char*)gct.bytes, 64, back, &backLen);
    CHECK(!ok, "GCM rejects tampered tag");
    PltDestroyCryptoContext(enc);
    PltDestroyCryptoContext(dec);

    // Round trip with a fresh IV per 1400-byte packet on reused contexts, the stream's usage.
    enc = PltCreateCryptoContext();
    dec = PltCreateCryptoContext();
    unsigned char k[16]; RAND_bytes(k, 16);
    for (int i = 0; i < 1000; i++) {
        unsigned char v[12], t[16], pkt[1400], c[1400], p[1400];
        RAND_bytes(v, 12); RAND_bytes(pkt, sizeof(pkt));
        int cl = 0, pl = 0;
        CHECK(PltEncryptMessage(enc, ALGORITHM_AES_GCM, 0, k, 16, v, 12, t, 16, pkt, sizeof(pkt), c, &cl), "GCM enc %d", i);
        CHECK(PltDecryptMessage(dec, ALGORITHM_AES_GCM, 0, k, 16, v, 12, t, 16, c, cl, p, &pl) && pl == (int)sizeof(pkt) && memcmp(p, pkt, pl) == 0, "GCM dec %d", i);
        if (failures) break;
    }
    PltDestroyCryptoContext(enc);
    PltDestroyCryptoContext(dec);
}

static void testRand(void) {
    unsigned char a[32] = {0}, b[32] = {0};
    PltGenerateRandomData(a, 32); PltGenerateRandomData(b, 32);
    CHECK(memcmp(a, b, 32) != 0, "RAND outputs differ");
    NSMutableData* big = [NSMutableData dataWithLength:1 << 20];
    PltGenerateRandomData(big.mutableBytes, (int)big.length);
    const unsigned char* p = big.bytes; size_t ones = 0;
    for (size_t i = 0; i < big.length; i++) ones += __builtin_popcount(p[i]);
    double ratio = (double)ones / (big.length * 8.0);
    CHECK(ratio > 0.499 && ratio < 0.501, "RAND bit balance %f", ratio);
}

static SecKeyRef copyKeyFromP12(NSData* p12, SecIdentityRef* identityOut) {
    NSMutableDictionary* opts = [@{ (__bridge id)kSecImportExportPassphrase: @"limelight" } mutableCopy];
    if (@available(macOS 15.0, *)) {
        opts[(__bridge id)kSecImportToMemoryOnly] = @YES;
    }
    CFArrayRef items = NULL;
    OSStatus st = SecPKCS12Import((__bridge CFDataRef)p12, (__bridge CFDictionaryRef)opts, &items);
    CHECK(st == errSecSuccess && items && CFArrayGetCount(items) == 1, "SecPKCS12Import status %d", (int)st);
    if (st != errSecSuccess || !items) return NULL;
    CFDictionaryRef item = CFArrayGetValueAtIndex(items, 0);
    SecIdentityRef identity = (SecIdentityRef)CFDictionaryGetValue(item, kSecImportItemIdentity);
    CHECK(identity != NULL, "p12 carries an identity");
    SecKeyRef key = NULL;
    if (identity) {
        CFRetain(identity);
        SecIdentityCopyPrivateKey(identity, &key);
        if (identityOut) *identityOut = identity; else CFRelease(identity);
    }
    CFRelease(items);
    return key;
}

static void testIdentityAndPairing(CryptoManager* cm) {
    CertKeyPair pair = generateCertKeyPair();
    CHECK(pair.x509 && pair.pkey && pair.p12, "generateCertKeyPair");
    if (!pair.x509 || !pair.pkey || !pair.p12) return;
    CHECK(EVP_PKEY_base_id(pair.pkey) == EVP_PKEY_RSA && EVP_PKEY_bits(pair.pkey) == 2048, "RSA-2048 key");

    NSData* certPem = [CryptoManager getCertFromCertKeyPair:&pair];
    NSData* keyPem = [CryptoManager getKeyFromCertKeyPair:&pair];
    NSData* p12 = [CryptoManager getP12FromCertKeyPair:&pair];
    freeCertKeyPair(pair);
    CHECK(certPem.length > 500 && keyPem.length > 1000 && p12.length > 1000, "PEM and PKCS#12 exported");
    CHECK(memmem(keyPem.bytes, keyPem.length, "BEGIN RSA PRIVATE KEY", 21) != NULL, "traditional RSA key encoding");

    // Certificate: DER form is accepted by Security and carries the expected subject.
    NSData* der = [CryptoManager pemToDer:certPem];
    SecCertificateRef cert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der);
    CHECK(cert != NULL, "Security parses the DER certificate");
    if (cert) {
        CFStringRef subject = SecCertificateCopySubjectSummary(cert);
        CHECK(subject && [(__bridge NSString*)subject isEqualToString:@"NVIDIA GameStream Client"], "subject");
        if (subject) CFRelease(subject);
        CFRelease(cert);
    }
    CHECK([[CryptoManager getSignatureFromCert:certPem] length] == 256, "certificate signature is 2048 bits");

    // PKCS#12 (3DES + SHA-1 MAC) imports into the Security framework.
    SecIdentityRef identity = NULL;
    SecKeyRef secKey = copyKeyFromP12(p12, &identity);
    CHECK(secKey != NULL, "private key from imported identity");

    // Pairing signatures: OpenSSL signs, OpenSSL verifies, and Security verifies the same bytes.
    NSData* msg = [@"pairing challenge response" dataUsingEncoding:NSUTF8StringEncoding];
    NSData* sig = [cm signData:msg withKey:keyPem];
    CHECK(sig.length == 256, "signature length");
    CHECK([cm verifySignature:msg withSignature:sig andCert:certPem], "verify own signature");
    NSData* other = [@"pairing challenge response!" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK(![cm verifySignature:other withSignature:sig andCert:certPem], "reject different data");
    NSMutableData* badSig = [sig mutableCopy]; ((unsigned char*)badSig.mutableBytes)[5] ^= 0x40;
    CHECK(![cm verifySignature:msg withSignature:badSig andCert:certPem], "reject corrupted signature");

    if (identity && secKey) {
        SecKeyRef pub = SecKeyCopyPublicKey(secKey);
        CFErrorRef err = NULL;
        Boolean ok = pub && SecKeyVerifySignature(pub, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, (__bridge CFDataRef)msg, (__bridge CFDataRef)sig, &err);
        CHECK(ok, "Security verifies the OpenSSL signature");
        if (err) CFRelease(err);
        CFDataRef secSig = SecKeyCreateSignature(secKey, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, (__bridge CFDataRef)msg, NULL);
        CHECK(secSig && [cm verifySignature:msg withSignature:(__bridge NSData*)secSig andCert:certPem], "OpenSSL verifies the Security signature");
        if (secSig) CFRelease(secSig);
        if (pub) CFRelease(pub);
    }
    if (secKey) CFRelease(secKey);
    if (identity) CFRelease(identity);

    // A host certificate is always a Sunshine-family RSA-2048 one. Generate one with a
    // different key the way a host does and verify its signature from the client side.
    CertKeyPair host = generateCertKeyPair();
    NSData* hostCert = [CryptoManager getCertFromCertKeyPair:&host];
    NSData* hostKey = [CryptoManager getKeyFromCertKeyPair:&host];
    freeCertKeyPair(host);
    NSData* hostSig = [cm signData:msg withKey:hostKey];
    CHECK([cm verifySignature:msg withSignature:hostSig andCert:hostCert], "host RSA certificate round trip");
    CHECK(![cm verifySignature:msg withSignature:hostSig andCert:certPem], "signature does not verify under another identity");
}

static void testEcHostCertIsRejectedCleanly(CryptoManager* cm) {
    // The trimmed build has no EC. An EC host certificate must fail verification without a
    // crash (none of the supported hosts issue one; see docs/openssl-static-libcrypto.md).
    NSData* ec = [NSData dataWithBytes:kEcCert length:strlen(kEcCert)];
    NSData* msg = [@"x" dataUsingEncoding:NSUTF8StringEncoding];
    NSData* sig = repeated(0x30, 72);
    CHECK(![cm verifySignature:msg withSignature:sig andCert:ec], "EC certificate does not verify and does not crash");
}

int main(void) {
    @autoreleasepool {
        printf("OpenSSL %s\n", OpenSSL_version(OPENSSL_VERSION));
        CryptoManager* cm = [[CryptoManager alloc] init];
        testHashes(cm);
        testEcb(cm);
        testCbcGcm();
        testRand();
        testIdentityAndPairing(cm);
        testEcHostCertIsRejectedCleanly(cm);
    }
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
