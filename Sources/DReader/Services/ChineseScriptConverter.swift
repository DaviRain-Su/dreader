import Foundation

/// Native Chinese Script Converter (繁体/简体一键无损转换引擎)
/// Leverages macOS native CoreFoundation ICU String Transformation (`Traditional-Simplified` / `Simplified-Traditional`)
/// Zero third-party dependencies, instantaneous C-level execution, safe for HTML entities and tags.
enum ChineseScriptConverter {
    /// Converts Traditional Chinese text or HTML to Simplified Chinese (繁体转简体)
    static func toSimplified(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
        return mutable as String
    }

    /// Converts Simplified Chinese text or HTML to Traditional Chinese (简体转繁体)
    static func toTraditional(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, "Simplified-Traditional" as CFString, false)
        return mutable as String
    }

    /// Applies conversion based on the user's selected mode
    static func convert(_ text: String, mode: ChineseScriptMode) -> String {
        switch mode {
        case .original:
            return text
        case .simplified:
            return toSimplified(text)
        case .traditional:
            return toTraditional(text)
        }
    }
}
