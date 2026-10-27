import SwiftUI

/// Apple Books & Kindle Style Physical Silk Bookmark Ribbon & Dog-Ear Fold
struct DogEarBookmarkRibbonView: View {
    let isBookmarked: Bool
    let onToggle: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onToggle) {
            ZStack(alignment: .top) {
                if isBookmarked {
                    // Crimson Silk Ribbon hanging from top of page
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(hex: "#C92A2A"),
                                        Color(hex: "#E03131"),
                                        Color(hex: "#B02525")
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 22, height: 42)

                        // Ribbon swallowtail notch cutout
                        RibbonTailShape()
                            .fill(Color(hex: "#B02525"))
                            .frame(width: 22, height: 10)
                    }
                    .shadow(color: Color.black.opacity(0.35), radius: 5, x: 0, y: 3)
                    .overlay(
                        // Silk gloss reflection
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.35), Color.clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 4, height: 42),
                        alignment: .leading
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    // Subtle translucent ghost bookmark fold for easy clicking
                    RibbonGhostShape()
                        .fill(isHovered ? Color.red.opacity(0.55) : Color.primary.opacity(0.12))
                        .frame(width: 20, height: 26)
                        .overlay(
                            Image(systemName: "bookmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isHovered ? .white : Color.primary.opacity(0.45))
                                .offset(y: 2)
                        )
                        .shadow(color: .black.opacity(isHovered ? 0.15 : 0.0), radius: 3, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isBookmarked ? "移除书签 (⌘+D)" : "在此处添加折角书签 (⌘+D)")
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isBookmarked)
    }
}

/// Downward pointed swallowtail notch shape for physical silk bookmark ribbon
struct RibbonTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + (rect.height * 0.35)))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Ghost shape for unbookmarked state
struct RibbonGhostShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 6))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 6))
        path.closeSubpath()
        return path
    }
}
