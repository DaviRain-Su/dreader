import Foundation

/// 微信读书原生二维码登录（个人互操作用途）。
/// 协议（KOReader weread.koplugin qr_login 同款，已本机实测）：
///   1. 持久化 wr_fp（32 位随机数十进制串）访问 /r/weread-skills 立登录会话
///   2. GET /api/auth/getLoginUid → { uid }
///   3. 手机扫 https://weread.qq.com/web/confirm?uid=… 上的二维码确认
///   4. 轮询 GET /api/auth/getLoginInfo?uid=…&otp=… 直到 succeed==true
///      逻辑码：NEED_OTP（4 位手机验证码）/ LOGIN_TIMEOUT / OTP_EXPIRED / OTP_NOT_MATCH
///   5. 成功耐劳件 webLoginVid/accessToken/refreshToken 拼 wr_vid/wr_skey/wr_rt/wr_ql Cookie
final class WeReadQRLoginService: @unchecked Sendable {
    static let shared = WeReadQRLoginService()

    private static let fingerprintKey = "dreader.weread.wr_fp"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0"
    private static let baseURL = "https://weread.qq.com"
    private static let skillsPage = baseURL + "/r/weread-skills"

    struct PollOutcome {
        let succeed: Bool
        let logicCode: String
        let webLoginVid: String
        let accessToken: String
        let refreshToken: String
    }

    enum LoginError: LocalizedError {
        case http(Int, String)
        case missingUID
        case missingCredentials

        var errorDescription: String? {
            switch self {
            case .http(let code, let stage): return "登录请求 \(stage) HTTP \(code)"
            case .missingUID: return "微信读书未返回有效的登录会话 ID"
            case .missingCredentials: return "登录成功但响应缺少账号凭据"
            }
        }
    }

    private var jar: [String: String] = [:]
    private let jarLock = NSLock()

    /// 不使用系统 cookie 存储：jar 手动管理，wr_fp 贯穿全程（缺独立指纹会多会话顶号）
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    init() {
        jarLock.withLock {
            jar["wr_fp"] = Self.deviceFingerprint()
        }
    }

    /// 安装级持久指纹：32 位随机数的十进制串，每台机器只生成一次
    private static func deviceFingerprint() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: fingerprintKey), !existing.isEmpty {
            return existing
        }
        let fresh = String(UInt32.random(in: 0...UInt32.max))
        defaults.set(fresh, forKey: fingerprintKey)
        return fresh
    }

    func cookieHeader() -> String {
        jarLock.withLock {
            jar.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
        }
    }

    /// 步骤 1+2：立会话并取一次性登录 uid。
    /// 每次扫码都从干净 jar 开始（仅保留 wr_fp），避免上次登录残留凭据污染本次会话。
    func beginSession() async throws -> String {
        jarLock.withLock {
            let fp = jar["wr_fp"]
            jar = fp.map { ["wr_fp": $0] } ?? [:]
        }
        let (_, _) = try await get("/r/weread-skills", referer: Self.baseURL + "/", accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        let (data, resp) = try await get(
            "/api/auth/getLoginUid",
            referer: Self.skillsPage,
            accept: "application/json, text/plain, */*"
        )
        guard (200..<300).contains(resp.statusCode) else {
            throw LoginError.http(resp.statusCode, "getLoginUid")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uid = obj["uid"] as? String, !uid.isEmpty
        else { throw LoginError.missingUID }
        return uid
    }

    /// 二维码内容：手机端扫码后打开此确认链接
    nonisolated static func confirmURL(uid: String) -> String {
        baseURL + "/web/confirm?uid=" + percentEncode(uid)
    }

    /// 步骤 4：单次长轮询（服务端会阻塞至状态变化或 ~5s，超时设 6s 紧贴其窗口）；
    /// transport 错误向上抛，由调用方决定是否继续
    func poll(uid: String, otp: String) async throws -> PollOutcome {
        let otpSuffix = otp.isEmpty ? "" : Self.percentEncode(otp)
        let (data, resp) = try await get(
            "/api/auth/getLoginInfo?uid=\(Self.percentEncode(uid))&otp=\(otpSuffix)",
            referer: Self.skillsPage,
            accept: "application/json, text/plain, */*",
            timeout: 6
        )
        guard (200..<300).contains(resp.statusCode) else {
            throw LoginError.http(resp.statusCode, "getLoginInfo")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoginError.http(resp.statusCode, "getLoginInfo")
        }
        return PollOutcome(
            succeed: (obj["succeed"] as? Bool) == true,
            logicCode: obj["logicCode"] as? String ?? "",
            webLoginVid: obj["webLoginVid"] as? String ?? "",
            accessToken: obj["accessToken"] as? String ?? "",
            refreshToken: obj["refreshToken"] as? String ?? ""
        )
    }

    /// 步骤 5：登录凭证 → 整段 Cookie header（wr_fp 贯穿）
    func finalize(_ outcome: PollOutcome) throws -> String {
        guard !outcome.webLoginVid.isEmpty, !outcome.accessToken.isEmpty else {
            throw LoginError.missingCredentials
        }
        jarLock.withLock {
            jar["wr_vid"] = outcome.webLoginVid
            jar["wr_skey"] = outcome.accessToken
            jar["wr_ql"] = "0"
            if !outcome.refreshToken.isEmpty {
                jar["wr_rt"] = Self.percentEncode(outcome.refreshToken)
            }
        }
        return cookieHeader()
    }

    /// RFC3986 严格百分比编码（quote(safe:=…) 语义，refresh token 必须）
    nonisolated static func percentEncode(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    private func get(_ path: String, referer: String, accept: String, timeout: Double = 20) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let header = cookieHeader()
        if !header.isEmpty {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        request.timeoutInterval = timeout
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            throw LoginError.http(-1, path)
        }
        jarLock.withLock {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: http.allHeaderFields as? [String: String] ?? [:], for: http.url ?? URL(string: Self.baseURL)!)
            for cookie in cookies where !cookie.value.isEmpty {
                jar[cookie.name] = cookie.value
            }
        }
        return (data, http)
    }
}
