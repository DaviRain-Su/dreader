import AppKit
import Foundation

/// OPDS 目录客户端：浏览自建图书馆（BookOrbit / Calibre-Web / Kavita 等任何 OPDS 源）。
/// OPDS 是标准开放协议，无风控、无 Cookie 过期问题——专为阅读器拉书而生。
/// 实现：Atom XML 流式解析（XMLParser），支持 导航 feed / 获取 feed / 分页 / 目录内搜索
/// / HTTP Basic 认证 / 可选自签名证书信任。
final class OPDSService: @unchecked Sendable {
    static let shared = OPDSService()

    static let userAgent = "DReader/1.0 (+OPDS)"

    enum OPDSError: LocalizedError {
        case badURL
        case http(Int)
        case parse(String)
        case noEpubLink
        case mobiOnly
        case pdfOnly

        var errorDescription: String? {
            switch self {
            case .badURL: return "地址格式无效"
            case .http(let code): return Self.sourceHintForHTTP(code) ?? "OPDS 源返回 HTTP \(code)"
            case .parse(let detail): return "OPDS 目录解析失败：\(detail)"
            case .noEpubLink: return "该书没有 EPUB 版本，DReader 暂只接 EPUB"
            case .mobiOnly: return "这本书只有 MOBI（Kindle）版本——自建书馆（如 Calibre-Web）通常一键可转 EPUB，转好再拉回即可"
            case .pdfOnly: return "这本书只有 PDF 版本，而 DReader 目前只读 EPUB"
            }
        }

        /// 常见自建源 401 的诊断提示
        private static func sourceHintForHTTP(_ code: Int) -> String? {
            if code == 401 { return "OPDS 源要求认证（HTTP 401）：请检查用户名与密码" }
            if code == 403 { return "OPDS 源拒绝访问（HTTP 403）" }
            if code == 404 { return "OPDS 地址不存在（HTTP 404）：请确认目录 URL" }
            return nil
        }
    }

    // MARK: - 模型

    /// 已配置的 OPDS 源
    struct Source: Identifiable, Equatable, Codable, Sendable {
        var id: UUID
        var name: String
        var url: String
        var username: String
        var password: String
        var allowSelfSigned: Bool

        init(
            id: UUID = UUID(),
            name: String,
            url: String,
            username: String = "",
            password: String = "",
            allowSelfSigned: Bool = false
        ) {
            self.id = id
            self.name = name
            self.url = url
            self.username = username
            self.password = password
            self.allowSelfSigned = allowSelfSigned
        }
    }

    /// feed 里的一个条目：书（带获取链接）或子目录（带 subsection 链接）
    struct Entry: Identifiable, Equatable, Sendable {
        var id: String
        var title: String
        var author: String
        var summary: String
        var coverURL: String?
        var acquisitionLinks: [(type: String, href: String)]
        var subsectionHref: String?

        var isBook: Bool { !acquisitionLinks.isEmpty }

        /// 最合适的封面 URL（大图优先，退回缩略图）
        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
    }

    struct Feed: Sendable {
        var title: String
        var entries: [Entry]
        var nextPageURL: String?
        var searchURLTemplate: String?
        var isMixed: Bool { entries.contains { $0.isBook } && entries.contains { !$0.isBook } }
        var isAcquisition: Bool { entries.contains { $0.isBook } }
    }

    // MARK: - 源管理（UserDefaults 持久化）

    private static let sourcesKey = "dreader.opds.sources"

    static func loadSources() -> [Source] {
        guard let data = UserDefaults.standard.data(forKey: sourcesKey),
              let list = try? JSONDecoder().decode([Source].self, from: data)
        else { return [] }
        return list
    }

