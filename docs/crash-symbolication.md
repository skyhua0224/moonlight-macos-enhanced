# 崩溃报告与日志调用栈的符号化

发布构建不带本地符号：主程序里约 15 MB 的符号表在构建时被剥离（项目 Release 配置 `STRIP_STYLE = non-global`），保留导出的全局符号。每次构建的函数名、源文件和行号放在同一次构建产生的 dSYM 里，随发布一起保存，按 UUID 与二进制一一对应。

## 去哪里取 dSYM

- 每个 Release 附带 `MoonlightEnhanced-dSYM-arm64.zip` 与 `MoonlightEnhanced-dSYM-x86_64.zip`。arm64、x86_64、universal 三种 DMG 里的二进制都来自这两次构建（universal 的两个切片分别取自它们），所以这两个 dSYM 覆盖全部三种安装包。每个 zip 含主程序和文件提供扩展两个 `.dSYM`。
- 同一份文件也在对应 CI 运行的产物里（`Moonlight-macOS-dsym-arm64`、`Moonlight-macOS-dsym-x86_64`），保留期按仓库的产物设置。需要长期保存的以 Release 附件为准。
- 要用哪个版本的 dSYM：看报告里的 App 版本与 Build 号，取同名 tag 的 Release。拿不准时用 UUID 核对：`dwarfdump --uuid MoonlightEnhanced.app/Contents/MacOS/MoonlightEnhanced` 与 `dwarfdump --uuid MoonlightEnhanced.app.dSYM` 必须一致。

## 三种来源怎么符号化

脚本只用系统自带的 `atos` 和 `dwarfdump`，需要在 macOS 上运行：

```
scripts/symbolicate_crash.py <报告或日志> --dsym <MoonlightEnhanced.app.dSYM>
```

- **系统崩溃报告**（`~/Library/Logs/DiagnosticReports/MoonlightEnhanced-*.ips`）：脚本读出 `usedImages` 里的 UUID 与加载地址，与 dSYM 核对后，把属于本应用的每一帧解析到 `函数 (文件:行)`。UUID 不一致时直接拒绝，不会给出错位的结果。把 dSYM 放进 Spotlight 能索引的目录，Console 与 Xcode 也会自动符号化。
- **应用日志里的调用栈行**（诊断日志中 `Thread.callStackSymbols` / `callStackSymbols` 写出的行，形如 `3   MoonlightEnhanced   0x… MoonlightEnhanced + 807028`）：同一个脚本处理，整份日志直接传入，命中的行下面会附上解析结果。这些行没有符号名时，加载地址由 `地址 − 偏移` 得出；行里写的是附近某个导出符号名时，用 `--load-address` 传入加载地址。
- **Sparkle 更新**：更新流程本身不使用符号。用户从哪个版本崩溃，就取那个版本的 dSYM；更新前后的版本各有自己的 Release 与 dSYM，不能混用。

脚本对返回地址取前一字节再解析（调用指令所在行，而不是返回点所在行），与系统崩溃报告自己的行号一致。
