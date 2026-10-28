# DReader 回归测试

```bash
swift test
```

`ReaderInteractionTests` 使用真实 `NSWindow`、`WKWebView`、生产正文脚本和 `EPUBWebView.Coordinator`，覆盖翻页、动画解锁、选区与笔记、划线恢复、键盘标注、脚注、搜索定位、主题、双语、竖排、空章节、连续换章和相对资源。

`LibraryRegressionTests` 覆盖书架恢复顺序、封面请求合并与缩略图、后台字数统计、旧编码章节、索引保留及等待章节就绪后的定位。测试使用临时目录；不载入用户书库数据库，并在结束后恢复测试改动的阅读偏好。

可额外设置 `DREADER_REGRESSION_BOOK_ROOTS`，用冒号分隔本地已解压 EPUB 根目录，运行真实合订本长章测试。测试会创建副本，选择每本最大的两个正文文件，在副本中验证加载、翻页、划线、删除和章末按钮；原书保持不变。

```bash
DREADER_REGRESSION_BOOK_ROOTS='/path/to/extracted-book-one:/path/to/extracted-book-two' swift test
```

未设置该变量时，只跳过真实书籍样本测试。组件测试不能代替完整应用的所有界面检查；在线书库、微信同步、AI 服务和听书仍需要各自可用的账号、网络或语音环境。
