import Foundation

/// 将原 DOM 段落拆成适合本地合成的小块，id 始终保留原段落身份。
/// 播放序号由 ChapterReadAloudService 另行维护，不能拿块序号当定位 ID。
enum QwenTextChunker {
    static let defaultLimit = 140

    static func chunks(
        for segments: [ChapterReadAloudService.Segment],
        limit: Int = defaultLimit
    ) -> [(id: Int, text: String)] {
        let limit = max(40, limit)
        return segments.flatMap { segment in
            chunks(for: segment.text, limit: limit).map { (id: segment.id, text: $0) }
        }
    }

    static func chunks(for text: String, limit: Int = defaultLimit) -> [String] {
        let limit = max(40, limit)
        var result: [String] = []
        var units: [String] = []
        for sentence in lexicalUnits(in: text, terminators: "。！？!?；\n") {
            if sentence.count > limit {
                for clause in lexicalUnits(in: sentence, terminators: "，、：,:;") {
                    if clause.count > limit {
                        units.append(contentsOf: hardSplits(for: clause, limit: limit))
                    } else {
                        units.append(clause)
                    }
                }
            } else {
                units.append(sentence)
            }
        }
        pack(units, limit: limit, into: &result)
        return result.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func pack(_ units: [String], limit: Int, into result: inout [String]) {
        var pending = ""
        for unit in units {
            if !pending.isEmpty && pending.count + unit.count > limit {
                result.append(pending)
                pending = ""
            }
            if unit.count > limit {
                if !pending.isEmpty {
                    result.append(pending)
                    pending = ""
                }
                result.append(contentsOf: hardSplits(for: unit, limit: limit))
            } else {
                pending += unit
            }
        }
        if !pending.isEmpty { result.append(pending) }
    }

    private static func hardSplits(for text: String, limit: Int) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }

    private static func lexicalUnits(in text: String, terminators: String) -> [String] {
        let closing: Set<Character> = ["”", "’", "」", "』", "）", ")", "】", "]", "\"", "'"]
        var result: [String] = []
        var start = text.startIndex
        var index = start
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            guard terminators.contains(character) else {
                index = next
                continue
            }
            var end = next
            while end < text.endIndex, closing.contains(text[end]) {
                end = text.index(after: end)
            }
            result.append(String(text[start..<end]))
            start = end
            index = end
        }
        if start < text.endIndex { result.append(String(text[start..<text.endIndex])) }
        return result
    }
}
