import Foundation

/// 把微信读书抓下来的章节 XHTML + 图片组装成 EPUB 3.0，
/// 产出物直接走既有 EPUBParser 入架（竖排/主题/划线/生词本全继承 DReader 能力）。
enum WeReadEPUBAssembler {

    struct ChapterResult {
        var chapter: WeReadContentService.WeChapter
        var xhtml: String
        var images: [(name: String, data: Data, mime: String)]
        var srcMap: [String: String]
    }

    // MARK: - XML 辅助

    private static func xmlEscape(_ value: String) -> String {
        var v = String(value.unicodeScalars.filter { !($0.value < 32 && $0 != "\t" && $0 != "\n" && $0 != "\r") })
        v = v.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return v
    }

    /// 微信读书章节数据可能解码出多个串联 XHTML 文档；首个 <body> 常是标题壳，正文在后面的 body 里。
    /// 取全部 body 内容合并（与 KOReader body_fragment 一致）。
    static func bodyFragment(_ xhtml: String) -> String {
        var bodies: [String] = []
        var remaining = Substring(xhtml)
        while !remaining.isEmpty {
            guard let bodyStart = remaining.range(of: "<body") else { break }
            guard let gt = remaining[bodyStart.upperBound...].firstIndex(of: ">") else { break }
            let afterOpen = remaining[gt...].dropFirst()
            guard let bodyClose = afterOpen.range(of: "</body>") else {
                bodies.append(String(afterOpen))
                break
            }
            bodies.append(String(afterOpen[..<bodyClose.lowerBound]))
            remaining = afterOpen[bodyClose.upperBound...]
        }
        if !bodies.isEmpty { return bodies.joined(separator: "\n") }
        // 无 body：剥掉 xml 声明与 doctype 直接用
        var cleaned = xhtml
        if let range = cleaned.range(of: #"<\?xml.*?\?>"#, options: .regularExpression) {
            cleaned.removeSubrange(range)
        }
        if let range = cleaned.range(of: #"<!DOCTYPE.*?>"#, options: .regularExpression) {
            cleaned.removeSubrange(range)
        }
        return cleaned
    }

    /// 把章节 XHTML 内的图片 src 替换为 EPUB 内相对路径
    static func rewriteImageSources(_ xhtml: String, srcMap: [String: String]) -> String {
        guard !srcMap.isEmpty else { return xhtml }
        var result = xhtml
        for (raw, href) in srcMap.sorted(by: { $0.key.count > $1.key.count }) {
            // WeRead XHTML 中 src 常为文件名或带路径引用，统一按出现形式替换
            result = result
                .replacingOccurrences(of: "src=\"\(raw)\"", with: "src=\"\(href)\"")
                .replacingOccurrences(of: "src=\"\(raw)?\"", with: "src=\"\(href)?\"")
        }
        return result
    }

    // MARK: - 抓取整本书

