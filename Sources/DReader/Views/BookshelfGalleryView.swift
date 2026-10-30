import SwiftUI
import AppKit

/// 纸张色原生书架场景。主题切换由 RealisticBookshelfView 管理，这里只负责长廊。
struct BookshelfGalleryView: View {
    let books: [EPUBBook]
    let onSelectBook: (EPUBBook) -> Void
    var onImportEPUB: (() -> Void)? = nil
    var onOpenXRay: ((EPUBBook) -> Void)? = nil
    var onResetProgress: ((UUID) -> Void)? = nil
    var onDeleteBook: ((UUID) -> Void)? = nil
    var emptyMessage = "书库暂时还没有藏书"
    var chineseScriptMode: ChineseScriptMode = .original

    @State private var model = BookshelfSceneViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var sceneFocused: Bool

    var body: some View {
        @Bindable var model = model
        GeometryReader { proxy in
            let height = min(max(220, proxy.size.height * 0.42), 340)
            let coverWidth = height * 0.527
            let spineWidth = height * 0.15
            let gap = height * 0.03

            ZStack {
                paperBackground
                if books.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 8) {
                        Spacer(minLength: 12)
                        ZStack {
                            ForEach(model.visibleItems()) { item in
                                let openness = model.openness(for: item.relative)
                                let isHovered = model.hoveredID == item.book.id
                                BookshelfGalleryBookView(
                                    book: item.book,
                                    openness: openness,
                                    isHovered: isHovered,
                                    spineWidth: spineWidth,
                                    coverWidth: coverWidth,
                                    height: height,
                                    chineseScriptMode: chineseScriptMode,
                                    reduceMotion: reduceMotion,
                                    onOpen: {
                                        sceneFocused = true
                                        model.select(item.book)
                                    },
                                    onOpenXRay: { onOpenXRay?(item.book) },
                                    onResetProgress: { onResetProgress?(item.book.id) },
                                    onDelete: { onDeleteBook?(item.book.id) }
                                )
                                .offset(
                                    x: BookshelfSceneViewModel.xOffset(
                                        relative: item.relative,
                                        spineWidth: spineWidth,
                                        coverWidth: coverWidth,
                                        gap: gap
                                    ),
                                    y: reduceMotion ? 0 : -openness * height * 0.035
                                        - (isHovered && openness < 0.5 ? height * 0.045 : 0)
                                )
                                .zIndex(100 - abs(item.relative) * 4)
                                .accessibilityValue("第 \(BookshelfSceneViewModel.wrapped(item.virtualIndex, books.count) + 1) 本，共 \(books.count) 本")
                                .onHover { hovering in
                                    if hovering {
                                        model.hoveredID = item.book.id
                                    } else if model.hoveredID == item.book.id {
                                        model.hoveredID = nil
                                    }
                                }
                            }
                        }
                        .frame(height: height + 88)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 5)
                                .onChanged { value in
                                    if !model.isDragging { model.startDragging() }
                                    model.dragChanged(translation: value.translation.width,
                                                      step: spineWidth + gap)
                                }
                                .onEnded { _ in model.endDragging() }
                        )

                        caption
                            .frame(maxWidth: min(proxy.size.width * 0.82, 700))
                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 24)

