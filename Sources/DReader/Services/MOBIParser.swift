import Foundation
import Cmobi

// MARK: - MOBI 数据模型

/// 一个从书内数据接出来的二进制资源；uid 与 libmobi 重建引用 `resource%05u` / `flow%05u` 对齐。
struct MOBIResource {
    let uid: Int
    /// 不带点，如 jpg/png/css/otf。
    let ext: String
    let mediaType: String
    let data: Data
    let isImage: Bool
}

/// 一个章的正文片段。KF8 为完整文档字节流；KF7 为重建 HTML 的 `<body>` 内部片段。
struct MOBIChapterData {
    let title: String?
    let utf8Fragment: Data
    /// true：片段是完整文档（含 <html> 外壳），组装层不再包壳。
    let isWholeDocument: Bool
}

struct MOBIParsedBook {
    let title: String
    let author: String
    let language: String
    let chapters: [MOBIChapterData]
    /// key 为 resource uid。
    let resources: [Int: MOBIResource]
    /// 封面资源 uid（可能为 nil：无图 MOBI）。
    let coverUID: Int?
    /// 正文流的 CSS 资源 uid（EPUB 内会连进每章 <head>）。
    let cssUIDs: [Int]
}

enum MOBIParseError: LocalizedError {
    case fileNotFound
    case drmProtected
    case loadFailed(String)
    case rawmlFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "找不到指定的 MOBI 文件"
        case .drmProtected:
            return "这本书带 Kindle DRM 加密保护。DReader 只能导入未加密的 MOBI/AZW3（Kindle 商店购买的加密副本不受支持）。"
        case .loadFailed(let message):
            return "MOBI 文件解析失败：\(message)"
        case .rawmlFailed(let message):
            return "MOBI 正文重建失败：\(message)"
        }
    }
}

/// libmobi C 桥：MOBI/AZW3 → 结构化数据（元数据、章片段、资源）。
/// 章切分策略对齐 libmobi opf.c 的语义：
/// - KF7：NCX filepos 直接对应重建 HTML 的字节偏移（书内自带 `<a id="NNNNNNNNNN">` 锚）；
/// - KF8：NCX posfid 落在 skel 段内，part 序号即 markup part 序号；
/// - 无 NCX 退回 `<mbp:pagebreak/>` 切分；再无则单章。
enum MOBIParser {
    static func parse(fileURL: URL) throws -> MOBIParsedBook {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MOBIParseError.fileNotFound
        }
        let m = mobi_init()!
        defer { mobi_free(m) }
        let status = fileURL.path.withCString { path in
            mobi_load_filename(m, path)
        }
        guard status == MOBI_SUCCESS else {
            if let rh = m.pointee.rh, rh.pointee.encryption_type != 0 {
                throw MOBIParseError.drmProtected
            }
            throw MOBIParseError.loadFailed("libmobi status=\(status.rawValue)")
        }
        // DRM 在 load 成功后也可能存在（PDB 头加密位）；显式再查一次。
        if let rh = m.pointee.rh, rh.pointee.encryption_type != 0 {
            throw MOBIParseError.drmProtected
        }

        let rawml = mobi_init_rawml(m)!
        defer { mobi_free_rawml(rawml) }
        guard mobi_parse_rawml(rawml, m) == MOBI_SUCCESS else {
            throw MOBIParseError.rawmlFailed("mobi_parse_rawml 失败")
        }

        let title = readTitle(m: m) ?? fileURL.deletingPathExtension().lastPathComponent
        let author = readEXTH(m: m, tag: MOBIExthTag(rawValue: 100)) ?? "未知作者"
        let language = readEXTH(m: m, tag: MOBIExthTag(rawValue: 524)) ?? nil

