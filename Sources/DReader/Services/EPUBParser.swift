import Foundation

enum EPUBParserError: LocalizedError {
    case fileNotFound
    case notAZipArchive
    case unzipFailed(String)
    case containerXMLNotFound
    case opfPathNotFound
    case opfFileNotFound
    case manifestNotFound
    case spineNotFound

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "找不到指定的 EPUB 文件"
        case .notAZipArchive:
            return "这不是有效的 EPUB 文件（缺少 ZIP 包结构签名）。常见原因：① 文件被浏览器或下载工具拦成了空壳；② 实际是个 .mobi/.azw3 文件改了扩展名；③ DRM 加密版本书源导出的拷贝。建议用 Calibre 转换后再试。"
        case .unzipFailed(let msg):
            return "EPUB 解压失败: \(msg)"
        case .containerXMLNotFound:
            return "未找到 META-INF/container.xml，文件可能已损坏"
        case .opfPathNotFound:
            return "未能从 container.xml 中读取 content.opf 路径"
        case .opfFileNotFound:
            return "未找到 OPF 描述文件"
        case .manifestNotFound:
            return "未在 OPF 中找到 manifest 资源列表"
        case .spineNotFound:
            return "未在 OPF 中找到 spine 章节排布"
        }
    }
}

/// Native macOS EPUB parser extracting metadata, manifest, spine and table of contents
final class EPUBParser: Sendable {
    static let shared = EPUBParser()