                    HStack {
                        arrowButton(systemName: "chevron.left", label: "上一本") {
                            model.move(by: -1)
                        }
                        Spacer()
                        arrowButton(systemName: "chevron.right", label: "下一本") {
                            model.move(by: 1)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 38)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .background(
                GalleryWheelBridge(enabled: model.detailID == nil) { delta in
                    model.scrollBy(delta)
                }
            )
            .focusable()
            .focused($sceneFocused)
            .onKeyPress(.leftArrow) {
                model.move(by: -1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                model.move(by: 1)
                return .handled
            }
            .onKeyPress(.home) {
                if let first = books.first { model.select(first.id) }
                return .handled
            }
            .onKeyPress(.end) {
                if let last = books.last { model.select(last.id) }
                return .handled
            }
            .onKeyPress(.return) {
                model.openSelected()
                return .handled
            }
            .onAppear {
                model.reduceMotion = reduceMotion
                model.updateBooks(books)
            }
            .onChange(of: books.map {
                "\($0.id.uuidString)-\($0.currentChapterIndex)-\($0.title)-\($0.author)-\($0.coverImageURL?.path ?? "")"
            }) { _, _ in
                model.updateBooks(books)
            }
            .onChange(of: reduceMotion) { _, reduced in
                model.reduceMotion = reduced
            }
            .sheet(item: Binding(
                get: { model.detailBook },
                set: { model.detailID = $0?.id }
            )) { book in
                BookshelfBookDetailView(
                    book: book,
                    onContinue: {
                        model.dismissDetail()
                        onSelectBook(book)
                    },
                    onOpenXRay: { onOpenXRay?(book) },
                    onResetProgress: { onResetProgress?(book.id) },
                    onDelete: { onDeleteBook?(book.id) },
                    chineseScriptMode: chineseScriptMode
                )
            }
        }
    }

    private var paperBackground: some View {
        ZStack {
            Color(hex: "#EDEBE6").ignoresSafeArea()
            LinearGradient(
                colors: [Color.white.opacity(0.18), Color.clear, Color(hex: "#B8B0A0").opacity(0.08)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 32))
                .foregroundStyle(Color(hex: "#1F3FB0"))
            Text(emptyMessage)
                .font(.system(size: 22, design: .serif))
                .foregroundStyle(Color(hex: "#141414"))
            if let onImportEPUB {
                Button("导入 EPUB", action: onImportEPUB)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "#1F3FB0"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var caption: some View {
        if let book = model.selectedBook {
            VStack(spacing: 8) {
                Text(ChineseScriptConverter.convert(book.title, mode: chineseScriptMode))
                    .font(.system(size: 29, weight: .regular, design: .serif))
                    .foregroundStyle(Color(hex: "#141414"))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .id(book.id)
                    .transition(.move(edge: .bottom))
                Text(ChineseScriptConverter.convert(book.author, mode: chineseScriptMode))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: "#1F3FB0"))
                    .lineLimit(1)
                Text("\(book.chapters.count) 章节 · 已读 \(Int(book.progress * 100))%")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(Color(hex: "#6D6A63"))
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: model.selectedID)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("当前书籍")
        }
    }

    private func arrowButton(systemName: String, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: {
            sceneFocused = true
            action()
        }) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(hex: "#141414"))
        .disabled(books.count <= 1)
        .accessibilityLabel(label)
    }
}

/// 仅在长廊窗口区域内处理滚轮；离开视图即移除，不读取系统输入权限。
private struct GalleryWheelBridge: NSViewRepresentable {
    let enabled: Bool
    let onDelta: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDelta: onDelta) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.enabled = enabled
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.enabled = enabled
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    private final class MonitorToken: @unchecked Sendable {
        let value: Any
        init(_ value: Any) { self.value = value }
        deinit { NSEvent.removeMonitor(value) }
    }

    @MainActor
    final class Coordinator {
        let onDelta: (Double) -> Void
        var enabled = true
        private weak var view: NSView?
        private var monitor: MonitorToken?

        init(onDelta: @escaping (Double) -> Void) {
            self.onDelta = onDelta
        }

        func install(on view: NSView) {
            guard monitor == nil else { return }
            self.view = view
            let token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { @MainActor [weak self, weak view] event in
                guard let self, self.enabled, let view, event.window === view.window else { return event }
                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location) else { return event }
                let x = event.scrollingDeltaX
                let y = event.scrollingDeltaY
                let dominant = abs(x) > abs(y) ? x : y
                guard abs(dominant) > 0.01 else { return event }
                let scale = event.hasPreciseScrollingDeltas ? 0.008 : 0.3
                self.onDelta(-Double(dominant) * scale)
                return nil
            }
            if let token { monitor = MonitorToken(token) }
        }

        func stop() {
            monitor = nil
            view = nil
        }
    }
}
