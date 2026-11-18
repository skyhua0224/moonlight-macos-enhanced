# OpenSSL：静态链接的 libcrypto

应用不再携带 `OpenSSL.framework`，也不再依赖 Swift Package 形式的预编译包。`scripts/build_openssl.sh` 从固定版本、固定校验值的 OpenSSL 源码，按下面的裁剪配置为 arm64 和 x86_64 各编一份静态 `libcrypto.a`，主程序和 moonlight-common-c 直接链接它。仓库里不提交任何二进制，每次 CI 构建都从源码重新编译。

## 版本与取舍

- 当前版本 **OpenSSL 3.5.9**，源码包 sha256 写在 `scripts/build_openssl.sh` 里，与 GitHub 发布页的 `.sha256` 文件和 API 返回的摘要三处一致。
- 选 3.5 的原因：它是当前受支持的长期支持（LTS）线，OpenSSL 官方发布策略写明 3.5 支持到 2030-04-08；非 LTS 版本只保证 13 个月，4.0 到 2027-05-14，4.1 到 2027-11-23。裁剪后的库只用到成熟的 RSA、X.509、PKCS#12、AES、SHA、HMAC 接口，用 LTS 线换来最长的安全修复期，升级时也不需要追新接口。
- 以前的预编译包固定在 3.6.1。3.6 线不在官方受支持名单里，换成 3.5.9 同时去掉了这个停滞的固定版本。
- 汇编优化保持开启（ARMv8 Crypto Extensions、AES-NI、PCLMULQDQ），**不要加 `no-asm`**。以前的预编译包没有这些汇编，AES-GCM 每包解密 8.8 µs，现在 0.24 µs，见下面的测量。

## 保留与去掉

| 保留 | 用途 |
| --- | --- |
| RSA 密钥生成、签名、验签 | 客户端证书与配对签名（`mkcert.c`、`CryptoManager.m`） |
| X.509、PEM、PKCS#12（3DES + SHA-1 MAC） | 证书和私钥的生成、导出，macOS 各版本都能导入的 PKCS#12 |
| SHA-1、SHA-256、HMAC | 配对、端点刷新协议 |
| AES-ECB、AES-CBC、AES-GCM，DES-EDE3 | 配对、RTSP、音频、控制、视频流的加解密；PKCS#12 的 3DES |
| 系统熵源播种的 DRBG | `RAND_bytes` |

去掉的有：libssl（`no-ssl no-tls no-dtls no-quic`，也不编译它，只 `make libcrypto.a`）、legacy provider、动态加载（`no-module no-dso no-engine`）、椭圆曲线（`no-ec no-ecdsa no-ecdh`）、DH、DSA、SM2/3/4、Blowfish、CAST、RC2/4/5、IDEA、SEED、Camellia、ARIA、ChaCha20-Poly1305、OCB、SIV、scrypt、argon2、MD2/4/MDC2、RIPEMD、Whirlpool、BLAKE2、SipHash、OCSP、CMS、CT、TS、CMP、压缩和 socket BIO。完整列表在脚本的 `OPTIONS` 数组里。去掉的功能没有任何一项被应用调用。

不参与编译的功能同时也不在攻击面里：OpenSSL 公告里关于 QUIC、DTLS、TLS 握手、CMS、OCSP、CMP、AES-GCM-SIV、SM2 的条目都不适用于这份库。

## 主机证书只走 RSA，所以去掉了 EC

客户端遇到的 GameStream 主机证书，在受支持的主机里都是 RSA-2048：

| 主机 | 证书生成 |
| --- | --- |
| Foundation Sunshine | `create_creds`，经共享的配对身份 Adapter 生成自签 RSA-2048，20 年有效期 |
| LizardByte Sunshine | `crypto::gen_creds`，`EVP_PKEY_CTX_new_id(EVP_PKEY_RSA)` + `EVP_PKEY_CTX_set_rsa_keygen_bits`，`httpcommon.cpp` 以 2048 位调用 |
| Apollo | 同一份 `gen_creds`，`EVP_PKEY_RSA`，`httpcommon.cpp` 以 2048 位调用 |

核对的版本：LizardByte/Sunshine `37ee7d549`（2026-11-18）、Apollo `adc5c5a0b`（2026-05-21）、Foundation Sunshine 当前主线。三者的证书生成路径里都没有 `EVP_PKEY_EC`、`EC_KEY` 或 Ed25519。客户端自己的证书也是 RSA-2048，由 `mkcert.c` 生成。

保留 EC 的代价：在脚本的 `OPTIONS` 里去掉 `no-ec no-ecdsa no-ecdh`，arm64 的静态库从 5.1 MB 变成 6.1 MB，链接并剥离后的测试程序从 1.69 MB 变成 2.29 MB，也就是每个架构多约 0.6 MB。如果将来有主机改发 EC 证书，这样改即可，`tests/openssl-static` 里的 EC 反向用例要同步改成正向用例。在那之前，EC 主机证书会让验签返回失败而不会崩溃（`testEcHostCertIsRejectedCleanly` 覆盖这一点）。

## 构建与链接

