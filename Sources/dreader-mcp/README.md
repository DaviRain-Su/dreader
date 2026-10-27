# DReader MCP Server

把本地 DReader 书库（书架、划线、思考笔记、章节全文、阅读统计）暴露给任何 MCP 客户端——Claude Desktop、Claude Code、Cursor 等都能直接问「我在《明朝那些事儿》里划过哪些关于用人的句子」这类问题。

## 数据源（全部只读）

| 数据 | 位置 |
|---|---|
| 划线 / 思考 / 书签 / 复习排期 | `~/Library/Application Support/DReader/library.sqlite` |
| 书架 EPUB 文件 | `~/Library/Application Support/DReader/` 与 `.../DownloadedBooks/` |
| 已解压章节渲染缓存 | `~/Library/Caches/com.dreader.cache/<bookId>/` |

服务器与 GUI 完全解耦：GUI 不在运行也能查询；数据库是 WAL 模式，GUI 运行中也可以并发读取。

## 工具一览

| 工具 | 说明 |
|---|---|
| `list_books` | 书架全景：书名、作者、章节数、划线数、源文件名 |
| `search_highlights` | 跨书全文搜索划线与思考（`book_filter` 可限定单书） |
| `get_book_notes` | 单本书全部划线与思考，按章节分组 |
| `get_chapter_text` | 读某一章纯文本（可选 `convert_to_simplified` 一键转简体） |
| `get_reading_stats` | 知识库总览：总量、记忆通道分布、划线最多的书 |

书名支持模糊匹配与繁简归一——输入「三国演义」同样能命中繁体《三國志演義》。

## 接入 Claude Desktop

编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "dreader": {
      "command": "/Users/davirian/dreader/.build/release/dreader-mcp"
    }
  }
}
```

重启 Claude Desktop 即可在工具列表看到 5 个 DReader 工具。

## 接入 Claude Code

```bash
claude mcp add dreader -- /Users/davirian/dreader/.build/release/dreader-mcp
```

## 构建

```bash
swift build -c release --product dreader-mcp
```

手动冒烟测试：

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_reading_stats","arguments":{}}}' \
  | .build/release/dreader-mcp
```
