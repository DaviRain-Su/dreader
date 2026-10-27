import SwiftUI

enum XRayFilterSegment: String, CaseIterable, Identifiable {
    case all = "全部"
    case characters = "人物谱系"
    case concepts = "核心概念"
    case timeline = "脉络时序"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "sparkles.rectangle.stack"
        case .characters: return "person.2.fill"
        case .concepts: return "lightbulb.fill"
        case .timeline: return "clock.arrow.circlepath"
        }
    }
}

/// Kindle-style Book X-Ray Inspection Panel in Sidebar
struct BookXRayView: View {
    let book: EPUBBook
    let onJumpToChapter: (Int) -> Void
    let onSearchTerm: (String) -> Void
    let onAskAIAboutTerm: (String) -> Void

    @State private var selectedFilter: XRayFilterSegment = .all
    @State private var searchText: String = ""

    private var xrayData: BookXRayData {
        BookXRayService.shared.getXRayData(for: book)
    }

    private var filteredCharacters: [XRayCharacter] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return xrayData.characters }
        return xrayData.characters.filter {
            $0.name.lowercased().contains(query) ||
            $0.role.lowercased().contains(query) ||
            $0.identity.lowercased().contains(query) ||
            $0.description.lowercased().contains(query) ||
            $0.keyTraits.contains { $0.lowercased().contains(query) }
        }
    }

    private var filteredConcepts: [XRayConcept] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return xrayData.concepts }
        return xrayData.concepts.filter {
            $0.term.lowercased().contains(query) ||
            $0.category.lowercased().contains(query) ||
            $0.shortDefinition.lowercased().contains(query) ||
            $0.inDepthExplanation.lowercased().contains(query)
        }
    }

    private var filteredTimeline: [XRayEvent] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return xrayData.timeline }
        return xrayData.timeline.filter {
            $0.title.lowercased().contains(query) ||
            $0.chapterTitle.lowercased().contains(query) ||
            $0.summary.lowercased().contains(query) ||
            $0.significance.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search Input
            searchBar

            Divider()
                .opacity(0.2)

            // Category Filter Pills
            filterSegmentBar

            Divider()
                .opacity(0.15)

            // Main Content Area
            ScrollView {
                VStack(spacing: 16) {
                    // Header Banner
                    headerCard

                    // Characters Section
                    if selectedFilter == .all || selectedFilter == .characters {
                        if !filteredCharacters.isEmpty {
                            sectionHeader(
                                title: "主要人物谱系与角色档案",
                                icon: "person.2.fill",
                                count: filteredCharacters.count,
                                color: Color.primary.opacity(0.75)
                            )
                            LazyVStack(spacing: 10) {
                                ForEach(filteredCharacters) { char in
                                    characterCard(char)
                                }
                            }
                        }
                    }

                    // Concepts Section
                    if selectedFilter == .all || selectedFilter == .concepts {
                        if !filteredConcepts.isEmpty {
                            sectionHeader(
                                title: "核心哲学术语与概念表",
                                icon: "lightbulb.fill",
                                count: filteredConcepts.count,
                                color: .amberAccent
                            )
                            LazyVStack(spacing: 10) {
                                ForEach(filteredConcepts) { concept in
                                    conceptCard(concept)
                                }
                            }
                        }
                    }

                    // Timeline Section
                    if selectedFilter == .all || selectedFilter == .timeline {
                        if !filteredTimeline.isEmpty {
                            sectionHeader(
                                title: "叙事与历史背景脉络",
                                icon: "clock.arrow.circlepath",
                                count: filteredTimeline.count,
                                color: .blue
                            )
                            LazyVStack(spacing: 10) {
                                ForEach(filteredTimeline) { event in
                                    timelineEventCard(event)
                                }
                            }
                        }
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Search Bar
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("在 X-Ray 中检索人物或概念...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Filter Segment Bar
    private var filterSegmentBar: some View {
        HStack(spacing: 4) {
            ForEach(XRayFilterSegment.allCases) { filter in
                let isSelected = (selectedFilter == filter)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedFilter = filter
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: filter.icon)
                            .font(.system(size: 9.5))
                        Text(filter.rawValue)
                            .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isSelected ? Color.primary.opacity(0.09) : Color.clear)
                    )
                    .foregroundStyle(isSelected ? Color.primary.opacity(0.85) : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // MARK: - Header Card
    private var headerCard: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.primary.opacity(0.5), Color.primary.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                Image(systemName: "atom")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Kindle-Grade Book X-Ray")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.primary)
                    Text("AI 透视")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                }

                Text("透视登场人物背景、核心哲学概念与叙事历史脉络")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(10)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Section Header
    private func sectionHeader(title: String, icon: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)

            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))

            Spacer()

            Text("\(count)")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(color.opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    // MARK: - Character Card
    private func characterCard(_ char: XRayCharacter) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                // Initial Badge
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 26, height: 26)
                    Text(String(char.name.prefix(1)))
                        .font(.system(size: 12, weight: .bold, design: .serif))
                        .foregroundStyle(Color.primary.opacity(0.75))
                }

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 6) {
                        Text(char.name)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.primary)

                        Text(char.role)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    Text(char.identity)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            Text(char.description)
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(Color.primary.opacity(0.88))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            // Traits Pills
            if !char.keyTraits.isEmpty {
                HStack(spacing: 4) {
                    ForEach(char.keyTraits, id: \.self) { trait in
                        Text("#\(trait)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(Capsule())
                    }
                }
            }

            Divider()
                .opacity(0.1)

            // Action Buttons
            HStack(spacing: 12) {
                Button {
                    onJumpToChapter(char.chapterIndex)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle")
                        Text("初登场：\(char.firstAppearanceChapter)")
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.primary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("点击跳转到该人物首次登场章节")

                Spacer()

                Button {
                    let cleanedName = char.name.components(separatedBy: " ").first ?? char.name
                    onSearchTerm(cleanedName)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "magnifyingglass")
                        Text("全书查找")
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("在全书中检索该人物出现的各处上下文")
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Concept Card
    private func conceptCard(_ concept: XRayConcept) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(concept.term)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.primary)

                Text(concept.category)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(hex: "#D97706"))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color(hex: "#D97706").opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                Spacer()

                Button {
                    onAskAIAboutTerm(concept.term)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                        Text("问AI")
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("向 AI 伴读探讨此概念的深层含义")
            }

            Text(concept.shortDefinition)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.92))

            Text(concept.inDepthExplanation)
                .font(.system(size: 10.5, design: .serif))
                .foregroundStyle(.secondary)
                .lineSpacing(2)

            if let quote = concept.representativeQuotes.first {
                HStack(alignment: .top, spacing: 5) {
                    Text("“")
                        .font(.system(size: 14, weight: .bold, design: .serif))
                        .foregroundStyle(Color(hex: "#D97706"))
                    Text(quote)
                        .font(.system(size: 10, design: .serif))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .italic()
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "#D97706").opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Timeline Event Card
    private func timelineEventCard(_ event: XRayEvent) -> some View {
        HStack(alignment: .top, spacing: 9) {
            // Milestone Dot & Line
            VStack(spacing: 2) {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 7, height: 7)
                Rectangle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 1.5)
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.title)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Button {
                        onJumpToChapter(event.chapterIndex)
                    } label: {
                        Text(event.chapterTitle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("跳转到该章节")
                }

                Text(event.summary)
                    .font(.system(size: 10.5, design: .serif))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineSpacing(1.5)

                HStack(spacing: 4) {
                    Text("意义:")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(event.significance)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private extension Color {
    static let amberAccent = Color(hex: "#D97706")
}
