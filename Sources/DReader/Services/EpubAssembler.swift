import Foundation

/// 把 MOBIParser 的结构化产物组装成标准 EPUB（EPUB2 + NCX + cover 标记双保险），
/// 交给现有 EPUBParser 走统一导入管线。
///
/// 输出目录布局（OEBPS 平铺，引用无路径歧义）：
/// - mimetype / META-INF/container.xml
/// - OEBPS/content.opf、OEBPS/toc.ncx
/// - OEBPS/cNNNNN.xhtml（各章正文）
/// - OEBPS/aNNNNN.ext（图片/CSS/字体资源，文件名沿用 libmobi 的 resource uid）
enum EpubAssembler {
    /// 并发导入竞态安全：每个导入一个独立 staging 目录。
    @discardableResult
    static func assemble(book: ParsedBook, outputURL: URL) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("DReaderMobiImport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let oebps = staging.appendingPathComponent("OEBPS", isDirectory: true)
        try fm.createDirectory(at: oebps, withIntermediateDirectories: false)
        try fm.createDirectory(at: staging.appendingPathComponent("META-INF", isDirectory: true),
                               withIntermediateDirectories: false)

        // mimetype 原样落盘（EPUB 要求首文件）。
        try Data("application/epub+zip".utf8).write(to: staging.appendingPathComponent("mimetype"))

        // 1. 资源拷贝：resource uid → aNNNNN.ext；CSS 记录到样式表集合供章引用。
        var cssFiles: [String] = []
        for resource in book.resources.values.sorted(by: { $0.uid < $1.uid }) {
            let fileName = "a\(String(format: "%05d", resource.uid)).\(resource.ext)"
            try resource.data.write(to: oebps.appendingPathComponent(fileName))
            if resource.mediaType == "text/css" {
                cssFiles.append(fileName)
            }
        }

        // 2. 各章 XHTML：资源引用重写 + 壳。
        for (index, chapter) in book.chapters.enumerated() {
            let name = "c\(String(format: "%04d", index + 1)).xhtml"
            let fragment = rewriteResourceReferences(chapter.utf8Fragment)
            let page: Data
            if chapter.isWholeDocument {
                page = Self.injectStylesAndResources(fragment, cssFiles: cssFiles)
            } else {
                page = Self.wrapFragment(fragment, cssFiles: cssFiles)
            }
            try page.write(to: oebps.appendingPathComponent(name))
        }

        // 3. container.xml。
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try Data(container.utf8).write(to: staging.appendingPathComponent("META-INF/container.xml"))

        // 4. content.opf。
        var manifestItems = "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
        if let coverUID = book.coverUID, book.resources[coverUID] != nil {
            let ext = book.resources[coverUID]!.ext
            manifestItems += "<item id=\"cover-image\" href=\"a\(String(format: "%05d", coverUID)).\(ext)\" media-type=\"\(book.resources[coverUID]!.mediaType)\" properties=\"cover-image\"/>"
        }
        manifestItems += cssFiles.map { "<item id=\"css-\($0)\" href=\"\($0)\" media-type=\"text/css\"/>" }.joined()
        let chapterFiles = (0..<book.chapters.count).map { "c\(String(format: "%04d", $0 + 1)).xhtml" }
        manifestItems += chapterFiles
            .map { "<item id=\"n-\($0)\" href=\"\($0)\" media-type=\"application/xhtml+xml\"/>" }
            .joined()

        let spine = chapterFiles.map { "<itemref idref=\"n-\($0)\"/>" }.joined()
        let escapedTitle = Self.escapeXML(book.title)
        let escapedAuthor = Self.escapeXML(book.author)
        let uuid = UUID().uuidString
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:\(uuid)</dc:identifier>
            <dc:title>\(escapedTitle)</dc:title>
            <dc:creator>\(escapedAuthor)</dc:creator>
            <dc:language>\(Self.escapeXML(book.language))</dc:language>
            <meta name="cover" content="cover-image"/>
          </metadata>
          <manifest>\(manifestItems)</manifest>
          <spine toc="ncx">\(spine)</spine>
        </package>
        """
        try Data(opf.utf8).write(to: oebps.appendingPathComponent("content.opf"))

        // 5. toc.ncx。
        var navPoints = ""
        for (index, chapter) in book.chapters.enumerated() {
            let title = chapter.title ?? "第 \(index + 1) 章"
            let playOrder = index + 1
            navPoints += """
            <navPoint id="np-\(playOrder)" playOrder="\(playOrder)">
              <navLabel><text>\(Self.escapeXML(title))</text></navLabel>
              <content src="c\(String(format: "%04d", playOrder)).xhtml"/>
            </navPoint>
            """
        }
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="urn:uuid:\(uuid)"/>
            <meta name="dtb:depth" content="1"/>
            <meta name="dtb:totalPageCount" content="0"/>
            <meta name="dtb:maxPageNumber" content="0"/>
          </head>
          <docTitle><text>\(escapedTitle)</text></docTitle>
          <navMap>\(navPoints)</navMap>
        </ncx>
        """
        try Data(ncx.utf8).write(to: oebps.appendingPathComponent("toc.ncx"))

        // 6. 打包 zip（ditto 打包 + nosource 保证不打 __MACOSX）。
        try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        try runProcess("/usr/bin/ditto", arguments: ["-c", "-k", "--norsrc", staging.path, outputURL.path])
        guard fm.fileExists(atPath: outputURL.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return outputURL
    }

    // MARK: 内容清洗

    /// 重写 libmobi 重建引用：
    /// `resourceNNNNN.ext`（图片/字体）/ `flowNNNNN.ext`（CSS 等）→ EPUB 内文件 `aNNNNN.ext`。
    private static func rewriteResourceReferences(_ fragment: Data) -> Data {
        guard let text = String(data: fragment, encoding: .utf8) else { return fragment }
        let pattern = #"(resource|flow)(\d{5})\.([A-Za-z0-9]{2,4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return fragment }
        let range = NSRange(location: 0, length: text.utf16.count)
        let rewritten = regex.stringByReplacingMatches(
            in: text, options: [], range: range,
            withTemplate: "a$2.$3"
        )
        return Data(rewritten.utf8)
    }

    /// KF7 片段包 XHTML 壳。
    private static func wrapFragment(_ fragment: Data, cssFiles: [String]) -> Data {
        guard let text = String(data: fragment, encoding: .utf8) else {
            return Data()
        }
        let head = "<head>" + cssFiles.map { "<link rel=\"stylesheet\" href=\"\($0)\" type=\"text/css\"/>" }.joined() + "</head>"
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">\(head)<body>\(text)</body></html>
        """.utf8)
    }

    /// KF8 完整文档注入 <link> 样式表（补齐 flow 的 css 引用）。
    private static func injectStylesAndResources(_ fragment: Data, cssFiles: [String]) -> Data {
        guard !cssFiles.isEmpty,
              let text = String(data: fragment, encoding: .utf8) else { return fragment }
        let links = cssFiles.map { "<link rel=\"stylesheet\" href=\"\($0)\" type=\"text/css\"/>" }.joined()
        if let headIndex = text.range(of: "</head>") {
            let prefix = String(text[..<headIndex.lowerBound])
            let suffix = String(text[headIndex.lowerBound...])
            return Data((prefix + links + suffix).utf8)
        }
        return Data((
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE html>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head>\(links)</head><body>\(text)</body></html>"
        ).utf8)
    }

    private static func escapeXML(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func runProcess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "EpubAssembler", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(executable) failed"])
        }
    }
}
