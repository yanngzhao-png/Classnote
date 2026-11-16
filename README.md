# Classnote

在 Mac 上听英文课，看双语字幕，下课后把课堂内容整理成有来源的中文复习笔记。

**免费使用 · 源码公开 · 禁止商用 · 作者：阿瑞斯又（抖音 / 小红书）**

Classnote 使用你自己的 OpenAI API Key。软件免费，API 调用可能产生费用。Notion 归档可选，不配置也能使用本地笔记。

## 能做什么

- 使用 Mac 麦克风转录英文，并在同一阅读区域显示中文翻译。
- 悬浮播放器、悬停字幕、历史回看和独立字号调整。
- 课后整理中文要点、概念、例子、术语和复习题。
- 导入有文字层的 PDF，将知识点关联到课堂原话和课件页码。
- 按课程管理课堂，导入课表，批量导出 Markdown。
- 将笔记归档到自己已有的 Notion 课程页，默认折叠原话与来源。

## 下载与开始

当前版本 **0.6.5 / build 18**，安装包支持 **Apple 芯片 Mac，macOS 14 或更新版本**。不提供 Windows 版本或已验证的 Intel 安装包。

发布后请在本仓库的 **Releases** 下载 `Classnote-v0.6.5-macOS-arm64.zip`；GitHub 的 Source code 压缩包是源码，不是安装包。

1. 解压，将 `Classnote.app` 拖入“应用程序”。
2. 打开 App，在设置中填入自己的 API Key 和账户可用的模型，检查连接。
3. 新建课堂，允许麦克风访问，先用一小段英文试录。
4. 结束课堂并等待整理完成；按需配置 Notion。

安装包尚未经过 Apple Developer ID 签名及公证。详细操作见[安装与配置](docs/GETTING-STARTED.md)。

## 看一个示例

[中文复习笔记与折叠来源示例](examples/NOTION-DEMO.md)展示最终阅读结构；这是基于虚构 Economics 课堂的人工排版示例，不是 Notion 截图或本次实测结果。

另附[实际 AI 生成的历史演示结果](examples/AI-GENERATED-DEMO.md)及[三页演示 PDF](source/Assets/Classnote-Economics-Demo.pdf)。输入为合成内容，不含真实课堂资料。

## 使用说明

- [安装、API 与常见问题](docs/GETTING-STARTED.md)
- [Notion 配置与同步](docs/NOTION.md)
- [数据去向与保存边界](docs/PRIVACY.md)
- [版本说明](CHANGELOG.md)
- [源码构建](source/README.md)

当前支持文字 PDF，不直接支持 PPTX、扫描 PDF 识字或图表理解。AI 可能误识别或错误归纳，重要内容请结合原话和课件核对。网络故障会暂停收音；本 App 不是独立的离线连续录音机。

## 授权与署名

允许符合许可条件的非商业使用、学习、修改和免费再分发。禁止未经书面授权的商业使用、收费售卖、付费打包或商业服务集成。再分发和修改版须保留署名及许可。完整条款以 [LICENSE](LICENSE) 为准。

本项目是**源码公开、非商业授权**，不是通常定义的自由开源软件。非商业限制不符合 [OSI 开源定义](https://opensource.org/osd)。

播放器保留轻量署名，首次启动及菜单中保留免费声明；主窗口不增加底部水印条，导出笔记正文不加入水印。

## 反馈

可在本仓库 Issues 描述问题，并附 macOS 版本、App 版本、复现步骤和已去除私人信息的截图。不要上传 API Key、Notion 凭证、私人课表链接或真实课堂录音。
