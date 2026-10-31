import SwiftUI

// MARK: - 页边批注布局纯函数

/// Tufte 式页边批注：把有思考的划线以批注卡贴在正文两侧空白。
/// 布局全部为纯函数，便于单元测试（左右分配 / 跨栏锚点 / 重叠下推 / 溢出裁剪）。
enum MarginNotesLayout {

    static let topPadding: CGFloat = 72        // 顶部预留：避右上 DogEar 书签角标
    static let bottomClipInset: CGFloat = 12   // 卡底超出视口剩余空间 → 整卡裁掉计 dropped
    static let cardGap: CGFloat = 8            // 同侧卡重叠时依次下推的间距
    static let cardEdgeInsets: CGFloat = 10    // 卡与正文盒的水平间距
    static let scrollbarInset: CGFloat = 14    // 右缘让位常显滚动条
    static let maxCardWidth: CGFloat = 184
    static let minZoneWidth: CGFloat = 180     // 该侧留白窄于此 → 整侧不排卡
    static let displayBand: CGFloat = 64       // 视口带外延（±64px 内的碎片仍算可视锚区）

    enum HorizontalSide: CaseIterable {
        case left, right
    }

    /// 一张页边卡的计算位置（top 为卡顶 y，centerX 为卡心 x，均与 webview 同坐标系）
    struct Placement: Equatable {
        let id: UUID
        let side: HorizontalSide
        let centerX: CGFloat
        let top: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    /// 由一个划线元素的全部 getClientRects 碎片推出页边锚定矩形。
    /// - 只取与视口垂直带 [-64, vh+64] 相交的碎片（content-visibility 场景碎片可能在带外）
    /// - 跨栏（spread 左右栏，横向差 >40px）或碎片 ≥4 → 取可视面积最大的单片，union 会横跨中缝
    /// - 否则取碎片 union bounding（同栏多行划线）
    static func resolveAnchor(frags: [CGRect], viewportHeight: CGFloat) -> CGRect? {
        let clean = frags.filter { $0.width > 0.5 && $0.height > 0.5 }
        guard !clean.isEmpty else { return nil }
        let candidates = clean.filter { $0.maxY > -displayBand && $0.minY < viewportHeight + displayBand }
        let pool = candidates.isEmpty ? clean : candidates
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for frag in pool {
            minX = min(minX, frag.minX)
            maxX = max(maxX, frag.maxX)
            minY = min(minY, frag.minY)
            maxY = max(maxY, frag.maxY)
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        // 跨栏判定看行起点横向聚类差（行宽差异不影响 maxX 判定）
        let startSpread = (pool.map(\.minX).max() ?? minX) - (pool.map(\.minX).min() ?? minX)
        let isCrossColumn = startSpread > 40 || pool.count >= 4
        if isCrossColumn {
            return pool.max { anchorArea($0, viewportHeight) < anchorArea($1, viewportHeight) }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 相对视口的可视面积（交叠高度 × 片宽），用于跨栏时选锚片
    private static func anchorArea(_ frag: CGRect, _ viewportHeight: CGFloat) -> CGFloat {
        let interH = max(0, min(frag.maxY, viewportHeight) - max(frag.minY, 0))
        return interH * frag.width
    }

    /// 排布：按 anchor.minY 排序、中线分左右、同侧重叠依次下推、溢出整卡裁掉计 dropped。
    /// 留白 < minZoneWidth 的侧不排卡（不计 dropped）。卡宽 min(maxCardWidth, zone−16)，实测高未到时以 96 兜底。
    static func place(
        anchors: [UUID: CGRect],
        bodyRect: CGRect,
        viewport: CGSize,
        cardHeights: [UUID: CGFloat]
    ) -> (placements: [Placement], droppedLeft: Int, droppedRight: Int) {
        guard bodyRect.width > 0, viewport.width > 0, viewport.height > 0 else { return ([], 0, 0) }

        let leftZone = bodyRect.minX - cardEdgeInsets
        let rightZone = viewport.width - scrollbarInset - bodyRect.maxX - cardEdgeInsets
        let leftWidth = min(maxCardWidth, leftZone - 16)
        let rightWidth = min(maxCardWidth, rightZone - 16)

        var nextBottom: [HorizontalSide: CGFloat] = [:] // 同侧已排到卡的累计 bottom（下推基准）
        var droppedLeft = 0
        var droppedRight = 0
        var placements: [Placement] = []

        let sorted = anchors.sorted { $0.value.minY < $1.value.minY }
        for (id, anchor) in sorted {
            let side: HorizontalSide = anchor.midX <= bodyRect.midX ? .left : .right
            let zone = side == .left ? leftZone : rightZone
            let width = side == .left ? leftWidth : rightWidth
            guard zone >= minZoneWidth else { continue } // 留白窄：整侧跳过（不计 dropped）
            let height = cardHeights[id] ?? 96
            // 顶部预留 72；同侧已有卡则至少接在其下 8px
            var top = max(anchor.minY, topPadding)
            if let prev = nextBottom[side], top < prev + cardGap {
                top = prev + cardGap
            }
            if top + height > viewport.height - bottomClipInset {
                if side == .left { droppedLeft += 1 } else { droppedRight += 1 }
                continue
            }
            nextBottom[side] = top + height
            let centerX = side == .left
                ? bodyRect.minX - cardEdgeInsets - width / 2
                : bodyRect.maxX + cardEdgeInsets + width / 2
            placements.append(Placement(id: id, side: side, centerX: centerX, top: top, width: width, height: height))
        }
        return (placements, droppedLeft, droppedRight)
    }
}

// MARK: - 页边批注卡片

/// 页边批注完整卡：色点 + 划线原文段 + 思考全文 + 元数据行；点击进入划线详情卡
struct MarginNoteCardView: View {
    let highlight: Highlight
    let width: CGFloat
    let isActive: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    private var colorDot: Color { Color(hex: highlight.colorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Circle()
                    .fill(colorDot)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                Text(highlight.displaySource)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "quote.opening")
                    .font(.system(size: 8.5))
                    .foregroundStyle(colorDot.opacity(0.9))
            }
            // 划线原文段：完整内容就长在页面上，这里截 4 行提示出处
            Text(highlight.text.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.6))
                .lineSpacing(2.5)
                .lineLimit(4)
            // 思考全文：页边批注的主角，原样呈现
            Text(highlight.note ?? "")
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.95))
                .lineSpacing(3)
            Text(highlight.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 9))
                .foregroundStyle(Color.primary.opacity(0.4))
                .lineLimit(1)
        }
        .padding(9)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .shadow(color: .black.opacity(isHovering || isActive ? 0.2 : 0.1), radius: isHovering || isActive ? 10 : 6, x: 0, y: isHovering || isActive ? 4 : 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.primary.opacity(isHovering || isActive ? 0.24 : 0.12), lineWidth: 0.5)
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onTap)
    }
}