    private struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String
        let properties: String?
    }

    private init() {}

    func parse(fileURL: URL) async throws -> EPUBBook {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw EPUBParserError.fileNotFound
        }

        // Bail out early with a clear diagnosis when the file lacks the ZIP signature
        if let header = try? FileHandle(forReadingFrom: fileURL).read(upToCount: 4),
           header.count >= 4,
           header.prefix(4) != Data([0x50, 0x4B, 0x03, 0x04]) {
            throw EPUBParserError.notAZipArchive
        }

        // Deterministic bookId based on file name so highlights and cache persist reliably across launches
        let fileKey = fileURL.lastPathComponent
        let hashVal = fileKey.utf8.reduce(into: UInt64(14695981039346656037)) { $0 = ($0 ^ UInt64($1)) &* 1099511628211 }
        let bookId = UUID(uuid: (
            UInt8(truncatingIfNeeded: hashVal), UInt8(truncatingIfNeeded: hashVal >> 8),
            UInt8(truncatingIfNeeded: hashVal >> 16), UInt8(truncatingIfNeeded: hashVal >> 24),
            UInt8(truncatingIfNeeded: hashVal >> 32), UInt8(truncatingIfNeeded: hashVal >> 40),
            UInt8(truncatingIfNeeded: hashVal >> 48), UInt8(truncatingIfNeeded: hashVal >> 56),
            0x44, 0x52, 0x65, 0x61, 0x64, 0x65, 0x72, 0x31
        ))

        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let destinationDir = cachesDir
            .appendingPathComponent("com.dreader.cache", isDirectory: true)
            .appendingPathComponent(bookId.uuidString, isDirectory: true)

        let isAlreadyExtracted = FileManager.default.fileExists(atPath: destinationDir.path)
        if !isAlreadyExtracted {
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            // 1. Unzip using macOS native ditto tool (handles Unicode, GBK, AppleDouble and special characters)
            try await unzip(archiveURL: fileURL, destinationURL: destinationDir)
        }

        // 2. Read container.xml (resilient search)
        var containerURL = destinationDir.appendingPathComponent("META-INF/container.xml")
        var epubRoot = destinationDir

        if !FileManager.default.fileExists(atPath: containerURL.path) {
            // Check for lowercase meta-inf or nested folder
            if let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: destinationDir.path) {
                for subpath in subpaths {
                    if subpath.lowercased().hasSuffix("container.xml") {
                        let candidate = destinationDir.appendingPathComponent(subpath)
                        containerURL = candidate
                        let parent = candidate.deletingLastPathComponent()
                        if parent.lastPathComponent.lowercased() == "meta-inf" {
                            epubRoot = parent.deletingLastPathComponent()
                        }
                        break
                    }
                }
            }
        }

        guard FileManager.default.fileExists(atPath: containerURL.path),
              let containerData = try? Data(contentsOf: containerURL),
              let containerNode = XMLTreeParser.parse(data: containerData) else {
            throw EPUBParserError.containerXMLNotFound
        }

        let rootfileNodes = containerNode.allDescendants(named: "rootfile")
        guard let rawOpfRelativePath = rootfileNodes.first?.attributes["full-path"], !rawOpfRelativePath.isEmpty else {
            throw EPUBParserError.opfPathNotFound
        }

        var cleanOpfPath = rawOpfRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        cleanOpfPath = cleanOpfPath.removingPercentEncoding ?? cleanOpfPath
        var opfURL = epubRoot.appendingPathComponent(cleanOpfPath)

        if !FileManager.default.fileExists(atPath: opfURL.path) {
            // Also try destinationDir root
            let directURL = destinationDir.appendingPathComponent(cleanOpfPath)
            if FileManager.default.fileExists(atPath: directURL.path) {
                opfURL = directURL
            } else {
                // Search for any .opf file in the unzipped directory
                if let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: destinationDir.path) {
                    for subpath in subpaths {
                        if subpath.lowercased().hasSuffix(".opf") {
                            opfURL = destinationDir.appendingPathComponent(subpath)
                            break
                        }
                    }
                }
            }
        }

        let opfDirectory = opfURL.deletingLastPathComponent()

        guard FileManager.default.fileExists(atPath: opfURL.path),
              let opfData = try? Data(contentsOf: opfURL),
              let opfNode = XMLTreeParser.parse(data: opfData) else {
            throw EPUBParserError.opfFileNotFound
        }

        // 3. Extract Metadata
        var title = fileURL.deletingPathExtension().lastPathComponent
        var author = "未知作者"
        var language = "zh"
        var bookDescription = ""
        var coverId: String?

        if let metadataNode = opfNode.descendant(named: "metadata") {
            if let t = metadataNode.descendant(named: "title")?.text, !t.isEmpty {
                title = t
            }
            if let a = metadataNode.descendant(named: "creator")?.text, !a.isEmpty {
                author = a
            }
            if let l = metadataNode.descendant(named: "language")?.text, !l.isEmpty {
                language = l
            }
            if let d = metadataNode.descendant(named: "description")?.text, !d.isEmpty {
                bookDescription = d
            }
            // Check for cover meta tag: <meta name="cover" content="id"/>
            for meta in metadataNode.allChildren(named: "meta") {
                if meta.attributes["name"] == "cover" {
                    coverId = meta.attributes["content"]
                }
            }
        }

        // 4. Extract Manifest Items
        var manifestMap: [String: ManifestItem] = [:]
        var ncxHref: String?
        var navHref: String?

        if let manifestNode = opfNode.descendant(named: "manifest") {
            for itemNode in manifestNode.allChildren(named: "item") {
                guard let id = itemNode.attributes["id"],
                      let href = itemNode.attributes["href"] else { continue }
                let mediaType = itemNode.attributes["media-type"] ?? ""
                let properties = itemNode.attributes["properties"]

                let item = ManifestItem(id: id, href: href, mediaType: mediaType, properties: properties)
                manifestMap[id] = item

                if properties?.contains("nav") == true {
                    navHref = href
                }
                if mediaType == "application/x-dtbncx+xml" || id == "ncx" || href.hasSuffix(".ncx") {
                    ncxHref = href
                }
            }
        }

        // Comprehensive Cover Detection (EPUB 3, EPUB 2, Calibre, filename match & disk scan)
        let coverURL: URL? = resolveCoverImageURL(
            coverId: coverId,
            manifestMap: manifestMap,
            opfDirectory: opfDirectory,
            destinationDir: destinationDir
        )

        // 5. Extract Spine (Reading Order)
        guard let spineNode = opfNode.descendant(named: "spine") else {
            throw EPUBParserError.spineNotFound
        }

        let itemrefNodes = spineNode.allChildren(named: "itemref")
        var chapters: [EPUBChapter] = []

        for (index, ref) in itemrefNodes.enumerated() {
            guard let idref = ref.attributes["idref"],
                  let manifestItem = manifestMap[idref] else { continue }

            let rawHref = manifestItem.href
            let cleanHref = rawHref.components(separatedBy: "#").first?.components(separatedBy: "?").first ?? rawHref
            let decodedHref = cleanHref.removingPercentEncoding ?? cleanHref

            var chapterURL = opfDirectory.appendingPathComponent(decodedHref)
            if !FileManager.default.fileExists(atPath: chapterURL.path) {
                chapterURL = opfDirectory.appendingPathComponent(cleanHref)
            }
            if !FileManager.default.fileExists(atPath: chapterURL.path) {
                let altURL = destinationDir.appendingPathComponent(decodedHref)
                if FileManager.default.fileExists(atPath: altURL.path) {
                    chapterURL = altURL
                }
            }
            guard FileManager.default.fileExists(atPath: chapterURL.path) else { continue }

            let chapter = EPUBChapter(
                id: idref,
                title: "第 \(index + 1) 章",
                fileURL: chapterURL,
                orderIndex: index
            )
            chapters.append(chapter)
        }

        // Fallback: If spine resulted in zero chapters, discover all HTML/XHTML files in manifest
        if chapters.isEmpty {
            let htmlItems = manifestMap.values.filter {
                $0.mediaType.contains("html") || $0.href.hasSuffix(".html") || $0.href.hasSuffix(".xhtml") || $0.href.hasSuffix(".htm")
            }.sorted { $0.href < $1.href }

            for (index, item) in htmlItems.enumerated() {
                let cleanHref = item.href.components(separatedBy: "#").first?.components(separatedBy: "?").first ?? item.href
                let decodedHref = cleanHref.removingPercentEncoding ?? cleanHref
                var chapterURL = opfDirectory.appendingPathComponent(decodedHref)
                if !FileManager.default.fileExists(atPath: chapterURL.path) {
                    chapterURL = opfDirectory.appendingPathComponent(cleanHref)
                }
                guard FileManager.default.fileExists(atPath: chapterURL.path) else { continue }

                chapters.append(EPUBChapter(
                    id: item.id,
                    title: "第 \(index + 1) 章",
                    fileURL: chapterURL,
                    orderIndex: index
                ))
            }
        }

        // 6. Extract Table of Contents (EPUB 3 nav or EPUB 2 ncx)
        var tocItems: [TOCItem] = []
        if let navPath = navHref {
            let cleanNav = (navPath.removingPercentEncoding ?? navPath).components(separatedBy: "#").first ?? navPath
            let navURL = opfDirectory.appendingPathComponent(cleanNav)
            if let navData = try? Data(contentsOf: navURL),
               let navNode = XMLTreeParser.parse(data: navData) {
                tocItems = parseNavTOC(node: navNode, baseURL: opfDirectory)
            }
        }

        if tocItems.isEmpty, let ncxPath = ncxHref {
            let cleanNcx = (ncxPath.removingPercentEncoding ?? ncxPath).components(separatedBy: "#").first ?? ncxPath
            let ncxURL = opfDirectory.appendingPathComponent(cleanNcx)
            if let ncxData = try? Data(contentsOf: ncxURL),
               let ncxNode = XMLTreeParser.parse(data: ncxData) {
                tocItems = parseNCXTOC(node: ncxNode, baseURL: opfDirectory)
            }
        }

        // Check if TOC is bogus (e.g. Project Gutenberg NCX containing only a single LICENSE entry)
        let isBogusTOC = (tocItems.count <= 2 && tocItems.contains(where: {
            let t = $0.title.uppercased()
            return t.contains("LICENSE") || t.contains("GUTENBERG") || t.contains("版权")
        }))
        if isBogusTOC {
            tocItems.removeAll()
        }

        // Fallback: If TOC is empty, build TOC from chapters
        if tocItems.isEmpty {
            tocItems = chapters.map { chap in
                TOCItem(
                    id: chap.id,
                    title: chap.title,
                    href: chap.fileURL.lastPathComponent,
                    targetURL: chap.fileURL
                )
            }
        }

        // Match TOC titles with chapters
        for i in 0..<chapters.count {
            let chapFile = chapters[i].fileURL.lastPathComponent
            if let matched = tocItems.first(where: {
                let tocFile = ($0.href.components(separatedBy: "#").first ?? $0.href)
                    .removingPercentEncoding ?? $0.href
                return URL(fileURLWithPath: tocFile).lastPathComponent == chapFile || $0.id == chapters[i].id
            }) {
                chapters[i].title = matched.title
            } else {
                // Try reading <title> or <h1> from chapter content
                if let data = try? Data(contentsOf: chapters[i].fileURL),
                   let htmlString = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                   let extractedTitle = extractTitleFromHTML(htmlString) {
                    chapters[i].title = extractedTitle
                }
            }
        }

        return EPUBBook(
            id: bookId,
            title: title,
            author: author,
            language: language,
            bookDescription: bookDescription,
            coverImageURL: coverURL,
            fileURL: fileURL,
            unzippedDirectory: destinationDir,
            opfDirectory: opfDirectory,
            chapters: chapters,
            toc: tocItems
        )
    }

    // MARK: - Unzip Helper
    private func unzip(archiveURL: URL, destinationURL: URL) async throws {
        // Primary: macOS native ditto tool (handles Unicode, GBK, UTF-8, and AppleDouble archives)
        let dittoProcess = Process()
        dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoProcess.arguments = ["-xk", archiveURL.path, destinationURL.path]

        let dittoErrorPipe = Pipe()
        dittoProcess.standardError = dittoErrorPipe

        do {
            try dittoProcess.run()
            dittoProcess.waitUntilExit()

            if dittoProcess.terminationStatus == 0 {
                return
            }
        } catch {
            // Fall through to unzip if ditto cannot execute
        }

        // Fallback: Info-ZIP unzip
        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipProcess.arguments = ["-q", "-o", archiveURL.path, "-d", destinationURL.path]

        let unzipPipe = Pipe()
        unzipProcess.standardError = unzipPipe

        try unzipProcess.run()
        unzipProcess.waitUntilExit()

        if unzipProcess.terminationStatus != 0 {
            let errorData = unzipPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "code \(unzipProcess.terminationStatus)"
            throw EPUBParserError.unzipFailed(errorMsg)
        }
    }

    // MARK: - EPUB 3 Navigation Parsing
    private func parseNavTOC(node: XMLNode, baseURL: URL) -> [TOCItem] {
        var results: [TOCItem] = []
        // Look for <nav epub:type="toc"> or <nav>
        let navNodes = node.allDescendants(named: "nav")
        guard let tocNav = navNodes.first(where: {
            $0.attributes["epub:type"] == "toc" || $0.attributes["type"] == "toc"
        }) ?? navNodes.first else {
            return []
        }

        let aNodes = tocNav.allDescendants(named: "a")
        for (idx, aNode) in aNodes.enumerated() {
            guard let href = aNode.attributes["href"], !href.isEmpty else { continue }
            let text = aNode.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = text.isEmpty ? "章节 \(idx + 1)" : text
            let targetURL = baseURL.appendingPathComponent(href)

            results.append(TOCItem(
                id: "nav-\(idx)",
                title: title,
                href: href,
                targetURL: targetURL
            ))
        }
        return results
    }

    // MARK: - EPUB 2 NCX Parsing
    private func parseNCXTOC(node: XMLNode, baseURL: URL) -> [TOCItem] {
        var results: [TOCItem] = []
        let navPoints = node.allDescendants(named: "navPoint")

        for (idx, point) in navPoints.enumerated() {
            let label = point.descendant(named: "text")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let src = point.descendant(named: "content")?.attributes["src"] ?? ""
            guard !src.isEmpty else { continue }

            let title = (label?.isEmpty ?? true) ? "章节 \(idx + 1)" : label!
            let targetURL = baseURL.appendingPathComponent(src)

            results.append(TOCItem(
                id: point.attributes["id"] ?? "ncx-\(idx)",
                title: title,
                href: src,
                targetURL: targetURL
            ))
        }
        return results
    }

    // MARK: - HTML Title Extractor
    private func extractTitleFromHTML(_ html: String) -> String? {
        // 1. First priority: Check for Chinese classic chapter headings (handles multiline OCR & Gutenberg headers)
        let chineseHeadingPattern = "<(?:p|h1|h2|h3)[^>]*>\\s*((?:第[0-9一二三四五六七八九十百千]+[回章节卷部集篇]|引子|楔子|序言|自序|卷首|前言|尾声|后记)[^<]{0,80})<\\/(?:p|h1|h2|h3)>"
        if let regex = try? NSRegularExpression(pattern: chineseHeadingPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let titleRange = Range(match.range(at: 1), in: html) {
            let raw = String(html[titleRange])
            var clean = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "[-—_~*]{3,}", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "　", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Collapse multiple spaces
            clean = clean.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)

            if !clean.isEmpty && clean.count < 65 {
                return clean
            }
        }

        // 2. Standard headings and title tag
        let patterns = [
            "<h1[^>]*>(.*?)<\\/h1>",
            "<h2[^>]*>(.*?)<\\/h2>",
            "<h3[^>]*>(.*?)<\\/h3>",
            "<title[^>]*>(.*?)<\\/title>"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let titleRange = Range(match.range(at: 1), in: html) {
                let raw = String(html[titleRange])
                // Strip inner tags
                let clean = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // Skip Gutenberg and generic boilerplate titles
                if clean.lowercased().contains("project gutenberg") || clean.lowercased().contains("ebook of") || clean.lowercased().contains("full project") {
                    continue
                }

                if !clean.isEmpty && clean.count < 60 {
                    return clean
                }
            }
        }
        return nil
    }

    // MARK: - Comprehensive Cover Resolver
    private func resolveCoverImageURL(
        coverId: String?,
        manifestMap: [String: ManifestItem],
        opfDirectory: URL,
        destinationDir: URL
    ) -> URL? {
        var candidateHrefs: [String] = []

        // 1. EPUB 3 cover-image property
        for item in manifestMap.values {
            if item.properties?.contains("cover-image") == true {
                candidateHrefs.append(item.href)
            }
        }

        // 2. EPUB 2 meta name="cover"
        if let cid = coverId, let item = manifestMap[cid] {
            candidateHrefs.append(item.href)
        }

        // 3. Manifest item with "cover" in id or href and mediaType is image
        for item in manifestMap.values {
            let isImg = item.mediaType.lowercased().starts(with: "image/")
            let hasCoverName = item.id.lowercased().contains("cover") || item.href.lowercased().contains("cover")
            if isImg && hasCoverName {
                candidateHrefs.append(item.href)
            }
        }

        // Check if any candidate is an actual image file on disk
        for href in candidateHrefs {
            if let resolved = findFileOnDisk(href: href, opfDirectory: opfDirectory, destinationDir: destinationDir) {
                let ext = resolved.pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "webp", "gif", "avif"].contains(ext) {
                    return resolved
                }
                // If it is an HTML cover page (like Calibre titlepage.xhtml), extract the image inside it
                if ["xhtml", "html", "htm", "xml"].contains(ext),
                   let content = try? String(contentsOf: resolved, encoding: .utf8) {
                    if let imgHref = extractImageFromHTML(content) {
                        let htmlDir = resolved.deletingLastPathComponent()
                        if let imgURL = findFileOnDisk(href: imgHref, opfDirectory: htmlDir, destinationDir: destinationDir) {
                            return imgURL
                        }
                    }
                }
            }
        }

        // 4. Disk scan: Look for files named cover.* or titlepage.*
        if let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: destinationDir.path) {
            for subpath in subpaths {
                let name = (subpath as NSString).lastPathComponent.lowercased()
                if (name.contains("cover") || name.contains("titlepage")) &&
                   ["jpg", "jpeg", "png", "webp"].contains((name as NSString).pathExtension.lowercased()) {
                    let fileURL = destinationDir.appendingPathComponent(subpath)
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        return fileURL
                    }
                }
            }
        }

        // 5. Fallback: First image in manifest
        for item in manifestMap.values {
            if item.mediaType.lowercased().starts(with: "image/") {
                if let resolved = findFileOnDisk(href: item.href, opfDirectory: opfDirectory, destinationDir: destinationDir) {
                    return resolved
                }
            }
        }

        return nil
    }

    private func findFileOnDisk(href: String, opfDirectory: URL, destinationDir: URL) -> URL? {
        let cleanHref = href.components(separatedBy: "#").first?.components(separatedBy: "?").first ?? href
        let decodedHref = cleanHref.removingPercentEncoding ?? cleanHref
        let candidates = [
            opfDirectory.appendingPathComponent(decodedHref),
            opfDirectory.appendingPathComponent(cleanHref),
            destinationDir.appendingPathComponent(decodedHref),
            destinationDir.appendingPathComponent(cleanHref)
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c.path) {
                return c
            }
        }
        return nil
    }

    private func extractImageFromHTML(_ html: String) -> String? {
        let patterns = [
            "(?i)<img[^>]+src=[\"']([^\"']+)[\"']",
            "(?i)<image[^>]+(?:xlink:href|href)=[\"']([^\"']+)[\"']"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let ns = html as NSString
                if let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: ns.length)),
                   match.numberOfRanges >= 2 {
                    return ns.substring(with: match.range(at: 1))
                }
            }
        }
        return nil
    }
}
