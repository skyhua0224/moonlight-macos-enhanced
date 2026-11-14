# Acknowledgements / 致谢

This repository is an enhanced macOS distribution in the Moonlight ecosystem. The copyright line used by this fork reflects the maintenance and release identity of this repository, while upstream projects retain their own copyrights, licenses, and attribution.

本仓库是 Moonlight 生态中的增强版 macOS 发行分支。此分支使用的版权标注仅对应本仓库的维护与发布身份；各上游项目仍保留各自的版权、许可证与署名要求。

## Direct Code Lineage / 直接代码谱系

- **[`moonlight-macos`](https://github.com/MichaelMKenny/moonlight-macos)** — Native macOS client foundation for this repository / 本仓库最直接的 macOS 客户端基础来源
- **[`moonlight-ios`](https://github.com/moonlight-stream/moonlight-ios)** — Historical Limelight/Moonlight client lineage that earlier macOS work was derived from / 更上层的 Limelight / Moonlight 客户端历史谱系来源
- **[`moonlight-common-c`](https://github.com/moonlight-stream/moonlight-common-c)** — Core GameStream/Sunshine client protocol implementation used by the project / 项目使用的核心 GameStream / Sunshine 客户端协议实现
- **[`qiin2333/moonlight-common-c`](https://github.com/qiin2333/moonlight-common-c)** — Important integration reference for the microphone-capable common-c path used in this enhanced branch / 当前增强分支中麦克风相关 common-c 能力的重要集成参考

## Feature And Behavior References / 功能与行为参考

- **[`moonlight-qt`](https://github.com/moonlight-stream/moonlight-qt)** — Reference for streaming defaults, settings parity, UX behavior, and tuning heuristics / 串流默认值、设置一致性、交互行为与调优策略的重要参考
- **[`qiin2333/moonlight-qt`](https://github.com/qiin2333/moonlight-qt)** — Additional feature reference from the Foundation Sunshine ecosystem / Foundation Sunshine 生态中的补充功能参考

## Host Ecosystem And Interoperability / 主机端生态与互操作参考

- **[`LizardByte/Sunshine`](https://github.com/LizardByte/Sunshine)** — Primary open host ecosystem targeted by modern Moonlight clients / 现代 Moonlight 客户端对接的主要开源主机端生态
- **[`qiin2333/foundation-sunshine`](https://github.com/qiin2333/foundation-sunshine)** — Enhanced Sunshine fork relevant to microphone support, virtual display workflows, and extended interoperability / 与麦克风支持、虚拟显示流程和扩展互操作能力密切相关的增强版 Sunshine 分支

## Third-Party Libraries / 第三方库

- **[`FFmpeg`](https://ffmpeg.org/)** (LGPL-2.1-or-later) — AV1 bitstream handling, statically linked / 静态链接
- **[`Opus`](https://opus-codec.org/)** (BSD-3-Clause) — Audio codec / 音频编解码
- **[`OpenSSL`](https://www.openssl.org/)** (Apache-2.0) — Cryptography / 加密能力
- **[`Sparkle`](https://sparkle-project.org/)** (MIT) — Updates / 应用更新
- **[`ENet`](https://github.com/cgutman/enet)** (MIT) and the Reed-Solomon FEC code inside `moonlight-common-c` / 位于 moonlight-common-c 内的 ENet 与前向纠错代码
- **[`dav1d`](https://code.videolan.org/videolan/dav1d)** (BSD 2-Clause, © VideoLAN and dav1d authors) — AV1 decoding on Macs without an AV1 hardware decoder; the full license texts are in the app under About > Third-Party Licenses / 在没有 AV1 硬件解码的 Mac 上解码 AV1；全部许可证全文在应用的“关于 > 第三方许可证”中

## Bundled Data / 随应用附带的数据

- **[`AutoEq`](https://github.com/jaakkopasanen/AutoEq)** (MIT License, Copyright © 2018-2022 Jaakko Pasanen) — Parametric equalizer results used for headphone correction; the license text is kept at the top of `HeadphoneCorrections.tsv` / 耳机校正使用的参数均衡结果；许可证全文保留在 `HeadphoneCorrections.tsv` 文件开头

## Scope Note / 范围说明

This file highlights the major upstream projects and ecosystem references that materially shaped this repository. It is not intended to replace full license texts or every transitive dependency notice. For complete legal terms, please also refer to `LICENSE.txt`, bundled third-party license files, package manifests, and submodule histories.

此文件重点列出对本仓库有实质影响的主要上游项目与生态参考，不用于替代完整许可证文本，也不覆盖所有传递依赖的署名说明。完整法律条款仍请同时参阅 `LICENSE.txt`、随仓库附带的第三方许可证文件、包管理清单与子模块历史。
