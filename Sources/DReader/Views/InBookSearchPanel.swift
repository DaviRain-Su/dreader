import SwiftUI

/// Apple Books Style Floating In-Book Search Panel
/// 双域搜索：这本书 / 整个书库（跨书全文检索，按书分组展示）
struct InBookSearchPanel: View {
    @Bindable var vm: ReaderViewModel
    @FocusState private var isFieldFocused: Bool
    @State private var isResultsDrawerExpanded: Bool = false
    @State private var scope: SearchScope = .thisBook

    enum SearchScope: String {
        case thisBook
        case wholeLibrary
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            // Main Search Capsule
            HStack(spacing: 8) {
                // Search Icon
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.75))

                // Locator Switch: 本书 / 全书库
                HStack(spacing: 2) {
                    scopeButton(.thisBook, title: "本书")
                    scopeButton(.wholeLibrary, title: "书库")
                }
                .padding(2)
                .background(Color.primary.opacity(0.05))
                .clipShape(Capsule())

                // Input Field
                TextField(scope == .wholeLibrary ? "在整个书库中搜索..." : "搜索书中文字 (⌘F)...", text: Binding(
                    get: { vm.searchQuery },
                    set: { newValue in
                        if scope == .wholeLibrary {
                            vm.performCrossBookSearch(query: newValue)
                        } else {
                            vm.performSearch(query: newValue)
                        }
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .frame(width: scope == .wholeLibrary ? 138 : 150)
                .focused($isFieldFocused)
                .onSubmit {
                    if scope == .thisBook { vm.nextSearchResult() }
                }

                // Match Count / Spinner
                if scope == .wholeLibrary {
                    if vm.isCrossBookSearching {
                        ProgressView()
                            .controlSize(.mini)
                    } else if !vm.searchQuery.isEmpty {
                        if vm.crossBookGroups.isEmpty {
                            Text("无匹配")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            let hits = vm.crossBookGroups.reduce(0) { $0 + $1.totalCount }
                            Text("\(vm.crossBookGroups.count) 本 · \(hits) 处")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                } else {
                    if vm.isSearching {
                        ProgressView()
                            .controlSize(.mini)
                    } else if !vm.searchQuery.isEmpty {
                        if vm.searchResults.isEmpty {
                            Text("无匹配")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(vm.currentSearchIndex + 1)/\(vm.searchResults.count)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(0.75))
                        }
                    }
                }

                if scope == .thisBook && !vm.searchQuery.isEmpty {
                    // Prev Button
                    Button {
                        vm.prevSearchResult()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.searchResults.isEmpty)
                    .help("上一处 (Shift+Enter)")

                    // Next Button
                    Button {
                        vm.nextSearchResult()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.searchResults.isEmpty)
                    .help("下一处 (Enter)")
                }

                // Toggle Results List Drawer
                if !vm.searchQuery.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isResultsDrawerExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isResultsDrawerExpanded ? "list.bullet.circle.fill" : "list.bullet")
                            .font(.system(size: 11))
                            .foregroundStyle(isResultsDrawerExpanded ? Color.primary.opacity(0.8) : Color.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(isResultsDrawerExpanded ? "收起搜索列表" : "展开所有搜索结果")
                }

                Divider()
                    .frame(height: 12)
                    .opacity(0.3)

                // Close Button
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        vm.isSearchPresented = false
                        vm.searchQuery = ""
                        vm.searchResults = []
                        vm.crossBookGroups = []
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭搜索 (Esc)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 5)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 0.6)
            )

