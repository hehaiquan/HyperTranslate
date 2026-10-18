# 第三方数据与系统能力

## ECDICT

- 项目：https://github.com/skywind3000/ECDICT
- 固定提交：`bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b`
- 使用文件：`ecdict.csv`。词条、音标、释义及词形变化转换到 SQLite；未使用或重新发布 `lemma.en.txt`。
- 许可：上游 MIT License。原文位于应用资源 `ThirdParty/ECDICT-LICENSE.txt`。
- 数据版本及源文件 SHA-256：`ThirdParty/ECDICT-metadata.json`。
- 词库中音标存在缺失或采用传统记音方式；应用不将其标为与系统朗读一致的英式/美式 IPA。

## Free Dictionary API / Wiktionary

- 接口说明：https://dictionaryapi.dev/
- 接口：`https://api.dictionaryapi.dev/api/v2/entries/en/<word>`。
- 单词例句通常来自 Wiktionary；每次响应的 `sourceUrls` 和 `license` 作为数据一并保留，显示在各条例句下。
- 例如 CC BY-SA 3.0：https://creativecommons.org/licenses/by-sa/3.0/ 。各条例句以接口实际返回的许可为准。
- 原始英文例句不改写；中文译文由 Apple Translation 生成，属于翻译内容，随原例句保留来源和相同许可声明。
- 例句及中文译文仅缓存在本机。服务没有可用性保证；无收录、断网或限流不影响离线词典。

## Apple 系统框架

- 选区读取：ApplicationServices Accessibility API，需用户授权辅助功能。
- 句子及例句翻译：Translation framework；在支持策略选择的系统上明确使用 `lowLatency` 传统本地模型。
- 发音：AVFoundation AVSpeechSynthesizer，本机合成英语朗读，不提供真人音频。
- 本项目不打包或重新分发苹果系统语言模型、词典数据或语音资源。