    static func saveSources(_ sources: [Source]) {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: sourcesKey)
        }
    }

    // MARK: - 网络

    /// 带自签名信任策略的 URLSession（按源配置放行特定主机）
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = TrustDelegate()
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    private var trustedHosts: Set<String> = []
    private let trustLock = NSLock()
    private let imageCache = NSCache<NSString, NSImage>()

    final class TrustDelegate: NSObject, URLSessionDataDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let host = challenge.protectionSpace.host
            let allowed = OPDSService.shared.trustLock.withLock { OPDSService.shared.trustedHosts.contains(host) }
            if allowed {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private func context(_ source: Source?) throws -> (request: URLRequest, authHeader: String?) {
        let base = source?.url ?? ""
        guard let url = URL(string: base), !base.isEmpty else { throw OPDSError.badURL }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/atom+xml,application/xml;q=0.9,text/xml;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        var auth: String? = nil
        if let src = source, !src.username.isEmpty {
            let raw = "\(src.username):\(src.password)"
            let token = Data(raw.utf8).base64EncodedString()
            auth = "Basic \(token)"
            request.setValue(auth!, forHTTPHeaderField: "Authorization")
        }
        // 自签名开关：登记主机，TrustDelegate 据此放行
        if let src = source, src.allowSelfSigned, let host = url.host {
            trustLock.withLock { _ = trustedHosts.insert(host) }
        }
        return (request, auth)
    }

    // MARK: - 拉取 feed

    func fetchFeed(href: String, source: Source?) async throws -> Feed {
        let base = try context(source)
        guard let url = absoluteURL(href) else { throw OPDSError.badURL }
        var request = base.request
        request.url = url
        if let auth = base.authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw OPDSError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw OPDSError.http(http.statusCode) }
        return try parseFeed(data, baseURL: url)
    }

    /// 目录内搜索：把 {searchTerms} 模板替换为编码后的关键词
    func search(template: String, terms: String, source: Source?) async throws -> Feed {
        let encoded = terms.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? terms
        let href = template.replacingOccurrences(of: "{searchTerms}", with: encoded)
        return try await fetchFeed(href: href, source: source)
    }

    /// 相对 href 依据 feed 所在 URL 解析为绝对地址（多数自建源日记里都是反着的）
    static func resolveHref(_ href: String, against base: URL) -> URL? {
        guard !href.isEmpty else { return nil }
        if let u = URL(string: href), u.scheme != nil { return u }
        return URL(string: href, relativeTo: base)
    }

    private func absoluteURL(_ href: String) -> URL? {
        URL(string: href)
    }

    // MARK: - XML 解析

    private func parseFeed(_ data: Data, baseURL: URL) throws -> Feed {
        let parser = FeedParser(data: data, baseURL: baseURL)
        let success = parser.parse()
        guard success, parser.errorDetail == nil else {
            throw OPDSError.parse(parser.errorDetail ?? "未知解析错误")
        }
        return parser.feed
    }

    /// XMLParser 委托：按元素累积 feed 级信息与 entry 列表（对命名空间前缀不敏感）
    private final class FeedParser: NSObject, @unchecked Sendable, XMLParserDelegate {
        private let parser: XMLParser
        private let baseURL: URL
        var feed = Feed(title: "", entries: [], nextPageURL: nil, searchURLTemplate: nil)
        var errorDetail: String? = nil

        private var entry: Entry? = nil
        private var textBuffer = ""
        private var textTarget: TextTarget? = nil
        private var depthInAuthorName = false

        enum TextTarget { case title, summary, feedTitle, idle }

        init(data: Data, baseURL: URL) {
            self.baseURL = baseURL
            self.parser = XMLParser(data: data)
            super.init()
            parser.delegate = self
        }

        func parse() -> Bool {
            let ok = parser.parse()
            if !ok {
                errorDetail = parser.parserError?.localizedDescription ?? "格式错误"
            }
            return ok
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            // localName：剥掉前缀（atom:entry / entry 都认）
            let name = elementName.components(separatedBy: ":").last ?? elementName
            let attrs = stripPrefixes(attributeDict)
            switch name {
            case "entry":
                entry = Entry(id: UUID().uuidString, title: "", author: "", summary: "", coverURL: nil, acquisitionLinks: [], subsectionHref: nil)
            case "author":
                depthInAuthorName = entry != nil
            case "name":
                if depthInAuthorName { textBuffer = ""; textTarget = .idle } // author name 走独立缓冲
                if entry != nil && depthInAuthorName { authorBuffer = "" }
            case "title":
                textBuffer = ""
                textTarget = entry != nil ? .title : .feedTitle
            case "summary", "content":
                if entry != nil { textBuffer = ""; textTarget = .summary }
            case "link":
                guard var e = entry else { break }
                let rel = attrs["rel"] ?? ""
                let type = attrs["type"] ?? ""
                let href = attrs["href"] ?? ""
                guard !href.isEmpty, let resolved = OPDSService.resolveHref(href, against: baseURL)?.absoluteString else { break }
                if rel.contains("acquisition") {
                    e.acquisitionLinks.append((type, resolved))
                } else if rel.contains("image") {
                    // image（大图）优先于 thumbnail；首个 image 直接存，thumbnail 仅在还没有时存
                    if rel.contains("thumbnail") {
                        if e.coverURL == nil { e.coverURL = resolved }
                    } else {
                        e.coverURL = resolved
                    }
                } else if rel.contains("subsection") || rel == "section" || rel == "catalog" {
                    if e.subsectionHref == nil { e.subsectionHref = resolved }
                } else if rel == "next" {
                    feed.nextPageURL = resolved
                } else if rel == "search" {
                    feed.searchURLTemplate = resolved
                }
                entry = e
            default:
                break
            }
        }

        private var authorBuffer = ""

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBuffer += string
            authorBuffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = elementName.components(separatedBy: ":").last ?? elementName
            switch name {
            case "name":
                if depthInAuthorName, var e = entry, !authorBuffer.isEmpty {
                    let trimmed = authorBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        e.author = e.author.isEmpty ? trimmed : e.author + ", " + trimmed
                    }
                    entry = e
                }
                authorBuffer = ""
                depthInAuthorName = false
            case "title":
                if textTarget == .feedTitle {
                    feed.title = normalize(textBuffer)
                } else if let e = entry, textTarget == .title {
                    var e2 = e
                    e2.title = normalize(textBuffer)
                    entry = e2
                }
                textTarget = .idle
                textBuffer = ""
            case "summary", "content":
                if let e = entry, textTarget == .summary, e.summary.isEmpty {
                    var e2 = e
                    e2.summary = normalize(textBuffer)
                    entry = e2
                }
                textTarget = .idle
                textBuffer = ""
            case "entry":
                if var e = entry {
                    if e.title.isEmpty { e.title = "未命名" }
                    // 去重防缓存条目重复
                    let key = "\(e.title)|\(e.subsectionHref ?? "")|\(e.acquisitionLinks.count)"
                    if !seenKeys.contains(key) {
                        seenKeys.insert(key)
                        feed.entries.append(e)
                    }
                    entry = nil
                }
            default:
                break
            }
        }

        private var seenKeys: Set<String> = []

        private func normalize(_ raw: String) -> String {
            raw
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }

        private func stripPrefixes(_ dict: [String: String]) -> [String: String] {
            var out: [String: String] = [:]
            for (k, v) in dict {
                out[k.components(separatedBy: ":").last ?? k] = v
            }
            return out
        }

        func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
            errorDetail = error.localizedDescription
        }
    }
}

