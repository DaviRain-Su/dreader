import SwiftUI

/// 键盘速查浮层：按 ?（或 ⇧?）唤起。列出阅读器与全局命令键位。
/// 设计纪律：无彩 chrome，键位用等宽胶囊，纸面卡片。
struct KeyboardCheatSheetView: View {
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.primary.opacity(0.25)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                header
                Divider().opacity(0.2)
                ScrollView {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 20) {
                            section("导航与工具", items: navItems)
                            section("阅读翻页与标注", items: readingItems)
                        }
                        VStack(alignment: .leading, spacing: 20) {
                            section("排版与显示", items: typographyItems)
                            section("AI 与朗读", items: aiItems)
                        }
                    }
                    .padding(24)
                }
            }
            .frame(minWidth: 640, idealWidth: 680, minHeight: 480, idealHeight: 520)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 26, y: 10)
            .padding(40)
        }
        .accessibilityLabel("键盘快捷键速查")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "command.square.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("键盘速查")
                    .font(.system(size: 15, weight: .bold, design: .serif))
                Text("不碰鼠标也能读成一整本书")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 键位数据

    private var navItems: [CheatItem] {
        [
            .init(keys: "⌘O", label: "打开本地 EPUB"),
            .init(keys: "⌘L", label: "在线书库（Open Library / OPDS…）"),
            .init(keys: "⌘B", label: "返回书架"),
            .init(keys: "Esc", label: "返回 / 逐层关闭浮层"),
            .init(keys: "⌘⇧W", label: "微信读书划线同步"),
            .init(keys: "⌘⇧N", label: "划线与思考中心"),
            .init(keys: "⌘G", label: "书单榜单目录"),
            .init(keys: "⌘⇧R", label: "划线 Mastery 复习"),
            .init(keys: "?", label: "本速查"),
        ]
    }

    private var readingItems: [CheatItem] {
        [
            .init(keys: "空格 / ↓", label: "向下翻一页（Shift 反向）"),
            .init(keys: "j / k", label: "下翻 / 上翻"),
            .init(keys: "Page ↑ ↓", label: "整页翻动"),
            .init(keys: "H", label: "高亮当前选中文字"),
            .init(keys: "N", label: "高亮并写想法"),
            .init(keys: "⌘[ ⌘]", label: "上一章 / 下一章"),
        ]
    }

    private var typographyItems: [CheatItem] {
        [
            .init(keys: "⌘+ ⌘-", label: "放大 / 缩小字号"),
            .init(keys: "⌘⇧D", label: "单页 / 双页对开"),
            .init(keys: "⌘Return", label: "禅意模式（全屏沉浸）"),
            .init(keys: "⌘⇧M", label: "显示 / 隐藏页边批注"),
            .init(keys: "⌘⇧L", label: "白天 / 夜间主题"),
            .init(keys: "⌘⇧C", label: "繁体 → 简体"),
        ]
    }

    private var aiItems: [CheatItem] {
        [
            .init(keys: "⌘⇧K", label: "AI 伴读面板"),
            .init(keys: "⌘T", label: "双语段落对照"),
            .init(keys: "⌘⇧T", label: "AI 全章翻译"),
            .init(keys: "⌘⇧S", label: "开始 / 暂停整章朗读"),
        ]
    }

    // MARK: - 渲染

    private func section(_ title: String, items: [CheatItem]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .serif))
                .foregroundStyle(.primary.opacity(0.85))
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.keys)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.primary.opacity(0.065))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .fixedSize()
                    Text(item.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private struct CheatItem: Identifiable {
        let keys: String
        let label: String
        var id: String { keys + label }
    }
}
