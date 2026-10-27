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

    /// Tag-safe conversion for HTML content (preserves all tags, attributes, scripts, styles)
    static func convertHTML(_ html: String, mode: ChineseScriptMode) -> String {
        guard mode != .original, !html.isEmpty else { return html }

        var result = ""
        result.reserveCapacity(html.count)
        let scanner = Scanner(string: html)
        scanner.charactersToBeSkipped = nil

        var inSkipBlock = false
        var skipEndTag = ""

        while !scanner.isAtEnd {
            if inSkipBlock {
                if let content = scanner.scanUpToString(skipEndTag) {
                    result.append(content)
                    if let endTag = scanner.scanString(skipEndTag) {
                        result.append(endTag)
                        inSkipBlock = false
                        skipEndTag = ""
                    }
                } else {
                    result.append(contentsOf: scanner.string[scanner.currentIndex...])
                    break
                }
            } else {
                if let text = scanner.scanUpToString("<") {
                    result.append(convert(text, mode: mode))
                }
                if let tag = scanner.scanUpToString(">") {
                    result.append(tag)
                    if scanner.scanString(">") != nil {
                        result.append(">")
                    }
                    let lowerTag = tag.lowercased()
                    if lowerTag.starts(with: "<script") {
                        inSkipBlock = true
                        skipEndTag = "</script>"
                    } else if lowerTag.starts(with: "<style") {
                        inSkipBlock = true
                        skipEndTag = "</style>"
                    }
                }
            }
        }
        return result
    }
}
