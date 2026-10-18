# HyperTranslate

面向 macOS 的原生英译中划词工具。选中英文后点击附近的「译」图标，查看单词释义、音标、例句或整段译文，并可使用系统语音朗读。

## 功能

- 内置 ECDICT 离线英汉词库，支持常见词形查询，保留原词及原形解释。
- 使用 Apple Translation 在本机翻译英文句子、段落和例句；首次使用需要准备系统语言包。
- 免费在线词典补充最多两条例句，保留来源与许可并在本机缓存。
- 菜单栏常驻、手动输入、显式剪贴板翻译、暂停划词和英美朗读口音设置。

## 开发与使用

最低运行环境为 macOS 15。使用带 macOS SDK 的 Apple Swift 工具链构建，无第三方 Swift 包依赖。

```bash
git clone https://github.com/hehaiquan/HyperTranslate.git
cd HyperTranslate
bash scripts/test.sh
bash scripts/build_app.sh
open dist/HyperTranslate.app
```

源码包含完整 SQLite 词库及第三方数据许可。构建产物输出到 `dist/`，编译缓存和安装包不纳入 Git。

19 项定向测试已通过。跨应用取词需要辅助功能授权；实际整句翻译还依赖系统语言包安装完成，完整实机验收状态见功能记录。

- [使用说明](使用说明.md)
- [开发说明](开发说明.md)
- [功能实现与验证记录](功能记录-2026-10-18.md)
- [第三方来源与许可](../ThirdParty/THIRD-PARTY-NOTICES.md)
