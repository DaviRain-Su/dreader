import Foundation

/// 超长章再切分：无目录的书/长文档常把全书挤成一章（实测 1MB+），
/// WKWebView 装载/主题注入/划线标定都会对巨型 DOM 跑，打开与滚动明显卡顿。
/// 超过上限的章按标签边界切成小段；完整文档先剥到 body inner。
enum ChapterSplitter {
    static let maxChapterBytes = 200_000
    static let targetChunkBytes = 120_000

    static func split(_ chapters: [BookChapterData]) -> [BookChapterData] {
        guard chapters.contains(where: { $0.utf8Fragment.count > maxChapterBytes }) else { return chapters }
        var result: [BookChapterData] = []
        result.reserveCapacity(chapters.count + 8)
        for chapter in chapters {
            guard chapter.utf8Fragment.count > maxChapterBytes else {
                result.append(chapter)
                continue
            }
            let bytes = Array(chapter.utf8Fragment)
            // 完整文档先剥到 body inner，切完的段都走 wrapFragment 路径。
            let inner: (start: Int, end: Int)
            if chapter.isWholeDocument {
                inner = MOBIParser.bodyInnerOf(bytes: bytes) ?? (0, bytes.count)
            } else {
                inner = (0, bytes.count)
            }
            var lower = inner.start
            var first = true
            while lower < inner.end {
                let goal = min(lower + targetChunkBytes, inner.end)
                let cut = goal >= inner.end ? inner.end : tagBoundaryNear(bytes: bytes, goal: goal)
                let count = cut - lower
                guard count > 0 else { lower = min(lower + targetChunkBytes, inner.end); continue }
                result.append(BookChapterData(
                    title: first ? chapter.title : nil,
                    utf8Fragment: Data(bytes[lower..<cut]),
                    isWholeDocument: false
                ))
                first = false
                lower = cut
            }
        }
        return result
    }

    /// 从 goal 向前（最多 40KB）找最近的标签边界 '>' 之后作为切点；找不到就在 goal 硬切。
    static func tagBoundaryNear(bytes: [UInt8], goal: Int, window: Int = 40_000) -> Int {
        let floorIndex = max(1, goal - window)
        var i = goal
        while i >= floorIndex {
            if bytes[i - 1] == UInt8(ascii: ">") {
                return i
            }
            i -= 1
        }
        return goal
    }
}