    /// 逐章抓取（含每章 reader state 刷新 + 章间 sleep）。onProgress 上报 (已抓, 总数, 当前章名)。
    static func fetchWholeBook(
        bookId: String,
        chapters: [WeReadContentService.WeChapter],
        onProgress: @escaping @Sendable (Int, Int, String) -> Void
    ) async throws -> [ChapterResult] {
        let service = WeReadContentService.shared
        var results: [ChapterResult] = []
        var format: WeReadContentService.ChapterFormat? = nil
        for (idx, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            onProgress(idx, chapters.count, chapter.title)
            let xhtml = try await service.fetchChapterXHTML(bookId: bookId, chapter: chapter, format: &format)
            var images: [(name: String, data: Data, mime: String)] = []
            var srcMap: [String: String] = [:]
            if !chapter.tar.isEmpty {
                (images, srcMap) = (try? await service.fetchChapterImages(bookId: bookId, chapter: chapter)) ?? ([], [:])
            }
            results.append(ChapterResult(chapter: chapter, xhtml: xhtml, images: images, srcMap: srcMap))
            // 章间 1.2s 风控缓冲
            if idx < chapters.count - 1 {
                try await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
        return results
    }

    // MARK: - EPUB 打包

    /// 组装 EPUB 3 到目标路径（先写 .part 再原子改名）。
    /// 用系统 zip：mimetype 首个无压缩（-X -0），其余 deflate。
    static func packageEPUB(
        bookId: String,
        title: String,
        author: String,
        chapters: [ChapterResult],
        css: String?,
        outputURL: URL
    ) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("weread-epub-\(UUID().uuidString)", isDirectory: true)
        let oebps = staging.appendingPathComponent("OEBPS", isDirectory: true)
        let imagesDir = oebps.appendingPathComponent("images", isDirectory: true)
        let textDir = oebps.appendingPathComponent("text", isDirectory: true)
        try fm.createDirectory(at: textDir, withIntermediateDirectories: true)
        if chapters.contains(where: { !$0.images.isEmpty }) {
            try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        }

        // 章节文件（ch_0001.xhtml ...），图片文件名全书去重
        var usedImageNames = Set<String>()
        var manifestItems: [String] = []
        var spineItems: [String] = []
        var imageFiles: [(name: String, data: Data)] = []

        for (idx, ch) in chapters.enumerated() {
            let fileName = String(format: "ch_%04d.xhtml", idx + 1)
            let fragment = bodyFragment(ch.xhtml)
            let rewritten = rewriteImageSources(fragment, srcMap: ch.srcMap)
            let page = """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
            <head><title>\(xmlEscape(ch.chapter.title))</title></head>
            <body>
            \(rewritten)
            </body>
            </html>
            """
            try page.write(to: textDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
            manifestItems.append("<item id=\"ch\(idx + 1)\" href=\"text/\(fileName)\" media-type=\"application/xhtml+xml\"/>")
            spineItems.append("<itemref idref=\"ch\(idx + 1)\"/>")
            for img in ch.images {
                var name = img.name
                var counter = 2
                while usedImageNames.contains(name) {
                    name = (img.name as NSString).deletingPathExtension + "_\(counter)." + (img.name as NSString).pathExtension
                    counter += 1
                }
                usedImageNames.insert(name)
                try img.data.write(to: imagesDir.appendingPathComponent(name))
                manifestItems.append("<item id=\"img_ch\(idx + 1)_\(usedImageNames.count)\" href=\"images/\(name)\" media-type=\"\(img.mime)\"/>")
            }
        }

        // style.css
        let cssText = (css?.isEmpty == false) ? css! : "body { line-height: 1.7; margin: 5%; } img { max-width: 100%; }"
        try cssText.write(to: oebps.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        manifestItems.append("<item id=\"style\" href=\"style.css\" media-type=\"text/css\"/>")

        // nav.xhtml
        let navList = chapters.enumerated().map { (idx, ch) in
            "<li><a href=\"text/\(String(format: "ch_%04d.xhtml", idx + 1))\">\(xmlEscape(ch.chapter.title))</a></li>"
        }.joined(separator: "\n")
        let nav = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Navigation</title></head>
        <body>
        <nav epub:type="toc">
        <ol>
        \(navList)
        </ol>
        </nav>
        </body>
        </html>
        """
        try nav.write(to: oebps.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        manifestItems.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")

        // content.opf
        let utcModified = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            return fmt.string(from: Date())
        }()
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">weread-\(xmlEscape(bookId))</dc:identifier>
        <dc:title>\(xmlEscape(title))</dc:title>
        <dc:creator>\(xmlEscape(author))</dc:creator>
        <dc:publisher>WeRead</dc:publisher>
        <dc:language>zh-CN</dc:language>
        <meta property="dcterms:modified">\(utcModified)</meta>
        </metadata>
        <manifest>
        \(manifestItems.joined(separator: "\n"))
        </manifest>
        <spine>
        \(spineItems.joined(separator: "\n"))
        </spine>
        </package>
        """
        try opf.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        // container.xml / mimetype
        let metaInf = staging.appendingPathComponent("META-INF", isDirectory: true)
        try fm.createDirectory(at: metaInf, withIntermediateDirectories: true)
        let containerXML = """
        <?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        try containerXML.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        try "application/epub+zip".write(to: staging.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)

        // zip 打包：mimetype 必须是 zip 内第一个且不压缩
        let partURL = outputURL.appendingPathExtension("part")
        try? fm.removeItem(at: partURL)
        let mimetypeFirst = try Process.runAndCapture(launchPath: "/usr/bin/zip", arguments: ["-X", "-0", partURL.path, "mimetype"], cwd: staging.path)
        guard mimetypeFirst.terminationStatus == 0 else {
            throw NSError(domain: "WeReadEPUB", code: 1, userInfo: [NSLocalizedDescriptionKey: "zip mimetype 失败: \(mimetypeFirst.stderr)"])
        }
        // 其余文件 deflate 追加
        var addArgs = ["-X", "-9", "-r", partURL.path, "META-INF", "OEBPS"]
        let rest = try Process.runAndCapture(launchPath: "/usr/bin/zip", arguments: addArgs, cwd: staging.path)
        guard rest.terminationStatus == 0 else {
            throw NSError(domain: "WeReadEPUB", code: 2, userInfo: [NSLocalizedDescriptionKey: "zip 打包失败: \(rest.stderr)"])
        }
        _ = imageFiles
        addArgs = []

        // 原子提交
        try? fm.removeItem(at: outputURL)
        try fm.moveItem(at: partURL, to: outputURL)
        try? fm.removeItem(at: staging)
    }
}

/// Process 辅助（同步跑短命令）
extension Process {
    static func runAndCapture(launchPath: String, arguments: [String], cwd: String) throws -> (terminationStatus: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        try p.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: errData, encoding: .utf8) ?? "")
    }
}
