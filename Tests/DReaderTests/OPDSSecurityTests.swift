import AppKit
import Foundation
import XCTest
@testable import DReader

@MainActor
final class OPDSSecurityTests: XCTestCase {
    private let sourceURL = "https://catalog.opds.invalid/opds"
    private let expectedAuthorization = "Basic " + Data("fixture-reader:fictional-password".utf8).base64EncodedString()

    private func source(id: UUID = UUID(), url: String? = nil, allowSelfSigned: Bool = false) -> OPDSService.Source {
        .init(id: id, name: "虚构 OPDS", url: url ?? sourceURL, username: "fixture-reader",
              password: "fictional-password", allowSelfSigned: allowSelfSigned)
    }

    private func fixture(image: Data = Data()) -> (OPDSService, OPDSRequestFixture) {
        let fixture = OPDSRequestFixture(image: image)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OPDSFixtureProtocol.self]
        configuration.httpAdditionalHeaders = [
            "X-DReader-OPDS-Fixture": fixture.id,
            // 即使注入配置带默认认证头，也不能绕过逐请求 origin 检查。
            "Authorization": "Basic configuration-must-not-leak"
        ]
        return (OPDSService(configuration: configuration), fixture)
    }

    private var destinations: [(String, Bool)] {
        [
            ("https://catalog.opds.invalid/feed", true),
            ("https://CATALOG.opds.invalid:443/feed", true),
            ("https://cdn.opds.invalid/feed", false),
            ("http://catalog.opds.invalid/feed", false),
            ("https://catalog.opds.invalid:8443/feed", false),
            ("https://catalog.opds.invalid.attacker.invalid/feed", false)
        ]
    }

    func testFeedOnlySendsBasicToConfiguredOrigin() async throws {
        let (service, fixture) = fixture()
        defer { fixture.unregister() }
        let source = source()
        for (href, sameOrigin) in destinations {
            let feed = try await service.fetchFeed(href: href, source: source)
            XCTAssertEqual(feed.title, "Fixture")
            XCTAssertEqual(fixture.requests.last?.value(forHTTPHeaderField: "Authorization"),
                           sameOrigin ? expectedAuthorization : nil, href)
        }
        XCTAssertEqual(fixture.requests.count, destinations.count)
    }

    func testHTTPDefaultPortAndExplicitPortAreEquivalent() async throws {
        let (service, fixture) = fixture()
        defer { fixture.unregister() }
        let source = source(url: "http://catalog.opds.invalid:80/opds")
        for href in ["http://catalog.opds.invalid/feed", "http://catalog.opds.invalid:80/feed"] {
            _ = try await service.fetchFeed(href: href, source: source)
            XCTAssertEqual(fixture.requests.last?.value(forHTTPHeaderField: "Authorization"), expectedAuthorization)
        }
        _ = try await service.fetchFeed(href: "https://catalog.opds.invalid:80/feed", source: source)
        XCTAssertNil(fixture.requests.last?.value(forHTTPHeaderField: "Authorization"))
    }

    func testCoversAndDownloadsUseTheSameOriginBoundary() async throws {
        let (service, fixture) = fixture()
        defer { fixture.unregister() }
        let source = source()
        for (href, sameOrigin) in destinations {
            _ = await service.fetchImage(href: href, source: source)
            XCTAssertEqual(fixture.requests.last?.value(forHTTPHeaderField: "Authorization"),
                           sameOrigin ? expectedAuthorization : nil, "封面：\(href)")
            let entry = OPDSService.Entry(id: href, title: "Fixture", author: "", summary: "", coverURL: nil,
                                         acquisitionLinks: [("application/epub+zip", href)], subsectionHref: nil)
            do {
                _ = try await service.downloadEPUB(entry: entry, source: source)
                XCTFail("fixture 必须在写入下载目录前因缺少 zip 头而失败")
            } catch OPDSService.OPDSError.parse {
                // 有意返回非 EPUB；验证真实 bytes(for:) 路径但不写用户书库。
            } catch {
                XCTFail("下载未到达内容校验：\(error)")
            }
            XCTAssertEqual(fixture.requests.last?.value(forHTTPHeaderField: "Authorization"),
                           sameOrigin ? expectedAuthorization : nil, "下载：\(href)")
        }
        XCTAssertEqual(fixture.requests.count, destinations.count * 2)
    }

    func testRedirectDelegateRecalculatesAuthorizationForEveryHop() throws {
        let (service, fixture) = fixture()
        defer { fixture.unregister() }
        let source = source()
        let context = try service.context(source)
        let delegate = try XCTUnwrap(context.session.delegate as? OPDSService.TrustDelegate)
        let initial = try context.policy.request(for: XCTUnwrap(URL(string: source.url)))
        let task = context.session.dataTask(with: initial)
        defer { task.cancel() }
        let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(initial.url), statusCode: 302,
                                                    httpVersion: "HTTP/1.1", headerFields: [:]))
        for (href, sameOrigin) in destinations {
            var proposed = URLRequest(url: try XCTUnwrap(URL(string: href)))
            proposed.setValue(expectedAuthorization, forHTTPHeaderField: "Authorization")
            proposed.setValue("Basic must-be-removed", forHTTPHeaderField: "Proxy-Authorization")
            var redirected: URLRequest?
            delegate.urlSession(context.session, task: task, willPerformHTTPRedirection: response,
                                newRequest: proposed) { redirected = $0 }
            let request = try XCTUnwrap(redirected)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                           sameOrigin ? expectedAuthorization : nil, href)
            XCTAssertNil(request.value(forHTTPHeaderField: "Proxy-Authorization"))
        }
        // 站外跳转再返回源时，可按源策略恢复认证；不采用上一跳携带的头。
        let returnURL = try XCTUnwrap(URL(string: sourceURL))
        let returnRequest = try context.policy.request(for: returnURL, redirecting: URLRequest(url: returnURL))
        XCTAssertEqual(returnRequest.value(forHTTPHeaderField: "Authorization"), expectedAuthorization)
    }

    func testURLSessionRedirectsDoNotForwardBasicAcrossOrigin() async throws {
        let (service, fixture) = fixture()
        defer { fixture.unregister() }
        let source = source()
        for (href, sameOrigin) in destinations {
            var redirect = try XCTUnwrap(URLComponents(string: sourceURL))
            redirect.path = "/redirect"
            redirect.queryItems = [URLQueryItem(name: "to", value: href)]
            let feed = try await service.fetchFeed(href: XCTUnwrap(redirect.url).absoluteString, source: source)
            XCTAssertEqual(feed.title, "Fixture")
            let requests = fixture.requests
            XCTAssertEqual(requests.suffix(2).first?.value(forHTTPHeaderField: "Authorization"), expectedAuthorization)
            XCTAssertEqual(requests.last?.url, URL(string: href))
            XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"),
                           sameOrigin ? expectedAuthorization : nil, href)
        }
        XCTAssertEqual(fixture.requests.count, destinations.count * 2)
    }

    func testForeignBasicChallengeCannotUseStoredCredentials() throws {
        let (service, fixture) = fixture()
        defer { fixture.unregister() }
        let context = try service.context(source())
        let delegate = try XCTUnwrap(context.session.delegate as? OPDSService.TrustDelegate)
        let space = URLProtectionSpace(host: "cdn.opds.invalid", port: 443, protocol: "https", realm: "Fixture",
                                       authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let stored = URLCredential(user: "fixture-reader", password: "fictional-password", persistence: .forSession)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: stored,
                                                  previousFailureCount: 0, failureResponse: nil, error: nil,
                                                  sender: OPDSChallengeSender())
        delegate.urlSession(context.session, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .rejectProtectionSpace)
            XCTAssertNil(credential)
        }
        XCTAssertNil(context.session.configuration.urlCredentialStorage)
        XCTAssertNil(context.session.configuration.httpCookieStorage)
    }

    func testSelfSignedPolicyIsIsolatedBySourceAndFullOrigin() throws {
        let (service, fixture) = fixture()
        defer { fixture.unregister() }
        let permissive = source(allowSelfSigned: true)
        let strict = source() // 相同主机的另一个源不能继承例外。
        service.updateSources([permissive, strict])
        let permissiveContext = try service.context(permissive)
        let strictContext = try service.context(strict)
        XCTAssertFalse(permissiveContext.session === strictContext.session)
        for (href, sameOrigin) in destinations {
            let space = try protectionSpace(href)
            XCTAssertEqual(permissiveContext.policy.allowsSelfSigned(space), sameOrigin, href)
            XCTAssertFalse(strictContext.policy.allowsSelfSigned(space), href)
        }
        let anonymous = try service.context(nil)
        XCTAssertFalse(anonymous.policy.allowsSelfSigned(try protectionSpace(sourceURL)))
    }

    func testDisablingTrustRevokesOldPolicyAndRejectsStaleSource() throws {
        let (service, fixture) = fixture()
        defer { fixture.unregister() }
        let oldSource = source(allowSelfSigned: true)
        service.updateSources([oldSource])
        let oldContext = try service.context(oldSource)
        let delegate = try XCTUnwrap(oldContext.session.delegate as? OPDSService.TrustDelegate)
        let task = oldContext.session.dataTask(with: try XCTUnwrap(URL(string: sourceURL)))
        defer { task.cancel() }
        let space = try protectionSpace(sourceURL)
        XCTAssertTrue(oldContext.policy.allowsSelfSigned(space))
        var strict = oldSource
        strict.allowSelfSigned = false
        service.updateSources([strict])
        XCTAssertFalse(oldContext.policy.allowsSelfSigned(space))
        XCTAssertThrowsError(try oldContext.policy.request(for: XCTUnwrap(URL(string: sourceURL))))
        XCTAssertThrowsError(try service.context(oldSource))
        let newContext = try service.context(strict)
        XCTAssertFalse(oldContext.session === newContext.session, "必须更换会话以丢弃已放行的 TLS 连接")
        XCTAssertFalse(newContext.policy.allowsSelfSigned(space))

        let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(URL(string: sourceURL)), statusCode: 302,
                                                    httpVersion: "HTTP/1.1", headerFields: [:]))
        delegate.urlSession(oldContext.session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: try XCTUnwrap(URL(string: sourceURL)))) {
            XCTAssertNil($0, "撤销后旧任务不能借重定向重新发出认证")
        }
    }

    func testChangingOrDeletingSourceRevokesOldHostImmediately() throws {
        let (service, fixture) = fixture()
        defer { fixture.unregister() }
        let oldSource = source(allowSelfSigned: true)
        service.updateSources([oldSource])
        let oldContext = try service.context(oldSource)
        var changed = oldSource
        changed.url = "https://replacement.opds.invalid:9443/opds"
        service.updateSources([changed])
        let changedContext = try service.context(changed)
        XCTAssertFalse(oldContext.policy.allowsSelfSigned(try protectionSpace(sourceURL)))
        XCTAssertThrowsError(try service.context(oldSource))
        XCTAssertFalse(changedContext.policy.allowsSelfSigned(try protectionSpace(sourceURL)))
        XCTAssertTrue(changedContext.policy.allowsSelfSigned(try protectionSpace(changed.url)))
        let oldHostRequest = try changedContext.policy.request(for: XCTUnwrap(URL(string: sourceURL)))
        XCTAssertNil(oldHostRequest.value(forHTTPHeaderField: "Authorization"))
        service.updateSources([])
        XCTAssertFalse(changedContext.policy.allowsSelfSigned(try protectionSpace(changed.url)))
        XCTAssertThrowsError(try service.context(changed))
        XCTAssertThrowsError(try changedContext.policy.request(for: XCTUnwrap(URL(string: changed.url))))
    }

    func testCoverCacheDoesNotCrossSourcesOrSurvivePolicyReplacement() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 4, bitsPerPixel: 32))
        let imageData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let (service, fixture) = fixture(image: imageData)
        defer { fixture.unregister() }
        let first = source(allowSelfSigned: true)
        var second = source()
        second.username = "another-fictional-reader"
        service.updateSources([first, second])
        let href = "https://catalog.opds.invalid/cover"
        let firstImage = await service.fetchImage(href: href, source: first)
        XCTAssertNotNil(firstImage)
        _ = await service.fetchImage(href: href, source: first)
        XCTAssertEqual(fixture.requests.count, 1, "同策略可复用缓存")
        _ = await service.fetchImage(href: href, source: second)
        XCTAssertEqual(fixture.requests.count, 2, "切换源不能复用私有封面")
        var strict = first
        strict.allowSelfSigned = false
        service.updateSources([strict, second])
        _ = await service.fetchImage(href: href, source: strict)
        XCTAssertEqual(fixture.requests.count, 3, "关闭信任后必须重新获取")
        let staleImage = await service.fetchImage(href: href, source: first)
        XCTAssertNil(staleImage)
        XCTAssertEqual(fixture.requests.count, 3, "旧配置不能命中缓存或重新发请求")
    }

    func testAnonymousAndUserInfoURLsCannotAcquireSourceCredentials() async throws {
        let (service, fixture) = fixture()
        defer { fixture.unregister() }
        _ = try await service.fetchFeed(href: sourceURL, source: nil)
        XCTAssertNil(fixture.requests.last?.value(forHTTPHeaderField: "Authorization"))
        do {
            _ = try await service.fetchFeed(href: "https://embedded:fictional@cdn.opds.invalid/feed", source: source())
            XCTFail("URL 内嵌凭据应在发请求前拒绝")
        } catch OPDSService.OPDSError.badURL { }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    private func protectionSpace(_ href: String) throws -> URLProtectionSpace {
        let url = try XCTUnwrap(URL(string: href))
        return URLProtectionSpace(host: try XCTUnwrap(url.host), port: url.port ?? (url.scheme == "https" ? 443 : 80),
                                  protocol: url.scheme, realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }
}

/// 所有 URL 都由此协议截获；没有 fixture 或注册头时也直接失败，绝不退回真实网络。
private final class OPDSFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-DReader-OPDS-Fixture"),
              let fixture = OPDSFixtureRegistry.shared.fixture(id), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        fixture.record(request)
        if url.path == "/redirect", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let destination = components.queryItems?.first(where: { $0.name == "to" })?.value,
           let target = URL(string: destination),
           let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                          headerFields: ["Location": destination]) {
            var redirected = request
            redirected.url = target
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        let data = url.path == "/cover" ? fixture.image : Data("<feed xmlns='http://www.w3.org/2005/Atom'><title>Fixture</title></feed>".utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

private final class OPDSRequestFixture: @unchecked Sendable {
    let id = UUID().uuidString
    let image: Data
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }

    init(image: Data) {
        self.image = image
        OPDSFixtureRegistry.shared.register(self)
    }

    func record(_ request: URLRequest) { lock.withLock { recorded.append(request) } }
    func unregister() { OPDSFixtureRegistry.shared.unregister(id) }
}

private final class OPDSFixtureRegistry: @unchecked Sendable {
    static let shared = OPDSFixtureRegistry()
    private let lock = NSLock()
    private var fixtures: [String: OPDSRequestFixture] = [:]
    func register(_ fixture: OPDSRequestFixture) { lock.withLock { fixtures[fixture.id] = fixture } }
    func unregister(_ id: String) { _ = lock.withLock { fixtures.removeValue(forKey: id) } }
    func fixture(_ id: String) -> OPDSRequestFixture? { lock.withLock { fixtures[id] } }
}

private final class OPDSChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { }
    func cancel(_ challenge: URLAuthenticationChallenge) { }
}
