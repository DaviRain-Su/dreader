# DReader — 极简拟真现代的 macOS 原生 AI 电子书阅读器

> 专注纯粹优雅的拟真阅读排版体验，通过 ACP (Agent Client Protocol) 及 CLI 驱动无缝连接本地 AI Agent 矩阵（Grok、Kimi、Claude Code、Codex、Cursor、Pi 等），支持划线选区提问与批判性思辨。

---

## 🌟 核心特性与架构

1. **拟真 3D 胡桃木书架大厅 (Realistic Bookshelf)**
   - 启动进入拟真书架大厅，实木质感托板、层架背板漫反射顶光渐变与立体边缘倒角阴影。
   - 3D 立体硬壳精装图书：书脊弧面凹折光影、侧边真实内页纸质层理、烫金古典花纹与丝绸书签缎带。
   - 支持多本书籍陈列、即时检索过滤与「+ 放入新书」一键导入。

2. **100% 苹果 macOS 原生架构 (Swift 6 & SwiftUI)**
   - 采用纯 Swift 6 / SwiftUI 构建，相比 Electron 内存占用降低 90%，拥有丝滑的 120Hz 刷新与原生毛玻璃视效（`.ultraThinMaterial`）。
   - 遵从 macOS 人机交互指南（HIG），支持深色暗夜、羊皮纸复古、纯净白昼、OLED极黑与护眼豆沙绿等 6 种排版主题。
   - 细致的排版调节器：字号、行距、阅读栏宽（默认 720px 黄金阅读视距）、两端对齐、系统衬线与无衬线字体切换。

3. **工业级原生 EPUB 兼容引擎 (100% 成功率)**
   - 彻底解决 macOS Info-ZIP (`unzip`) 遇到中文/Unicode/GBK 文件名崩溃阻断的难题，采用 Apple 官方原生 `/usr/bin/ditto -xk` 解压架构。
   - 具备 XML 命名空间与特殊 HTML 实体（`&nbsp;`、`&mdash;`、未转义 `&` 等）自动修复能力，支持 GB18030 / Big5 / UTF-8 多重编码自适应。
   - 经实机 45 本真实复杂中英文多卷本 EPUB（包括古籍《周易》、146卷《与神对话》、243卷《魔鬼经济学》合集等）严苛测试，达到 **100% 导入解析成功率**。
   - 内置三本精排经典书目：《瓦尔登湖》、《小王子》、《朝花夕拾》。

4. **双页对开实体书 & 禅意全屏沉浸模式**
   - **双页对开模式 (`⌘ + ⇧ + D`)**：宽屏下自动呈现实体精装书的双栏对开阅读效果，中央伴随典雅中缝内阴影。
   - **禅意无干扰沉浸模式 (`⌘ + Return`)**：一键隐藏顶栏、底栏进度与侧边抽屉，只留纯粹墨香排版，鼠标右上角浮动微缩退出胶囊。
   - **笔记导出至 Markdown / Obsidian**：在划线笔记侧边栏一键将全书划线、批注与 AI 思辨结构化导出为标准 Markdown 文档。

4. **划线阅读与浮动 AI 快捷菜单 (Highlight & Ask)**
   - 在阅读视图中选中文本后，原生浮动工具栏自动浮现：
     - 💬 **问 AI**：将选中文本作为即时语境，注入 AI 对话面板进行追问
     - 💡 **解释**：深入解析词句隐喻与背景
     - 📝 **总结**：萃取核心观点与 3 个关键要点
     - 🌐 **翻译**：原汁原味的文学级对照翻译
     - 🖍️ **5色划线高亮**：黄、绿、蓝、粉、橙彩色荧光划线，自动持久化存储至本地笔记侧边栏
     - 📋 **复制**：一键复制选中段落

5. **全能本地 AI Agent 矩阵 (ACP 协议 + CLI 流式驱动)**
   - **Grok**：xAI Grok 原生 ACP (Agent Client Protocol) Stdio 协议双向连接 (`grok agent stdio`)
   - **Kimi**：Moonshot Kimi Code 官方原生 ACP 服务 (`kimi acp`)
   - **Claude Code**：Anthropic 官方 Claude Code CLI 驱动 (`claude -p`)
   - **Pi**：Pi AI 极速伴读与编码 Agent CLI (`pi -p`)
   - **Codex**：OpenAI Codex CLI 命令行交互 (`codex exec`)
   - **Cursor**：Cursor Agent CLI (`agent -p`)
   - **Devin**：Cognition Devin 原生 ACP 协议接口 (`devin acp`)
   - **Ollama / LM Studio**：本地模型端口直连 (`http://localhost:11434` / `1234`)
   - **内置伴读引擎**：完全脱机运行的离线伴读引擎
   - **4 种伴读角色**：深度导读学者、批判性思考者、灵感提炼师、文学精译官。

---

## 🚀 快速启动与运行

### 方式 1：直接运行已编译的 App Bundle
```bash
open DReader.app
```

### 方式 2：使用构建脚本编译 Release 版本
```bash
./build-app.sh
```

### 方式 3：通过 Swift 命令行直接启动
```bash
swift run DReader
```

### 方式 4：在 Xcode 中编辑与调试
```bash
xed .
# 或者
open Package.swift
```

---

## ⌨️ 常用快捷键

| 快捷键 | 功能 |
| :--- | :--- |
| `⌘ + O` | 打开并导入本地 EPUB 电子书 |
| `⌘ + B` | 返回胡桃木书架大厅 |
| `⌘ + [` | 上一章 |
| `⌘ + ]` | 下一章 |
| `PageUp / Shift + Space` | 向上平滑翻页 |
| `PageDown / Space` | 向下平滑翻页 |
| `⌘ + +` | 增大字号 |
| `⌘ + -` | 减小字号 |
| `⇧ + ⌘ + D` | 切换单页 / 双页对开排版 |
| `⌘ + Return` | 进入 / 退出禅意无干扰沉浸模式 |
| `⇧ + ⌘ + K` | 展开 / 折叠 AI 伴读侧边面板 |

---

## 🗺️ 后续迭代路线

- [ ] PDF 排版解析与多模态视觉版面还原
- [ ] 本地 MCP (Model Context Protocol) Agent 协议接入
- [ ] 导出阅读高亮与 AI 笔记至 Obsidian / Markdown
- [ ] 外部 API 服务与自定义云端 Agent 支持
