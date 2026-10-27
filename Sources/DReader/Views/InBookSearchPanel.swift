import SwiftUI

/// Apple Books Style Floating In-Book Search Panel
struct InBookSearchPanel: View {
    @Bindable var vm: ReaderViewModel
    @FocusState private var isFieldFocused: Bool
    @State private var isResultsDrawerExpanded: Bool = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            // Main Search Capsule
            HStack(spacing: 8) {
                // Search Icon
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.purple)

                // Input Field
                TextField("搜索书中文字 (⌘F)...", text: Binding(
                    get: { vm.searchQuery },
                    set: { vm.performSearch(query: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .frame(width: 170)
                .focused($isFieldFocused)
                .onSubmit {
                    vm.nextSearchResult()
                }

                // Match Count / Spinner
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
                            .foregroundStyle(Color.purple)
                    }
                }

                if !vm.searchQuery.isEmpty {
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

                    // Toggle Results List Drawer
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isResultsDrawerExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isResultsDrawerExpanded ? "list.bullet.circle.fill" : "list.bullet")
                            .font(.system(size: 11))
                            .foregroundStyle(isResultsDrawerExpanded ? Color.purple : Color.secondary)
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
            if isResultsDrawerExpanded && !vm.searchResults.isEmpty {
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
                                                .foregroundStyle(index == vm.currentSearchIndex ? Color.purple : Color.secondary)
                                                .lineLimit(1)
                                            Spacer()
                                            if index == vm.currentSearchIndex {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundStyle(Color.purple)
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
                                            .fill(index == vm.currentSearchIndex ? Color.purple.opacity(0.1) : Color.primary.opacity(0.02))
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
        }
        .onAppear {
            isFieldFocused = true
        }
    }
}
