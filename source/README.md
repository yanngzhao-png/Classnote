# 从源码构建

需要 macOS 14+、Swift 6 工具链（Xcode 或 Command Line Tools）。源码使用 Swift 5 语言模式，无第三方运行时依赖。

```sh
cd source
swift run ClassnoteChecks
zsh build.sh
```

构建脚本在仓库根目录生成 Classnote.app 和 Classnote-macOS-arm64.zip，采用本地 ad-hoc 签名，不是 Apple 公证。构建前请退出同路径 App。当前发行包在 Apple 芯片机器构建；脚本 ZIP 名称固定含 arm64，在 Intel 机器上构建须另行验证并修正文件名，不能据文件名推断架构。

ClassnoteCore 保存课程、原稿、课件、课表和 Notion 同步逻辑；Classnote 提供原生界面、麦克风与 API 接入；Tests 为无需 XCTest 的回归检查。

此代码按根目录 LICENSE 提供，仅授权符合条款的非商业用途。保留现有固定署名与声明，不要将凭证或真实课堂资料提交至仓库。