            // Results List Drawer
            if isResultsDrawerExpanded && !vm.searchQuery.isEmpty {
                if scope == .wholeLibrary {
                    crossBookDrawer
                } else if !vm.searchResults.isEmpty {
                    thisBookDrawer
                }
            }
        }
        .onAppear {
            isFieldFocused = true
        }
    }

    // MARK: - 单域按钮

    private func scopeButton(_ target: SearchScope, title: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                if scope != target {
                    scope = target
                    if target == .wholeLibrary,
                       !vm.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        vm.performCrossBookSearch(query: vm.searchQuery)
                    } else if target == .thisBook,
                              !vm.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        vm.performSearch(query: vm.searchQuery)
                    }
                }
            }
        } label: {
            Text(title)
                .font(.system(size: 10, weight: scope == target ? .semibold : .regular))
                .foregroundStyle(scope == target ? Color.white : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(scope == target ? Color.primary.opacity(0.75) : Color.primary.opacity(0.02), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 本书结果抽屉（原有）

    @ViewBuilder
    private var thisBookDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("共找到 \(vm.searchResults.count) 处匹配")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
                .opacity(0.2)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(vm.searchResults.enumerated()), id: \.element.id) { index, item in
                        Button {
                            vm.jumpToSearchResult(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.chapterTitle)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(index == vm.currentSearchIndex ? Color.primary.opacity(0.85) : Color.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    if index == vm.currentSearchIndex {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Color.primary.opacity(0.75))
                                    }
                                }

                                // Snippet with highlighted keyword
                                HStack(spacing: 0) {
                                    Text("..." + item.snippetBefore)
                                        .font(.system(size: 11, design: .serif))
                                        .foregroundStyle(Color.primary.opacity(0.8))
                                    Text(item.keyword)
                                        .font(.system(size: 11, weight: .bold, design: .serif))
                                        .foregroundStyle(Color.orange)
                                        .background(Color.yellow.opacity(0.25))
                                    Text(item.snippetAfter + "...")
                                        .font(.system(size: 11, design: .serif))
                                        .foregroundStyle(Color.primary.opacity(0.8))
                                }
                                .lineLimit(2)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(index == vm.currentSearchIndex ? Color.primary.opacity(0.08) : Color.primary.opacity(0.02))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .frame(height: min(280, CGFloat(vm.searchResults.count * 52)))
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.6)
        )
        .padding(.top, 6)
        .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
    }

    // MARK: - 跨书结果抽屉（按书分组）

    private var crossHeaderLabel: String {
        if vm.isCrossBookSearching { return "正在搜索整个书库..." }
        if vm.crossBookGroups.isEmpty { return "书库中没有命中" }
        let hits = vm.crossBookGroups.reduce(0) { $0 + $1.totalCount }
        return "在 \(vm.crossBookGroups.count) 本书中共 \(hits) 处匹配"
    }

    private var crossDrawerHeight: CGFloat {
        if vm.isCrossBookSearching { return 60 }
        var rows = 1
        for group in vm.crossBookGroups { rows += min(group.items.count, 12) + 2 }
        return min(300, CGFloat(rows * 24))
    }

    @ViewBuilder
    private var crossBookDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(crossHeaderLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
                .opacity(0.2)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.crossBookGroups) { group in
                        // Book Section Header
                        HStack(spacing: 6) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.75))
                            Text(group.bookTitle)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(0.85))
                                .lineLimit(1)
                            Spacer()
                            Text("\(group.totalCount) 处")
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 2)

                        ForEach(group.items.prefix(12)) { item in
                            Button {
                                vm.openCrossBookResult(item)
                            } label: {
                                HStack(spacing: 0) {
                                    Text(item.chapterTitle.isEmpty ? "第 \(item.chapterIndex + 1) 章" : "")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 86, alignment: .leading)

                                HStack(spacing: 0) {
                                    Text(item.fullSnippet)
                                        .font(.system(size: 10.5, design: .serif))
                                        .foregroundStyle(Color.primary.opacity(0.8))
                                }
                                .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.02))
                            )
                        }

                        if group.items.count > 12 {
                            Text("该书还有 \(group.items.count - 12) 处更多匹配…")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                        }
                    }
                }
                .padding(8)
            }
            .frame(height: crossDrawerHeight)
        }
        .frame(width: 360)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.6)
        )
        .padding(.top, 6)
        .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
    }
}
