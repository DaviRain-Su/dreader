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

/// Chinese script conversion mode (繁简一键转换)
enum ChineseScriptMode: String, CaseIterable, Identifiable, Codable {
    case original = "原版字形"
    case simplified = "转换为简体"
    case traditional = "转换为繁体"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .original: return "原"
        case .simplified: return "简"
        case .traditional: return "繁"
        }
    }
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

    // Chinese Script Conversion (繁体转简体)
    var chineseScriptMode: ChineseScriptMode = {
        if let raw = UserDefaults.standard.string(forKey: "dreader.chinese_script_mode"),
           let mode = ChineseScriptMode(rawValue: raw) {
            return mode
        }
        return .original
    }() {
        didSet {
            UserDefaults.standard.set(chineseScriptMode.rawValue, forKey: "dreader.chinese_script_mode")
        }
    }

    // Vertical Typesetting (中文古籍竖排 right-to-left)
    var isVertical: Bool = false

    // Line Guide (行引导线：跟随视线的淡线，防长行串行 —— Apple Books Line Guide)
    var isLineGuide: Bool = {
        UserDefaults.standard.bool(forKey: "dreader.line_guide_enabled") == true
    }() {
        didSet {
            UserDefaults.standard.set(isLineGuide, forKey: "dreader.line_guide_enabled")
        }
    }

    // 仿真翻页：翻页时旧页以整幅纸面平移滑出（快照合成，无闪烁）
    var isPageTurnAnimation: Bool = {
        UserDefaults.standard.object(forKey: "dreader.page_turn_animation") == nil
            ? true // 默认开：更接近纸书手感
            : UserDefaults.standard.bool(forKey: "dreader.page_turn_animation")
    }() {
        didSet {
            UserDefaults.standard.set(isPageTurnAnimation, forKey: "dreader.page_turn_animation")
        }
    }

    // 主题跟随系统外观：macOS 亮/暗模式切换时自动换昼/夜主题。
    // 手动点主题卡 = 关闭跟随并把该主题记入对应的昼（或夜）偏好。
    var followSystemAppearance: Bool = {
        UserDefaults.standard.bool(forKey: "dreader.follow_system_appearance")
    }() {
        didSet {
            UserDefaults.standard.set(followSystemAppearance, forKey: "dreader.follow_system_appearance")
            if followSystemAppearance { applySystemAppearance() }
        }
    }

    var lightTheme: ReaderTheme = {
        if let raw = UserDefaults.standard.string(forKey: "dreader.light_theme"),
           let t = ReaderTheme(rawValue: raw) { return t }
        return .sepia
    }() {
        didSet { UserDefaults.standard.set(lightTheme.rawValue, forKey: "dreader.light_theme") }
    }

    var darkTheme: ReaderTheme = {
        if let raw = UserDefaults.standard.string(forKey: "dreader.dark_theme"),
           let t = ReaderTheme(rawValue: raw) { return t }
        return .dark
    }() {
        didSet { UserDefaults.standard.set(darkTheme.rawValue, forKey: "dreader.dark_theme") }
    }

    /// 按当前系统外观把主题设为昼（或夜）偏好主题；跟随模式开启时与外观变化时调用
    func applySystemAppearance() {
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        theme = isDarkMode ? darkTheme : lightTheme
    }

    // MARK: - 听书引擎（Read-Aloud）

    /// 听书语音来源：Piper 本地神经网络（默认，离线）或 OpenAI 兼容 TTS API（在线大模型）
    enum ReadAloudEngine: String, Codable, CaseIterable, Identifiable {
        case piper = "Piper 本地语音（免费离线）"
        case ai = "AI 大模型语音（在线拟人）"
        var id: String { rawValue }
    }

    var readAloudEngine: ReadAloudEngine = {
        if let raw = UserDefaults.standard.string(forKey: "dreader.readaloud.engine"),
           let e = ReadAloudEngine(rawValue: raw) { return e }
        return .piper
    }() {
        didSet { UserDefaults.standard.set(readAloudEngine.rawValue, forKey: "dreader.readaloud.engine") }
    }

    /// OpenAI 兼容 /v1/audio/speech 端点（OpenAI、硅基流动等）
    var aiTTSEndpoint: String = {
        UserDefaults.standard.string(forKey: "dreader.readaloud.ai_endpoint")
            ?? "https://api.siliconflow.cn/v1"
    }() {
        didSet { UserDefaults.standard.set(aiTTSEndpoint, forKey: "dreader.readaloud.ai_endpoint") }
    }

    var aiTTSAPIKey: String = {
        UserDefaults.standard.string(forKey: "dreader.readaloud.ai_key") ?? ""
    }() {
        didSet { UserDefaults.standard.set(aiTTSAPIKey, forKey: "dreader.readaloud.ai_key") }
    }

    var aiTTSModel: String = {
        UserDefaults.standard.string(forKey: "dreader.readaloud.ai_model")
            ?? "FunAudioLLM/CosyVoice2-0.5B"
    }() {
        didSet { UserDefaults.standard.set(aiTTSModel, forKey: "dreader.readaloud.ai_model") }
    }

    /// 音色：OpenAI 为 alloy 等短名；硅基流动为 "模型名:音色" 全称
    var aiTTSVoice: String = {
        UserDefaults.standard.string(forKey: "dreader.readaloud.ai_voice")
            ?? "FunAudioLLM/CosyVoice2-0.5B:anna"
    }() {
        didSet { UserDefaults.standard.set(aiTTSVoice, forKey: "dreader.readaloud.ai_voice") }
    }
    /// 记住每本书的竖排偏好（bookId → "1"/"0"），切书时恢复
    private static let verticalPrefsKey = "dreader.vertical_by_book"

    init() {}

    // MARK: - Vertical Preference (per-book persistence)

    private static var verticalPrefs: [String: String] {
        get {
            UserDefaults.standard.string(forKey: verticalPrefsKey)?
                .data(using: .utf8)
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: verticalPrefsKey)
            }
        }
    }

    /// 读取某本书的竖排偏好（未设置时默认 false）
    func storedVertical(for bookId: UUID) -> Bool {
        Self.verticalPrefs[bookId.uuidString] == "1"
    }

    /// 应用某本书的竖排偏好（切书时调用）
    func applyStoredVertical(for bookId: UUID) {
        isVertical = storedVertical(for: bookId)
    }

    /// 切换竖排并记住（按书）
    func toggleVertical(for bookId: UUID?) {
        isVertical.toggle()
        if let bookId {
            var prefs = Self.verticalPrefs
            prefs[bookId.uuidString] = isVertical ? "1" : "0"
            Self.verticalPrefs = prefs
        }
    }

    /// 古籍自动竖排：书名或作者命中古典关键词时默认开竖排（仅首次打开该书时应用）
    static func looksLikeClassicalChinese(title: String, author: String = "") -> Bool {
        let combined = title + author
        let markers = [
            "紅樓夢", "红楼梦", "三國", "三国", "水滸", "水浒", "西遊", "西游",
            "道德經", "道德经", "論語", "论语", "孟子", "莊子", "庄子", "老子",
            "易經", "易经", "詩經", "诗经", "左傳", "左传", "史記", "史记",
            "資治通鑑", "资治通鉴", "唐詩", "唐诗", "宋詞", "宋词", "古文觀止", "古文观止",
            "聊齋", "聊斋", "儒林外史", "鏡花緣", "镜花缘", "封神", "金瓶梅",
            "演義", "演义", "志異", "志异", "傳", "禮記", "礼记", "尚書", "书经"
        ]
        return markers.contains { combined.contains($0) }
    }
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
