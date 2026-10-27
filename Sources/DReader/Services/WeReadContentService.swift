import Foundation
import CryptoKit

/// 微信读书 Web 正文接入（非官方接口，个人互操作用途）。
///
/// 协议参考 KOReader weread.koplugin 的开源实现（MIT）：
/// 1. 携带浏览器 cookie（wr_vid / wr_skey）打开章节 reader 页，提取 `window.__INITIAL_STATE__` 中的 psvts 会话令牌
/// 2. `chapterInfos` 拿目录（含每章 tar 资源包地址）
/// 3. 章节正文分三片（e_0/e_1/e_3），每片以 32 位大写 MD5 前缀校验，拼接后剥首字符、
///    逆字符交换、base64-url 解码还原 XHTML；CSS 走 e_2 单片
/// 4. 请求参数需 `e()` 编码 + `s` 签名（0x15051505 双向移位异或哈希）
/// 5. 图片在章节 tar 包内，逐 entry 提取
final class WeReadContentService: @unchecked Sendable {
    static let shared = WeReadContentService()

    private let baseURL = "https://weread.qq.com"
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
    private let cookieKey = "dreader.weread.web_cookie"
    private let sessionLock = NSLock()
    private nonisolated(unsafe) var lastRequestTime: Date = .distantPast
    /// 分片请求最小间隔（秒），规避风控；章节间另有显式 sleep
    private let minRequestInterval: TimeInterval = 0.4

    // MARK: - Errors