        var resources: [Int: MOBIResource] = [:]
        var cssUIDs: [Int] = []
        var coverUID: Int?
        var firstImageSeen = false
        var cursor = rawml.pointee.resources
        while let part = cursor {
            defer { cursor = part.pointee.next }
            guard let resource = makeResource(from: part) else { continue }
            resources[resource.uid] = resource
            if resource.mediaType == "text/css" {
                cssUIDs.append(resource.uid)
            } else if resource.isImage && !firstImageSeen {
                coverUID = resource.uid
            }
            if resource.isImage { firstImageSeen = true }
        }

        let chapters = buildChapters(rawml: rawml, fallbackTitle: title)
        guard !chapters.isEmpty else {
            throw MOBIParseError.rawmlFailed("未找到正文内容")
        }
        return MOBIParsedBook(title: title, author: author, language: language ?? "zh",
                              chapters: chapters, resources: resources, coverUID: coverUID, cssUIDs: cssUIDs)
    }

    // MARK: 元数据

    private static func readTitle(m: UnsafeMutablePointer<MOBIData>) -> String? {
        if let t = readEXTH(m: m, tag: MOBIExthTag(rawValue: 99)) { return t } // EXTH_TITLE
        var fullname = [CChar](repeating: 0, count: 2048)
        mobi_get_fullname(m, &fullname, 2048)
        let name = String(cString: fullname).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func readEXTH(m: UnsafeMutablePointer<MOBIData>, tag: MOBIExthTag) -> String? {
        guard let header = mobi_get_exthrecord_by_tag(m, tag), let raw = header.pointee.data else { return nil }
        let count = Int(header.pointee.size)
        guard count > 0 else { return nil }
        let text = String(decoding: UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: count), as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: 资源

    private static func makeResource(from part: UnsafeMutablePointer<MOBIPart>) -> MOBIResource? {
        guard let meta = fileMeta(part.pointee.type) else { return nil }
        let size = Int(part.pointee.size)
        guard size > 0, let data = part.pointee.data else { return nil }
        // OPF/NCX 由 EPUB 组装层自行生成。
        switch meta.ext {
        case "opf", "ncx":
            return nil
        default:
            break
        }
        return MOBIResource(uid: Int(part.pointee.uid), ext: meta.ext, mediaType: meta.mime,
                            data: Data(bytes: data, count: size),
                            isImage: ["jpg", "jpeg", "png", "gif", "bmp", "svg"].contains(meta.ext))
    }

    /// mobi_get_filemeta_by_type 的 Swift 收束。
    private static func fileMeta(_ type: MOBIFiletype) -> (ext: String, mime: String)? {
        let ext: String
        let mime: String
        switch type {
        case T_HTML: ext = "html"; mime = "text/html"
        case T_CSS: ext = "css"; mime = "text/css"
        case T_SVG: ext = "svg"; mime = "image/svg+xml"
        case T_OPF: ext = "opf"; mime = "application/oebps-package+xml"
        case T_NCX: ext = "ncx"; mime = "application/x-dtbncx+xml"
        case T_JPG: ext = "jpg"; mime = "image/jpeg"
        case T_GIF: ext = "gif"; mime = "image/gif"
        case T_PNG: ext = "png"; mime = "image/png"
        case T_BMP: ext = "bmp"; mime = "image/bmp"
        case T_OTF: ext = "otf"; mime = "font/otf"
        case T_TTF: ext = "ttf"; mime = "font/ttf"
        case T_MP3: ext = "mp3"; mime = "audio/mpeg"
        case T_MPG: ext = "mpg"; mime = "video/mpeg"
        case T_PDF: ext = "pdf"; mime = "application/pdf"
        case T_FONT: return nil // 编码字体保留原始形态可能导致渲染异常，先不落盘
        default: return nil
        }
        return (ext, mime)
    }

    // MARK: 章节切分

    private static func buildChapters(rawml: UnsafeMutablePointer<MOBIRawml>, fallbackTitle: String) -> [MOBIChapterData] {
        let toc = readNCX(rawml: rawml)
        if mobi_is_rawml_kf8(rawml) {
            return kf8Chapters(rawml: rawml, toc: toc)
        }
        return kf7Chapters(rawml: rawml, toc: toc, fallbackTitle: fallbackTitle)
    }

    private struct NcxEntry {
        let title: String?
        let filepos: Int?       // KF7：重建 HTML 内字节偏移
        let posfid: Int         // KF8：frag 数组序号
        let posoff: Int         // KF8：part 内字节偏移
    }

    private static func readNCX(rawml: UnsafeMutablePointer<MOBIRawml>) -> [NcxEntry] {
        guard let ncx = rawml.pointee.ncx else { return [] }
        let count = Int(ncx.pointee.entries_count)
        guard count > 0 else { return [] }
        var result: [NcxEntry] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let entry = ncx.pointee.entries[i]
            var title: String?
            var filepos: Int?
            var posfid = -1
            var posoff = -1
            if let tags = entry.tags {
                for t in 0..<Int(entry.tags_count) {
                    let tag = tags[t]
                    guard let values = tag.tagvalues else { continue }
                    switch tag.tagid {
                    case 1:
                        filepos = Int(values[0])
                    case 3:
                        if title == nil, let cncx = ncx.pointee.cncx_record {
                            title = cncxString(from: cncx, offset: Int(values[0]))
                        }
                    case 6:
                        if Int(tag.tagvalues_count) > 0 { posfid = Int(values[0]) }
                        if Int(tag.tagvalues_count) > 1 { posoff = Int(values[1]) }
                    default:
                        break
                    }
                }
            }
            result.append(NcxEntry(title: title, filepos: filepos, posfid: posfid, posoff: posoff))
        }
        return result
    }

    /// CNCX 编译字符串：varlen 前缀 + UTF-8 内容（对齐 libmobi mobi_get_cncx_string_utf8）。
    private static func cncxString(from record: UnsafeMutablePointer<MOBIPdbRecord>, offset: Int) -> String? {
        let size = Int(record.pointee.size)
        guard size > 0, let data = record.pointee.data, offset >= 0, offset < size else { return nil }
        let bytes = data
        var pos = offset
        var length: UInt32 = 0
        while pos < size {
            let b = bytes[pos]
            pos += 1
            length = (length << 7) | UInt32(b & 0x7F)
            if b & 0x80 == 0 { break }
        }
        guard pos + Int(length) <= size else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes + pos, count: Int(length)), as: UTF8.self)
    }

    // MARK: KF8

    /// KF8 章切分，对齐 mobi_get_offset_by_posoff：
    /// pos_fid 是 frag 数组序号；offset_in_part = frag.label(十进制) − skel[fileNr].position + pos_off；
    /// part 即 markup 第 file_nr 个 T_HTML part。
    private static func kf8Chapters(rawml: UnsafeMutablePointer<MOBIRawml>, toc: [NcxEntry]) -> [MOBIChapterData] {
        var parts: [(uid: Int, base: UnsafePointer<UInt8>, size: Int)] = []
        var cursor = rawml.pointee.markup
        while let part = cursor {
            defer { cursor = part.pointee.next }
            if part.pointee.type == T_HTML, Int(part.pointee.size) > 0, let data = part.pointee.data {
                parts.append((Int(part.pointee.uid), UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self), Int(part.pointee.size)))
            }
        }
        guard !parts.isEmpty else { return [] }
        let uidToIndex: [Int: Int] = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($1.uid, $0) })

        let fragEntries = fragRecordEntries(rawml: rawml)
        let skelPositions = skelEntryPositions(rawml: rawml)

        // NCX 条目 → (part 序号, part 内字节偏移, 标题)。
        var chapterPoints: [(partIndex: Int, offset: Int, title: String?)] = []
        for entry in toc where entry.posfid >= 0 {
            guard entry.posfid < fragEntries.count else { continue }
            let frag = fragEntries[entry.posfid]
            guard frag.fileNr < skelPositions.count, frag.fileNr < parts.count else { continue }
            let base = frag.rawStart - skelPositions[frag.fileNr] + max(0, entry.posoff)
            guard let partIndex = uidToIndex[frag.fileNr], base > 0, base < parts[partIndex].size else { continue }
            chapterPoints.append((partIndex, base, entry.title))
        }

        var chapters: [MOBIChapterData] = []
        for (index, part) in parts.enumerated() {
            let points = chapterPoints
                .filter { $0.partIndex == index && $0.offset > 0 && $0.offset < part.size }
                .sorted { $0.offset < $1.offset }
            if points.isEmpty {
                chapters.append(MOBIChapterData(title: nil, utf8Fragment: Data(UnsafeBufferPointer(start: part.base, count: part.size)), isWholeDocument: true))
                continue
            }
            var lower = 0
            for point in points where point.offset > lower {
                if let fragment = midBytesFrom(base: part.base, size: part.size, from: lower, to: point.offset) {
                    chapters.append(MOBIChapterData(title: point.title, utf8Fragment: fragment, isWholeDocument: true))
                }
                lower = point.offset
            }
            if let tail = midBytesFrom(base: part.base, size: part.size, from: lower, to: part.size) {
                chapters.append(MOBIChapterData(title: nil, utf8Fragment: tail, isWholeDocument: true))
            }
        }
        return chapters
    }

    private struct FragEntry {
        let fileNr: Int
        let rawStart: Int
    }

    /// frag entries：file_nr（tag3）、raw 起点（label 十进制字符串，对齐 strtoul）。
    private static func fragRecordEntries(rawml: UnsafeMutablePointer<MOBIRawml>) -> [FragEntry] {
        guard let frag = rawml.pointee.frag else { return [] }
        let count = Int(frag.pointee.entries_count)
        var result: [FragEntry] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let entry = frag.pointee.entries[i]
            let rawStart = entry.label.flatMap { strtoul($0, nil, 10) } ?? 0
            var fileNr = -1
            if let tags = entry.tags {
                for t in 0..<Int(entry.tags_count) {
                    let tag = tags[t]
                    if tag.tagid == 3, let values = tag.tagvalues, Int(tag.tagvalues_count) > 0 {
                        fileNr = Int(values[0])
                    }
                }
            }
            result.append(FragEntry(fileNr: fileNr, rawStart: Int(rawStart)))
        }
        return result
    }

    private static func skelEntryPositions(rawml: UnsafeMutablePointer<MOBIRawml>) -> [Int] {
        guard let skel = rawml.pointee.skel else { return [] }
        let count = Int(skel.pointee.entries_count)
        var positions: [Int] = []
        positions.reserveCapacity(count)
        for i in 0..<count {
            let entry = skel.pointee.entries[i]
            var position = -1
            if let tags = entry.tags {
                for t in 0..<Int(entry.tags_count) {
                    let tag = tags[t]
                    if tag.tagid == 6, let values = tag.tagvalues, Int(tag.tagvalues_count) > 0 {
                        position = Int(values[0])
                    }
                }
            }
            positions.append(position)
        }
        return positions
    }

    // MARK: KF7

    /// KF7：单 part HTML；优先 NCX filepos 切，退回 pagebreak，单章兜底。
    private static func kf7Chapters(rawml: UnsafeMutablePointer<MOBIRawml>, toc: [NcxEntry], fallbackTitle: String) -> [MOBIChapterData] {
        guard let firstPart = rawml.pointee.markup, firstPart.pointee.type == T_HTML,
              let data = firstPart.pointee.data, Int(firstPart.pointee.size) > 0 else {
            return []
        }
        let size = Int(firstPart.pointee.size)
        let base = UnsafePointer(data)

        let inner = bodyInnerRange(base: base, size: size) ?? (start: 0, end: size)

        let fileposs = toc.compactMap { $0.filepos }.filter { $0 > inner.start && $0 < inner.end }.sorted()
        if !fileposs.isEmpty {
            let titlesByPos: [Int: String?] = {
                var dict: [Int: String?] = [:]
                for entry in toc where entry.filepos != nil && entry.filepos! > inner.start && entry.filepos! < inner.end {
                    if dict[entry.filepos!] == nil { dict[entry.filepos!] = entry.title }
                }
                return dict
            }()
            var segments: [MOBIChapterData] = []
            var lower = inner.start
            for cut in fileposs where cut > lower && cut < inner.end {
                if let fragment = midBytesFrom(base: base, size: size, from: lower, to: cut) {
                    let title: String? = titlesByPos[cut] ?? nil
                    segments.append(MOBIChapterData(title: title, utf8Fragment: fragment, isWholeDocument: false))
                }
                lower = cut
            }
            if let tail = midBytesFrom(base: base, size: size, from: lower, to: inner.end) {
                segments.append(MOBIChapterData(title: nil, utf8Fragment: tail, isWholeDocument: false))
            }
            if segments.count >= 2 {
                return segments
            }
        }

        // pagebreak fallback：`<mbp:pagebreak .../>` 切分。
        if let bodyText = textOf(base: base, size: size, from: inner.start, to: inner.end),
           bodyText.contains("<mbp:pagebreak") {
            let pieces: [String] = bodyText
                .components(separatedBy: "<mbp:pagebreak")
                .map { piece in
                    if let range = piece.range(of: "/>") {
                        String(piece[range.upperBound...])
                    } else if piece.count > 1,
                              let range = piece.range(of: ">", options: [], range: piece.startIndex..<piece.index(piece.startIndex, offsetBy: min(24, piece.count - 1))) {
                        String(piece[range.upperBound...])
                    } else {
                        piece
                    }
                }
                .filter { !$0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty }
            if pieces.count >= 2 {
                return pieces.map { MOBIChapterData(title: nil, utf8Fragment: Data($0.utf8), isWholeDocument: false) }
            }
        }

        // 单章兜底。
        guard let whole = midBytesFrom(base: base, size: size, from: inner.start, to: inner.end) else { return [] }
        return [MOBIChapterData(title: fallbackTitle, utf8Fragment: whole, isWholeDocument: false)]
    }

    // MARK: 字节工具

    /// 定位 `<body ...>` 开标签闭合 '>' 之后到 `</body>` 之前的字节范围（ASCII 精确定位，byte != String.index）。
    private static func bodyInnerRange(base: UnsafePointer<UInt8>, size: Int) -> (start: Int, end: Int)? {
        let p = Array("<body".utf8)
        func scan(_ needle: [UInt8], from start: Int) -> Int? {
            guard start <= size - needle.count else { return nil }
            var i = start
            outer: while i <= size - needle.count {
                for (offset, b) in needle.enumerated() where base[i + offset] != b {
                    i += 1
                    continue outer
                }
                return i
            }
            return nil
        }
        guard let bodyTag = scan(p, from: 0) else { return nil }
        var gt = bodyTag
        while gt < size, base[gt] != UInt8(ascii: ">") { gt += 1 }
        guard gt < size else { return nil }
        let start = gt + 1
        let end = scan(Array("</body>".utf8), from: start) ?? size
        guard start < end else { return nil }
        return (start, end)
    }

    private static func midBytesFrom(base: UnsafePointer<UInt8>, size: Int, from start: Int, to end: Int) -> Data? {
        guard start >= 0, end <= size, start < end else { return nil }
        let count = end - start
        let slice = UnsafeBufferPointer(start: base + start, count: count)
        var data = Data(slice)
        data.trimPartialUTF8Tail()
        return data
    }

    private static func textOf(base: UnsafePointer<UInt8>, size: Int, from start: Int, to end: Int) -> String? {
        guard let data = midBytesFrom(base: base, size: size, from: start, to: end) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension Data {
    /// 切点可能落在 UTF-8 字符中间——修整尾部不完整序列（最多回退 3 字节）。
    mutating func trimPartialUTF8Tail() {
        guard count > 3 else { return }
        for cut in 1...3 {
            if String(data: prefix(count - cut), encoding: .utf8) != nil {
                self = Data(prefix(count - cut))
                return
            }
        }
    }
}
