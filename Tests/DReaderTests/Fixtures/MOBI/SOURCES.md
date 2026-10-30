# MOBI fixtures 来源

这些 .mobi 样例来自 [libmobi](https://github.com/bfabiszewski/libmobi) v0.12 的
`tests/samples/` 目录（LGPL-3.0-or-later，作者 Bartek Fabiszewski），
复制用于 DReader 的 MOBI 导入回归测试：

- `sample-ncx.mobi` — hybrid KF8，带 NCX（章切分验证）
- `sample-drm-v1.mobi` — DRM v1 加密样例（DRM 报错验证）
- `sample-unicode-uncompressed.mobi` — UTF-8 无压缩（端到端组装验证）
- `sample-textread.mobi` — 带压缩文本（解析路径验证）