    enum WeReadContentError: LocalizedError {
        case missingCookie
        case loginExpired
        case readerStateNotFound
        case emptyShard(String)
        case md5Mismatch
        case noChapters
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingCookie:
                return "尚未配置微信读书网页版 Cookie，请在登录 weread.qq.com 后从浏览器复制"
            case .loginExpired:
                return "微信读书登录已过期（-2012），请重新复制浏览器 Cookie"
            case .readerStateNotFound:
                return "无法从阅读器页面提取会话状态（psvts），Cookie 可能无效"
            case .emptyShard(let ep):
                return "\(ep) 返回空对象：无该章权限或签名参数错误"
            case .md5Mismatch:
                return "章节分片 MD5 校验失败"
            case .noChapters:
                return "该书目录为空或暂无权限阅读任何章节"
            case .httpError(let code, let body):
                return "HTTP \(code)：\(body.prefix(120))"
            }
        }
    }

    // MARK: - Cookie

    var cookie: String {
        get { UserDefaults.standard.string(forKey: cookieKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: cookieKey)
        }
    }
    var hasCookie: Bool { !cookie.isEmpty }

    // MARK: - HTTP

    private func request(path: String, method: String = "GET", jsonBody: [String: Any]? = nil, referer: String? = nil) async throws -> (Data, Int) {
        guard let url = URL(string: baseURL + path) else { throw WeReadContentError.missingCookie }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://weread.qq.com/", forHTTPHeaderField: "Origin")
        req.setValue(referer ?? "https://weread.qq.com/", forHTTPHeaderField: "Referer")
        let ck = cookie
        guard !ck.isEmpty else { throw WeReadContentError.missingCookie }
        req.setValue(ck, forHTTPHeaderField: "Cookie")
        if let body = jsonBody {
            req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // 简易节流
        let wait: TimeInterval = sessionLock.withLock {
            let w = lastRequestTime.addingTimeInterval(minRequestInterval).timeIntervalSinceNow
            lastRequestTime = Date().addingTimeInterval(max(0, w))
            return w
        }
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (data, code)
    }

    private func requestText(path: String, method: String = "GET", jsonBody: [String: Any]? = nil, referer: String? = nil) async throws -> String {
        let (data, code) = try await request(path: path, method: method, jsonBody: jsonBody, referer: referer)
        guard (200..<300).contains(code) else {
            throw WeReadContentError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func requestJSON(path: String, jsonBody: [String: Any], referer: String? = nil) async throws -> [String: Any] {
        let text = try await requestText(path: path, method: "POST", jsonBody: jsonBody, referer: referer)
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw WeReadContentError.md5Mismatch
        }
        // -2012 登录超时
        if let errCode = obj["errCode"] as? Int, errCode == -2012 {
            throw WeReadContentError.loginExpired
        }
        return obj
    }

    // MARK: - 协议核心：e() 编码与 s 签名

    /// WeRead.e() —— MD5 混淆编码（数字与字符串两种分支）
    private func e(_ value: String) -> String {
        let h = md5Hex(value)
        var result = String(h.prefix(3))
        var chunks: [String] = []
        let typeFlag: String
        if !value.isEmpty && value.allSatisfy(\.isNumber) {
            typeFlag = "3"
            var i = value.startIndex
            while i < value.endIndex {
                let end = value.index(i, offsetBy: 9, limitedBy: value.endIndex) ?? value.endIndex
                let part = String(value[i..<end])
                chunks.append(String(format: "%x", UInt64(part) ?? 0))
                i = end
            }
        } else {
            typeFlag = "4"
            chunks.append(value.utf8.map { String(format: "%x", $0) }.joined())
        }
        result += typeFlag + "2" + String(h.suffix(2))
        for (idx, chunk) in chunks.enumerated() {
            result += String(format: "%02x", chunk.count) + chunk
            if idx < chunks.count - 1 { result += "g" }
        }
        if result.count < 20 {
            result += String(h.prefix(20 - result.count))
        }
        result += String(md5Hex(result).prefix(3))
        return result
    }

    /// WeRead.sign() —— 0x15051505 移位异或哈希（query 从尾部两字节向前）
    private func sign(_ query: String) -> String {
        var a: UInt32 = 0x1505_1505
        var b: UInt32 = 0x1505_1505
        let bytes = Array(query.utf8)
        let length = bytes.count
        var i = length
        while i > 1 {
            let ai = UInt32(bytes[i - 1]) << UInt32((length - i + 1) % 30)
            a = (a ^ ai) & 0x7fff_ffff
            let bi = UInt32(bytes[i - 2]) << UInt32((i - 1) % 30)
            b = (b ^ bi) & 0x7fff_ffff
            i -= 2
        }
        return String(format: "%x", a &+ b)
    }

    private func jsString(_ value: Any) -> String {
        switch value {
        case let flag as Bool: return flag ? "true" : "false"
        default: return "\(value)"
        }
    }

    /// JS 风格 query 拼接（字典序、无 s、RFC3986 百分号编码）
    private func sortedQuery(_ params: [String: Any]) -> String {
        params.keys.filter { $0 != "s" }.sorted().map { key in
            let raw = jsString(params[key]!)
            let encoded = raw.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~").inverted) ?? raw
            return key + "=" + encoded
        }.joined(separator: "&")
    }

    private func makeContentParams(bookId: String, chapterUid: Int, psvts: String, style: Bool = false) -> [String: Any] {
        var ct = Int(Date().timeIntervalSince1970)
        if e(String(ct)) == psvts { ct += 1 }
        var params: [String: Any] = [
            "b": e(bookId),
            "c": e(String(chapterUid)),
            "r": "\(Int.random(in: 0...9999) * Int.random(in: 0...9999))",
            "ct": "\(ct)",
            "ps": psvts,
            "pc": e(String(ct)),
            "sc": 1,
            "prevChapter": false,
            "st": style ? 1 : 0,
        ]
        params["s"] = sign(sortedQuery(params))
        return params
    }

    private func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Reader State

    struct ReaderState {
        var psvts: String = ""
        var bookId: String = ""
        var title: String = ""
        var author: String = ""
    }

    /// 打开章节 reader 页提取会话令牌。每章下载前都要刷新（与 Web 端行为一致）。
    private func fetchReaderState(bookId: String, chapterUid: Int?) async throws -> ReaderState {
        var path = "/web/reader/\(e(bookId))"
        if let uid = chapterUid { path += "k\(e(String(uid)))" }
        let html = try await requestText(path: path)
        var state = ReaderState()
        // __INITIAL_STATE__ 内嵌 JSON 的 reader.psvts（宽松正则提取，双保险字符串直配）
        if let regex = try? NSRegularExpression(pattern: #""psvts"\s*:\s*"([^"]+)""#) {
            let ns = html as NSString
            if let m = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) {
                state.psvts = ns.substring(with: m.range(at: 1))
            }
        }
        if state.psvts.isEmpty {
            if let regex = try? NSRegularExpression(pattern: #""psvts":"([^"]+)""#) {
                let ns = html as NSString
                if let m = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) {
                    state.psvts = ns.substring(with: m.range(at: 1))
                }
            }
        }
        if let m = html.range(of: #""bookId"\s*:\s*"([^"]+)""#, options: .regularExpression) {
            state.bookId = String(html[m].dropFirst()).components(separatedBy: "\"").last ?? ""
        }
        if state.psvts.isEmpty { throw WeReadContentError.readerStateNotFound }
        return state
    }

    // MARK: - 目录

    struct WeChapter {
        var chapterUid: Int
        var title: String
        var wordCount: Int
        var tar: String
    }

    func fetchCatalog(bookId: String) async throws -> [WeChapter] {
        let readerURL = "\(baseURL)/web/reader/\(e(bookId))"
        let payload = try await requestJSON(path: "/web/book/chapterInfos", jsonBody: ["bookIds": [bookId]], referer: readerURL)
        guard let data = payload["data"] as? [String: Any],
              let updated = (data["updated"] as? [[String: Any]] ?? (data["books"] as? [[String: Any]])) else {
            // 某些响应直接在顶层给 updated
            if let top = payload["updated"] as? [[String: Any]] {
                return parseChapters(top)
            }
            throw WeReadContentError.noChapters
        }
        return parseChapters(updated)
    }

    private func parseChapters(_ updated: [[String: Any]]) -> [WeChapter] {
        updated.compactMap { ch in
            guard let uid = (ch["chapterUid"] as? Int) ?? (ch["chapterUid"] as? String).flatMap({ Int($0) }) else { return nil }
            let wc = (ch["wordCount"] as? Int) ?? (ch["wordCount"] as? Double).map { Int($0) } ?? 0
            guard wc > 0 else { return nil }
            let title = (ch["title"] as? String) ?? ""
            guard title != "封面" else { return nil }
            let tar = (ch["tar"] as? String) ?? ""
            return WeChapter(chapterUid: uid, title: title, wordCount: wc, tar: tar)
        }
    }

    // MARK: - 分片解码

    /// 剥 32 位大写 MD5 前缀并校验
    private func checkedBody(_ text: String) throws -> Substring {
        guard text.count > 32 else { return "" }
        let prefix = text.prefix(32)
        let body = text.dropFirst(32)
        let actual = Insecure.MD5.hash(data: Data(body.utf8)).map { String(format: "%02X", $0) }.joined()
        guard actual == prefix else { throw WeReadContentError.md5Mismatch }
        return body[...]
    }

    /// 由末尾 n 个字节的二进制位导出交换位置表（与 swap_positions 等价）
    private func swapPositions(_ encoded: [UInt8]) -> [Int] {
        let length = encoded.count
        if length < 4 { return [] }
        if length < 11 { return [0, 2] }
        let n = min(4, (length + 9) / 10)
        var tmp = ""
        for idx in (length - n..<length).reversed() {
            var byte = encoded[idx]
            var bin = ""
            repeat {
                bin = String(byte % 2) + bin
                byte /= 2
            } while byte != 0
            // Lua tonumber(bin, 4)：按 4 进制解释二进制串
            var value = 0
            for ch in bin {
                value = value * 4 + (ch == "1" ? 1 : 0)
            }
            tmp += String(value)
        }
        var result: [Int] = []
        let m = length - n - 2
        let step = String(m).count
        var i = 0
        let chars = Array(tmp)
        // Lua 原式 i + step - 1 < #tmp（严格小于，1-based）：0-based 即 i + step < count，
        // 首值窗口永远不触及 tmp 的最后一个字符
        while result.count < 10 && i + step < chars.count {
            let v1 = Int(String(chars[i..<min(i + step, chars.count)])) ?? 0
            result.append(v1 % m)
            // Lua 第二块 sub(i+1, min(i+step, #tmp))，1-based → 0-based 排他终点 min(i+1+step, count)
            let end2 = min(i + step + 1, chars.count)
            if i + 1 < chars.count {
                let v2 = Int(String(chars[(i + 1)..<end2])) ?? 0
                result.append(v2 % m)
            }
            i += step
        }
        return result
    }

    /// 逆字符交换（成对交换，从尾部位置对向前）。Lua 的 positions[i]+k+1 为 1-based，转 0-based 即 +k
    private func reverseSwaps(_ encoded: [UInt8], positions: [Int]) -> [UInt8] {
        var chars = encoded
        guard positions.count >= 2 else { return chars }
        var idx = positions.count - 1
        while idx >= 1 {
            for k in stride(from: 1, through: 0, by: -1) {
                let left = positions[idx] + k
                let right = positions[idx - 1] + k
                guard left >= 0, left < chars.count, right >= 0, right < chars.count else { continue }
                chars.swapAt(left, right)
            }
            idx -= 2
        }
        return chars
    }

    private func base64URLDecode(_ s: String) -> Data {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = str.count % 4
        if pad > 0 { str += String(repeating: "=", count: 4 - pad) }
        return Data(base64Encoded: str) ?? Data()
    }

    /// 单片解码：剥首字符 → 逆交换 → base64-url
    private func decodeEncodedBody(_ body: Substring) -> Data {
        let encoded = Array(body.dropFirst().utf8)
        let restored = reverseSwaps(encoded, positions: swapPositions(encoded))
        return base64URLDecode(String(decoding: restored, as: UTF8.self))
    }

    private func decodeShards(_ parts: [String]) throws -> String {
        var concat = ""
        for p in parts { concat += try checkedBody(p) }
        let data = decodeEncodedBody(Substring(concat))
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 章节抓取

    enum ChapterFormat { case epub, txt }

    func fetchChapterXHTML(bookId: String, chapter: WeChapter, format: inout ChapterFormat?) async throws -> String {
        // 每章先刷新 reader state（携带该章 uid，与 Web 端翻章行为一致）
        let state = try await fetchReaderState(bookId: bookId, chapterUid: chapter.chapterUid)

        let chapterURL = "\(baseURL)/web/reader/\(e(bookId))k\(e(String(chapter.chapterUid)))"
        let e0 = try await requestText(path: "/web/book/chapter/e_0",
                                       jsonBody: makeContentParams(bookId: bookId, chapterUid: chapter.chapterUid, psvts: state.psvts),
                                       referer: chapterURL)
        // TXT 格式探测：e_0 返回 JSON 且含 bookId
        if e0.hasPrefix("{") && e0.contains("\"bookId\"") {
            format = .txt
            let t0 = try await requestText(path: "/web/book/chapter/t_0",
                                           jsonBody: makeContentParams(bookId: bookId, chapterUid: chapter.chapterUid, psvts: state.psvts),
                                           referer: chapterURL)
            let t1 = (try? await requestText(path: "/web/book/chapter/t_1",
                                             jsonBody: makeContentParams(bookId: bookId, chapterUid: chapter.chapterUid, psvts: state.psvts),
                                             referer: chapterURL)) ?? ""
            let plain = try decodeShards([t0, t1])
            return txtToXHTML(plain)
        }
        format = .epub
        let e1 = try await requestText(path: "/web/book/chapter/e_1",
                                       jsonBody: makeContentParams(bookId: bookId, chapterUid: chapter.chapterUid, psvts: state.psvts),
                                       referer: chapterURL)
        let e3 = try await requestText(path: "/web/book/chapter/e_3",
                                       jsonBody: makeContentParams(bookId: bookId, chapterUid: chapter.chapterUid, psvts: state.psvts),
                                       referer: chapterURL)
        return try decodeShards([e0, e1, e3])
    }

    private func txtToXHTML(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let paragraphs = escaped.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "<p>\($0)</p>" }
            .joined(separator: "\n")
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title></title></head>\n<body>\n\(paragraphs)\n</body></html>"
    }

    // MARK: - 图片 tar 包

    /// 从章节 tar 包提取图片，返回 [资源文件名 → 数据] 与 [原文件名 → EPUB 相对路径] 映射
    func fetchChapterImages(bookId: String, chapter: WeChapter) async throws -> (images: [(name: String, data: Data, mime: String)], srcMap: [String: String]) {
        guard !chapter.tar.isEmpty else { return ([], [:]) }
        var tarURL = chapter.tar
        if tarURL.hasPrefix("//") { tarURL = "https:" + tarURL }
        else if tarURL.hasPrefix("/") { tarURL = baseURL + tarURL }
        guard let url = URL(string: tarURL) else { return ([], [:]) }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://weread.qq.com/", forHTTPHeaderField: "Referer")
        let ck = cookie
        guard !ck.isEmpty else { throw WeReadContentError.missingCookie }
        req.setValue(ck, forHTTPHeaderField: "Cookie")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            return ([], [:])
        }
        return parseTarImages(data)
    }

    /// 512 字节块 TAR 解析（只提取图片）
    private func parseTarImages(_ data: Data) -> (images: [(name: String, data: Data, mime: String)], srcMap: [String: String]) {
        var images: [(String, Data, String)] = []
        var srcMap: [String: String] = [:]
        var usedNames = Set<String>()
        var offset = 0
        let bytes = [UInt8](data)
        while offset + 512 <= bytes.count {
            let header = Array(bytes[offset..<(offset + 512)])
            guard let nameEnd = header.firstIndex(of: 0), nameEnd > 0 else { break }
            let name = String(decoding: header[0..<nameEnd], as: UTF8.self)
            // 全零块 = 结束
            if name.isEmpty { break }
            func octal(_ range: ClosedRange<Int>) -> Int {
                var value = 0
                for b in header[range] where b != 0 {
                    let byte = Int(b)
                    if byte >= 48 && byte <= 55 { value = value * 8 + (byte - 48) }
                }
                return value
            }
            let size = octal(124...135)
            let bodyStart = offset + 512
            let bodyEnd = bodyStart + size
            if bodyEnd <= bytes.count, size > 0 {
                let entryData = Data(bytes[bodyStart..<bodyEnd])
                if let mime = Self.imageMime(for: entryData), let ext = Self.imageExt(for: mime) {
                    let stem = (name as NSString).lastPathComponent
                    var filename = stem
                    var counter = 2
                    while usedNames.contains(filename) {
                        filename = "\(stem)_\(counter)"
                        counter += 1
                    }
                    usedNames.insert(filename)
                    let href = "images/\(filename)"
                    images.append((filename, entryData, mime))
                    srcMap[stem] = "../" + href
                    srcMap[filename] = "../" + href
                    _ = ext
                }
            }
            offset = bodyStart + Int(ceil(Double(size) / 512.0)) * 512
        }
        return (images, srcMap)
    }

    static func imageMime(for data: Data) -> String? {
        guard data.count > 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if b.starts(with: [0x42, 0x4D]) { return "image/bmp" }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if let s = String(data: data.prefix(300), encoding: .utf8), s.contains("<svg") { return "image/svg+xml" }
        if b.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "image/webp" }
        return nil
    }

    static func imageExt(for mime: String) -> String? {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/bmp": return "bmp"
        case "image/svg+xml": return "svg"
        case "image/webp": return "webp"
        default: return nil
        }
    }

    // MARK: - 书架书 ID 发现（从 reader 页或书架页拿 bookId）

    /// 用 bookId 拉全书目录预览（导入 UI 用）
    func previewCatalog(bookId: String) async throws -> (title: String, chapters: [WeChapter]) {
        let state = try await fetchReaderState(bookId: bookId, chapterUid: nil)
        let chapters = try await fetchCatalog(bookId: bookId)
        return (state.title.isEmpty ? "微信读书书籍" : state.title, chapters)
    }
}
