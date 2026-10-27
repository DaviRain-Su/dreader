import SwiftUI

/// Available font families for reading
enum ReaderFontFamily: String, CaseIterable, Identifiable, Codable {
    case original = "原书默认"
    case sans = "苹方 (黑体)"
    case songti = "宋体"
    case kaiti = "楷体"
    case fangsong = "仿宋"
    case serif = "经典衬线 (Charter)"
    case mono = "等宽代码"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return "原书默认 (原版排印)"
        case .sans: return "苹方 / 黑体 (PingFang SC)"
        case .songti: return "宋体 (Songti SC / 典雅宋)"
        case .kaiti: return "楷体 (Kaiti SC / 文人楷)"
        case .fangsong: return "仿宋 (STFangsong / 清雅仿宋)"
        case .serif: return "经典衬线 (Charter / New York)"
        case .mono: return "等宽代码 (SF Mono / Menlo)"
        }
    }

    var shortName: String {
        switch self {
        case .original: return "原书默认"
        case .sans: return "苹方"
        case .songti: return "宋体"
        case .kaiti: return "楷体"
        case .fangsong: return "仿宋"
        case .serif: return "衬线"
        case .mono: return "等宽"
        }
    }

    var cssFontFamily: String {
        switch self {
        case .original:
            return ""
        case .sans:
            return "-apple-system, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', 'Heiti SC', 'SF Pro Text', sans-serif"
        case .songti:
            return "'Songti SC', 'STSong', 'SimSong', 'Songti TC', 'SimSun', '宋体', 'New York', Georgia, serif"
        case .kaiti:
            return "'Kaiti SC', 'STKaiti', 'Kai', 'BiauKaiTC', 'KaiTi', '楷体', serif"
        case .fangsong:
            return "'STFangsong', 'FangSong', '仿宋', 'Songti SC', serif"
        case .serif:
            return "-apple-system-ui-serif, 'New York', 'Charter', Georgia, 'Palatino', 'Songti SC', serif"
        case .mono:
            return "'SF Mono', Menlo, Monaco, Consolas, monospace"
        }
    }

    var previewFont: Font {
        switch self {
        case .original: return .system(size: 12)
        case .sans: return .custom("PingFang SC", size: 12)
        case .songti: return .custom("Songti SC", size: 12)
        case .kaiti: return .custom("Kaiti SC", size: 12)
        case .fangsong: return .custom("STFangsong", size: 12)
        case .serif: return .system(size: 12, design: .serif)
        case .mono: return .system(size: 12, design: .monospaced)
        }
    }
}

/// Reading color themes
enum ReaderTheme: String, CaseIterable, Identifiable, Codable {
    case sepia = "典雅羊皮纸"
    case white = "纯净白昼"
    case gray = "极简亚麻灰"
    case green = "竹韵护眼"
    case dark = "暖夜深褐"
    case oled = "黑曜极夜"

    var id: String { rawValue }

    var backgroundColorHex: String {
        switch self {
        case .sepia: return "#F7F1E5"
        case .white: return "#FAF9F5"
        case .gray: return "#EAE8E3"
        case .green: return "#EBF1E8"
        case .dark: return "#1E1D1B"
        case .oled: return "#121213"
        }
    }

    var textColorHex: String {
        switch self {
        case .sepia: return "#2E241E"
        case .white: return "#1C1C1E"
        case .gray: return "#252423"
        case .green: return "#1E2E20"
        case .dark: return "#E5DFD5"
        case .oled: return "#EAEAEB"
        }
    }

    var secondaryTextColorHex: String {
        switch self {
        case .sepia: return "#7A6B5D"
        case .white: return "#6E6E73"
        case .gray: return "#68686D"
        case .green: return "#526A54"
        case .dark: return "#998F84"
        case .oled: return "#8E8E93"
        }
    }

    var accentColorHex: String {
        switch self {
        case .sepia: return "#8E5123"
        case .white: return "#0066CC"
        case .gray: return "#2563EB"
        case .green: return "#2D7A31"
        case .dark: return "#D4AF37"
        case .oled: return "#A78BFA"
        }
    }

    var selectionColorHex: String {
        switch self {
        case .sepia: return "rgba(224, 188, 128, 0.45)"
        case .white: return "rgba(180, 213, 254, 0.45)"
        case .gray: return "rgba(203, 213, 225, 0.5)"
        case .green: return "rgba(165, 214, 167, 0.45)"
        case .dark: return "rgba(120, 100, 75, 0.65)"
        case .oled: return "rgba(80, 70, 110, 0.75)"
        }
    }

    var isDark: Bool {
        self == .dark || self == .oled
    }

    var swiftUIBackground: Color {
        Color(hex: backgroundColorHex)
    }

    var swiftUIText: Color {
        Color(hex: textColorHex)
    }
}

/// Reading page layout style
enum ReaderPageLayout: String, CaseIterable, Identifiable, Codable {
    case single = "单页排版"
    case spread = "双页对开"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .single: return "doc.text"
        case .spread: return "book.pages"
        }
    }
}

/// Bilingual reading layout mode
enum BilingualDisplayMode: String, CaseIterable, Identifiable, Codable {
    case interlinear = "段落下对照"
    case sideBySide = "左右分栏对照"

    var id: String { rawValue }
}

/// User's reading preferences
@Observable
final class ReaderSettings: @unchecked Sendable {
    var theme: ReaderTheme = .sepia
    var fontFamily: ReaderFontFamily = .serif
    var fontSize: Double = 18.0 // 14 to 32
    var lineHeight: Double = 1.8 // 1.4 to 2.4
    var maxWidth: Double = 720.0 // 560 to 900
    var paragraphSpacing: Double = 1.0 // em
    var isJustified: Bool = true
    var pageLayout: ReaderPageLayout = .single
    var isZenMode: Bool = false

    // Bilingual Reading
    var isBilingualEnabled: Bool = false
    var bilingualMode: BilingualDisplayMode = .interlinear

    init() {}
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