// MARK: - 页边批注浮层

/// 页边批注浮层：在 ReaderMainView 的 GeometryReader 内与 webview 同 frame，JS px 坐标直接定位。
/// 详情卡打开时整层隐藏（关闭即恢复）；换章对账不符时静默不渲染。
struct MarginNotesOverlay: View {
    let vm: ReaderViewModel
    let areaSize: CGSize

    @State private var cardHeights: [UUID: CGFloat] = [:]

    private var isFeatureActive: Bool {
        vm.settings.isMarginNotes && !vm.settings.isZenMode && !vm.settings.isVertical
    }

    private var chapterPath: String? {
        vm.currentBook?.currentChapter?.fileURL.path
    }

    var body: some View {
        Group {
            if isFeatureActive,
               vm.selectionManager.activeHighlightCard == nil, // 详情卡打开期间整层让位
               vm.isSearchPresented == false,
               !vm.isViewingBookshelf,
               chapterPath != nil,
               vm.marginNoteChapterKey == chapterPath,
               vm.marginViewport.width > 0, vm.marginViewport.height > 0,
               vm.marginBodyRect.width > 0,
               !vm.marginNoteRects.isEmpty {
                content
            }
        }
        .onChange(of: vm.selectionManager.activeHighlightCard) { newInfo in
            // B4：详情卡关闭（冻结解除）后补一轮重拉，把冻结期间的滚动位移接上
            if newInfo == nil {
                vm.requestMarginRects(.relayout)
            }
        }
    }

    private var content: some View {
        let layout = MarginNotesLayout.place(
            anchors: vm.marginNoteRects,
            bodyRect: vm.marginBodyRect,
            viewport: vm.marginViewport,
            cardHeights: cardHeights
        )
        let droppedTotal = layout.droppedLeft + layout.droppedRight
        return ZStack(alignment: .topLeading) {
            ForEach(layout.placements, id: \.id) { placement in
                if let highlight = vm.highlights.first(where: { $0.id == placement.id }) {
                    MarginNoteCardView(
                        highlight: highlight,
                        width: placement.width,
                        isActive: false,
                        onTap: {
                            vm.selectionManager.activeHighlightCard = HighlightCardInfo(
                                highlightId: placement.id,
                                x: placement.centerX,
                                y: placement.top,
                                bottomY: placement.top + placement.height
                            )
                        }
                    )
                    .offset(x: placement.centerX - placement.width / 2, y: placement.top)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { measured in
                        if abs(measured - (cardHeights[placement.id] ?? 0)) > 1 {
                            cardHeights[placement.id] = measured
                        }
                    }
                }
            }
            if droppedTotal > 0 {
                overflowPill(dropped: droppedTotal)
            }
        }
        // 换章重置实测高（旧章卡高度与新章无关）
        .id(vm.marginNoteChapterKey)
    }

    /// 溢出裁掉的卡数 → 侧栏划线页入口胶囊（挂视口下缘）
    private func overflowPill(dropped: Int) -> some View {
        Button {
            vm.sidebarTab = .highlights
            vm.isSidebarVisible = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 9.5))
                Text("+\(dropped) 条想法")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Color.primary.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 10)
        .allowsHitTesting(true)
    }
}
