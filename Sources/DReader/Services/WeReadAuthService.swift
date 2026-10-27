import Foundation

/// 微信读书登录态统一守门：验证 + 自动续期。
///
/// 背景（诊断结论）：扫码成功≠凭据可用；wr_skey 有 TTL，接口报 -2010/-2012 时
/// 可经 POST /web/login/renewal 续命（KOReader 同款）。此前未做这两件事，
/// 导致"扫码显示成功 → 云端书架报登录失效 → 反复扫码"死循环。
enum WeReadAuthService {

    enum AuthError: LocalizedError {
        case invalidCookie(String)
        var errorDescription: String? {
            switch self {
            case .invalidCookie(let detail):
                return "登录态验证未通过：\(detail)"
            }
        }
    }

    /// 判定业务层登录失效（i.weread 用 errCode，web 域部分接口同形）
    static func isAuthErrorCode(_ code: Int) -> Bool {
        code == -2010 || code == -2012
    }

    /// renewal：POST /web/login/renewal，成功时响应带 succ:true 且可能下发新 Set-Cookie。
    /// 失败必须保留原 Cookie（KOReader 同款语义）。
    @discardableResult
    static func renew() async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://weread.qq.com/web/login/renewal")!)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://weread.qq.com/", forHTTPHeaderField: "Origin")
        request.setValue("https://weread.qq.com/", forHTTPHeaderField: "Referer")
        let cookie = WeReadContentService.shared.cookie
        guard !cookie.isEmpty else { return false }
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["rq": "%2Fweb%2Fbook%2Fread", "ql": false])
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["succ"] as? Bool == true) || (obj["succ"] as? String == "1")
        else { return false }

        // 成功续期：合并响应 Set-Cookie（wr_skey 常在此刷新）
        var merged = parseCookieHeader(cookie)
        for cookieObj in HTTPCookie.cookies(withResponseHeaderFields: http.allHeaderFields as? [String: String] ?? [:], for: http.url ?? URL(string: "https://weread.qq.com")!) where !cookieObj.value.isEmpty {
            merged[cookieObj.name] = cookieObj.value
        }
        let newHeader = merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        if newHeader != cookie {
            WeReadContentService.shared.cookie = newHeader
        }
        return true
    }

    /// 登录态验证：拉一次书架（前几本）。扫码成功后必须过此关再提示用户成功。
    static func validate() async throws {
        let shelf = try await WeReadShelfService.shared.fetchShelf()
        // 书架为空不算失败（新账号可能没书），能拿到 200 即为有效登录
        _ = shelf
    }

    /// 解析 Cookie header 字符串为键值表
    static func parseCookieHeader(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !value.isEmpty {
                result[name] = value
            }
        }
        return result
    }
}