// MARK: - 获取链接挑选 / 下载

extension OPDSService {

    /// 从条目挑 EPUB 获取链接（支持 .epub 副本）。兼容书源只给 application/octet-stream 的情况。
    func pickEPUBLink(_ entry: Entry) -> String? {
        let links = entry.acquisitionLinks
        let withExt = links.first { $0.href.lowercased().hasSuffix(".epub") }
        if let withExt { return withExt.href }
        let epubType = links.first {
            $0.type.contains("epub") || $0.type.contains("application/zip") || $0.type.contains("octet-stream")
        }
        return epubType?.href
    }

    /// 下载 EPUB（逐字节计数上报进度），落 DownloadedBooks。
    func downloadEPUB(
        entry: Entry,
        source: Source?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard let href = pickEPUBLink(entry) else { throw OPDSError.noEpubLink }
        let ctx = try context(source)
        var request = ctx.request
        request.url = absoluteURL(href)
        if let auth = ctx.authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let (asyncBytes, resp) = try await session.bytes(for: request)
        guard let http = resp as? HTTPURLResponse else { throw OPDSError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw OPDSError.http(http.statusCode) }
        let expected = http.expectedContentLength

        var data = Data()
        let bufferSize = 256 * 1024
        var sinceReport = 0
        for try await byte in asyncBytes {
            data.append(byte)
            sinceReport += 1
            if let onProgress = progress, sinceReport >= bufferSize {
                sinceReport = 0
                if expected > 0 {
                    onProgress(min(0.99, Double(data.count) / Double(expected)))
                } else {
                    onProgress(0.5) // 无 Content-Length 时给不确定进度
                }
            }
        }
        progress?(expected > 0 ? 0.99 : 1.0)

        guard data.count > 4, [UInt8](data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04] else {
            // 识别常见替代格式，给出能落地的提示而不是笼统的解析失败
            if data.count > 68, data.subdata(in: 60..<68) == Data("BOOKMOBI".utf8) {
                throw OPDSError.mobiOnly
            }
            if data.prefix(4) == Data("%PDF".utf8) {
                throw OPDSError.pdfOnly
            }
            throw OPDSError.parse("下载内容不是合法 EPUB（zip 头缺失）")
        }

        let fm = FileManager.default
        let downloadsDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DReader/DownloadedBooks", isDirectory: true)
        try fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        let safeName = entry.title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespaces)
        let destinationURL = downloadsDir.appendingPathComponent("\(safeName).epub")
        // 幂等：同名覆盖（与既有导入命名习惯一致）
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    // MARK: - 封面图

    /// 拉 OPDS 封面（可能需要 Basic 认证），带内存缓存，失败返回 nil 走占位图
    func fetchImage(href: String, source: Source?) async -> NSImage? {
        if let hit = imageCache.object(forKey: href as NSString) { return hit }
        guard let url = absoluteURL(href) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let source {
            guard let ctx = try? context(source) else { return nil }
            request = ctx.request
            request.url = url
            if let auth = ctx.authHeader {
                request.setValue(auth, forHTTPHeaderField: "Authorization")
            }
        }
        guard let (data, _) = try? await session.data(for: request), let image = NSImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: href as NSString)
        return image
    }
}