- `scripts/build_openssl.sh` 产出 `xcframeworks/openssl/{lib/libcrypto.a,include/openssl,LICENSE.txt,VERSION,STAMP}`；`xcframeworks/` 已被 `.gitignore` 忽略。`STAMP` 是版本、部署目标、架构和选项的哈希，参数不变时脚本直接跳过。
- 部署目标 12.0，加 `-fvisibility=hidden`，静态库链接后随主程序的 `-dead_strip` 去掉没引用的部分。`ARCHS` 环境变量选择架构：CI 的每个任务只编自己那一份，本地默认两份并用 `lipo` 合成。
- `Moonlight.xcodeproj` 的主程序在 `HEADER_SEARCH_PATHS` 里加 `xcframeworks/openssl/include`，在 `OTHER_LDFLAGS` 里直接写 `libcrypto.a` 的路径；`moonlight-common.xcodeproj` 同样有头文件路径。`OpenSSL-Package` 的 Swift Package 依赖和 `Package.resolved` 里的固定项已删除。
- 没有网络或 GitHub 很慢时，把官方 `openssl-3.5.9.tar.gz` 先下载好，用 `OPENSSL_TARBALL=<路径>` 传入，同一个 sha256 校验照样执行。

## 验证

- `tests/openssl-static/run.sh` 为库里的每个架构（x86_64 在 Rosetta 下）编译并运行 `test_crypto.m`，共 2064 项检查：
  - SHA-1、SHA-256、HMAC-SHA1/SHA-256、AES-128-ECB 的标准答案（FIPS 180、FIPS 197、RFC 2202、RFC 4231）；
  - AES-CBC（含 PKCS#7 补位）和多块 ECB 与 CommonCrypto 对拍；
  - AES-GCM 的规范测试向量，篡改密文和标签必须被拒绝，1000 个 1400 字节包的加解密往返；
  - `RAND` 的两次输出不同，1 MiB 的位均衡；
  - 证书与私钥生成（RSA-2048、`BEGIN RSA PRIVATE KEY`）、PEM 与 DER 转换、`SecCertificateCreateWithData` 解析；
  - PKCS#12 用 `SecPKCS12Import`（仅内存）导入并取出身份和私钥；
  - 配对签名在 OpenSSL 与 Security 框架之间双向验证，改数据或签名必须验证失败；
  - EC 主机证书的验签失败而不崩溃。
- `BENCH=1 tests/openssl-static/run.sh` 另外运行 `bench_gcm.c`，用串流路径同一个入口 `PltDecryptMessage` 测每包 AES-GCM 解密。
- CI（`build.yml`）每个架构任务依次：构建 libcrypto、运行这些检查、构建应用，然后断言包里没有 `OpenSSL.framework`、`otool -L` 里没有 OpenSSL、libcrypto 或 libssl。

## 性能

在 Apple Silicon 上，同一份 `bench_gcm.c` 分别链接原先的 `OpenSSL.framework`（3.6.1）和现在的静态库，每包 1400 字节，各跑 3 轮交替取中位数：

| | 每包耗时 | 吞吐 | 对 150 Mbit/s 的余量 |
| --- | --- | --- | --- |
| 原 OpenSSL.framework 3.6.1 | 8.8 µs | 159 MB/s | 8 倍 |
| 静态 libcrypto 3.5.9 | 0.24 µs | 5.9 GB/s | 315 倍 |

原来的预编译包里没有 `aes_v8` / `aesni` 一类的汇编符号，也就是纯 C 的 AES-GCM；现在的库保留了汇编，不会退步。

## 升级 OpenSSL 与安全更新

1. **看公告**：订阅或定期查看 <https://openssl-library.org/news/vulnerabilities/>，以及 openssl/openssl 仓库的 Releases。关心的是影响 `3.5.x` 且落在保留功能里的条目：RSA、X.509 解析、PEM、PKCS#12、ASN.1、AES、SHA、HMAC、RAND。QUIC、TLS、DTLS、CMS、CMP、OCSP、EC、SM2、SIV 的条目对这份库不适用，但仍要写进升级记录里说明为什么不适用。
2. **升版本**：在 `scripts/build_openssl.sh` 里同时改 `VERSION` 和 `SHA256`。校验值取发布页的 `openssl-<版本>.tar.gz.sha256`，并和 GitHub Releases 资产的 `digest` 字段核对一致。同一次改动里更新：`scripts/generate_third_party_licenses.py` 的版本，重新运行它生成 `ThirdPartyLicenses.json`；`docs/third-party/SOURCES.md` 的固定版本；`docs/authority/source-index.tsv` 里压缩包的记录（sha256 与字节数）。
3. **补丁版本（3.5.x）**：不需要改接口，直接按第 2 步升级，跑 CI 即可。大版本换线（3.5 → 4.x LTS 之外的线）要重新核对 `INSTALL.md` 里每个 `no-*` 选项仍然存在，并重新读发布策略页确认支持期。
4. **CI 怎么验证**：打开 PR 后 `build.yml` 从源码重编、跑 `tests/openssl-static/run.sh`、再构建整包。任何一步失败都不能合并。失败最常见的原因是某个 `no-*` 选项被新版本改名或移除，或者某个保留功能依赖了被去掉的模块，脚本和测试会在构建阶段直接报出。
5. **支持期到头之前**：3.5 的支持到 2030-04-08。下一个 LTS 发布后，在 3.5 的最后一年换到新的 LTS 线，做法同第 2、3 步。

已知情况：公告页在 2026-11-10 和 11-17 列出的几条针对 3.5 的低危问题要等 3.5.10，发布后按上面的流程升级；它们都在 QUIC、TLS、CMS、AES-GCM-SIV、EC 或 `PEM_X509_INFO_read_bio_ex`（应用不调用）里，不涉及这份库实际链接的代码。
