import Foundation
import Darwin
import XCTest
@testable import DReader

@MainActor
final class EPUBCacheRegressionTests: XCTestCase {
    private var directory: URL!
    private var cacheRoot: URL!
    private var identityRoot: URL!
    private var shelfRoot: URL!
    private var fileName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("dreader-epub-tests-\(UUID())", isDirectory: true)
        cacheRoot = directory.appendingPathComponent("cache", isDirectory: true)
        identityRoot = directory.appendingPathComponent("identities", isDirectory: true)
        shelfRoot = directory.appendingPathComponent("shelf", isDirectory: true)
        fileName = "cache-regression-\(UUID()).epub"
        for root in [cacheRoot!, identityRoot!, shelfRoot!] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func parser() -> EPUBParser {
        EPUBParser(cacheRoot: cacheRoot, identityRoot: identityRoot)
    }

    /// Every source has a unique basename for this test, and every fixture gets
    /// its own input directory. Only zip/unzip run there; no source is executed.
    private func makeEPUB(at url: URL, title: String, body: String, author: String = "Regression Author",
                          metadataPadding: Int = 0, missingSpine: Bool = false) throws {
        let fm = FileManager.default
        let input = directory.appendingPathComponent("input-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: input.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: input.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("application/epub+zip".utf8).write(to: input.appendingPathComponent("mimetype"))
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">urn:uuid:\(UUID())</dc:identifier>
            <dc:title>\(title)</dc:title><dc:creator>\(author)</dc:creator><dc:language>en</dc:language>
            <dc:description>\(String(repeating: "metadata ", count: metadataPadding))</dc:description>
            <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
          </metadata>
          <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>
          \(missingSpine ? "" : "<spine><itemref idref=\"chapter\"/></spine>")
        </package>
        """
        let chapter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(title)</title></head>
        <body><h1>\(title)</h1><p>\(body)</p></body></html>
        """
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>Contents</title></head><body><nav epub:type="toc"><ol>
            <li><a href="chapter.xhtml">\(title)</a></li>
          </ol></nav></body>
        </html>
        """
        for (path, text) in [("META-INF/container.xml", container), ("OEBPS/content.opf", opf),
                             ("OEBPS/chapter.xhtml", chapter), ("OEBPS/nav.xhtml", nav)] {
            try text.write(to: input.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        // EPUB requires mimetype to be the first member, stored without compression.
        try runArchiveTool("/usr/bin/zip", arguments: ["-q", "-X", "-0", url.path, "mimetype"], cwd: input)
        try runArchiveTool("/usr/bin/zip", arguments: ["-q", "-X", url.path, "META-INF/container.xml",
                                                      "OEBPS/content.opf", "OEBPS/chapter.xhtml", "OEBPS/nav.xhtml"], cwd: input)
    }

    private func runArchiveTool(_ executable: String, arguments: [String], cwd: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, executable)
    }

    private func body(of book: EPUBBook) throws -> String {
        try String(contentsOf: XCTUnwrap(book.chapters.first).fileURL, encoding: .utf8)
    }

    private func assertComplete(_ book: EPUBBook, source: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let marker = try XCTUnwrap(EPUBIdentity.readMarker(in: book.unzippedDirectory), file: file, line: line)
        XCTAssertEqual(marker.bookID, book.id, file: file, line: line)
        XCTAssertEqual(marker.archiveFingerprint, try EPUBIdentity.fingerprint(of: source), file: file, line: line)
        XCTAssertEqual(marker.sourceFingerprint.count, 64, file: file, line: line)
        XCTAssertEqual(marker.payloadFingerprint.count, 64, file: file, line: line)
        XCTAssertEqual(try EPUBIdentity.relativePath(of: book.opfDirectory, in: book.unzippedDirectory), "OEBPS", file: file, line: line)
        for chapter in book.chapters {
            XCTAssertEqual(try EPUBIdentity.relativePath(of: chapter.fileURL, in: book.unzippedDirectory), "OEBPS/chapter.xhtml", file: file, line: line)
            XCTAssertTrue(FileManager.default.fileExists(atPath: chapter.fileURL.path), file: file, line: line)
        }
        for item in book.toc {
            XCTAssertEqual(try EPUBIdentity.relativePath(of: item.targetURL, in: book.unzippedDirectory), "OEBPS/chapter.xhtml", file: file, line: line)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path).contains { $0.hasPrefix(".extract-") }, file: file, line: line)
    }

    func testSameBasenameDifferentContentsNeverShareIdentityOrCache() async throws {
        let first = shelfRoot.appendingPathComponent(fileName)
        let second = shelfRoot.appendingPathComponent("Variants/second/\(fileName!)")
        try makeEPUB(at: first, title: "Book Alpha", body: "unique-alpha-body")
        try makeEPUB(at: second, title: "Book Beta", body: "unique-beta-body")
        let a = try await parser().parse(fileURL: first)
        let b = try await parser().parse(fileURL: second)
        XCTAssertEqual(a.id, EPUBIdentity.legacyBookID(forFileName: fileName))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.unzippedDirectory, b.unzippedDirectory)
        XCTAssertEqual(a.title, "Book Alpha")
        XCTAssertEqual(b.title, "Book Beta")
        XCTAssertTrue(try body(of: a).contains("unique-alpha-body"))
        XCTAssertTrue(try body(of: b).contains("unique-beta-body"))
        try assertComplete(a, source: first)
        try assertComplete(b, source: second)
        // Reproduce a cache root reached through an alias while FileManager's
        // enumerator emits canonical URLs, as /var and /private/var do on macOS.
        let cacheAlias = directory.appendingPathComponent("cache-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: cacheAlias, withDestinationURL: cacheRoot)
        let aliased = cacheAlias.appendingPathComponent(a.unzippedDirectory.lastPathComponent, isDirectory: true)
        XCTAssertEqual(try EPUBIdentity.payloadFingerprint(in: aliased), try EPUBIdentity.payloadFingerprint(in: a.unzippedDirectory))
        let rootWithTrailingSlash = URL(fileURLWithPath: aliased.path + "/", isDirectory: true)
        XCTAssertEqual(try EPUBIdentity.relativePath(of: XCTUnwrap(a.chapters.first).fileURL, in: rootWithTrailingSlash), "OEBPS/chapter.xhtml")
        let sibling = a.unzippedDirectory.deletingLastPathComponent().appendingPathComponent(a.unzippedDirectory.lastPathComponent + "-other/chapter.xhtml")
        XCTAssertThrowsError(try EPUBIdentity.relativePath(of: sibling, in: a.unzippedDirectory))
    }

    func testOverwritingSourceGetsNewIdentityAndLeavesOpenVersionIntact() async throws {
        let url = shelfRoot.appendingPathComponent(fileName)
        try makeEPUB(at: url, title: "Original", body: "original-body")
        let original = try await parser().parse(fileURL: url)
        let bytes = try Data(contentsOf: url)
        try makeEPUB(at: url, title: "Replacement", body: "replacement-body")
        let replacement = try await parser().parse(fileURL: url)
        XCTAssertNotEqual(original.id, replacement.id)
        XCTAssertNotEqual(original.unzippedDirectory, replacement.unzippedDirectory)
        XCTAssertEqual(replacement.title, "Replacement")
        XCTAssertTrue(try body(of: original).contains("original-body"))
        XCTAssertTrue(try body(of: replacement).contains("replacement-body"))
        try bytes.write(to: url, options: .atomic)
        let restored = try await parser().parse(fileURL: url)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.unzippedDirectory, original.unzippedDirectory)
    }

    func testRepeatedConcurrentParsesAndCacheRemovalKeepBothIDsStable() async throws {
        let first = shelfRoot.appendingPathComponent(fileName)
        let second = shelfRoot.appendingPathComponent("Variants/second/\(fileName!)")
        try makeEPUB(at: first, title: "Stable Alpha", body: "stable-alpha")
        try makeEPUB(at: second, title: "Stable Beta", body: "stable-beta")
        let firstParser = parser()
        let anotherParser = parser()
        async let a = firstParser.parse(fileURL: first)
        async let again = anotherParser.parse(fileURL: first)
        let (original, repeated) = try await (a, again)
        XCTAssertEqual(original.id, repeated.id)
        XCTAssertEqual(original.unzippedDirectory, repeated.unzippedDirectory)
        let other = try await parser().parse(fileURL: second)
        let before = try Data(contentsOf: original.unzippedDirectory.appendingPathComponent(EPUBIdentity.markerName))
        let reopened = try await parser().parse(fileURL: first)
        XCTAssertEqual(original.id, reopened.id)
        XCTAssertEqual(before, try Data(contentsOf: reopened.unzippedDirectory.appendingPathComponent(EPUBIdentity.markerName)))
        try FileManager.default.removeItem(at: cacheRoot)
        // Reverse order after cache deletion must not give Beta Alpha's old ID.
        let otherAfterPurge = try await parser().parse(fileURL: second)
        let originalAfterPurge = try await parser().parse(fileURL: first)
        XCTAssertEqual(otherAfterPurge.id, other.id)
        XCTAssertEqual(originalAfterPurge.id, original.id)
        XCTAssertTrue(try body(of: otherAfterPurge).contains("stable-beta"))
        try assertComplete(originalAfterPurge, source: first)
    }

    func testLegacyCacheMigratesUUIDWithoutAdoptingDifferentSource() async throws {
        let oldURL = shelfRoot.appendingPathComponent(fileName)
        let newURL = shelfRoot.appendingPathComponent("Variants/new/\(fileName!)")
        try makeEPUB(at: oldURL, title: "Legacy Book", body: "legacy-source-body")
        try makeEPUB(at: newURL, title: "Different Book", body: "different-source-body")
        let legacyID = EPUBIdentity.legacyBookID(forFileName: fileName)
        let oldCache = cacheRoot.appendingPathComponent(legacyID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: oldCache, withIntermediateDirectories: true)
        try runArchiveTool("/usr/bin/unzip", arguments: ["-q", oldURL.path, "-d", oldCache.path])
        let sourcePayload = try EPUBIdentity.payloadFingerprint(in: oldCache)
        try "generated reader HTML".write(to: oldCache.appendingPathComponent("_dreader_render.html"), atomically: true, encoding: .utf8)
        try Data("macOS metadata".utf8).write(to: oldCache.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(try EPUBIdentity.payloadFingerprint(in: oldCache), sourcePayload,
                       "Ignoring generated regular files must not prune EPUB source siblings")
        let newBook = try await parser().parse(fileURL: newURL)
        let recordURL = EPUBIdentity.recordURL(root: identityRoot, fileName: fileName)
        let ownership = try JSONDecoder().decode(EPUBIdentity.Record.self, from: Data(contentsOf: recordURL))
        XCTAssertEqual(ownership.legacyPayloadFingerprint, sourcePayload)
        XCTAssertNotEqual(newBook.id, legacyID)
        let oldBook = try await parser().parse(fileURL: oldURL)
        XCTAssertEqual(try XCTUnwrap(EPUBIdentity.readMarker(in: oldBook.unzippedDirectory)).payloadFingerprint, sourcePayload)
        XCTAssertEqual(oldBook.id, legacyID)
        XCTAssertTrue(try body(of: oldBook).contains("legacy-source-body"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldBook.unzippedDirectory.appendingPathComponent("_dreader_render.html").path))
        try FileManager.default.removeItem(at: cacheRoot)
        let newAfterPurge = try await parser().parse(fileURL: newURL)
        let oldAfterPurge = try await parser().parse(fileURL: oldURL)
        XCTAssertEqual(newAfterPurge.id, newBook.id)
        XCTAssertEqual(oldAfterPurge.id, legacyID)
    }

    func testFailedExtractionOrParsingCanRetrySameFilenameWithoutClaimingIdentity() async throws {
        let url = shelfRoot.appendingPathComponent(fileName)
        try Data([0x50, 0x4b, 0x03, 0x04, 0, 0, 0]).write(to: url)
        do {
            _ = try await parser().parse(fileURL: url)
            XCTFail("truncated ZIP should fail")
        } catch {}
        try makeEPUB(at: url, title: "Broken OPF", body: "bad-spine", missingSpine: true)
        do {
            _ = try await parser().parse(fileURL: url)
            XCTFail("missing spine should fail")
        } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: identityRoot.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path).isEmpty)
        let legacyID = EPUBIdentity.legacyBookID(forFileName: fileName)
        let remnant = cacheRoot.appendingPathComponent(legacyID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: remnant, withIntermediateDirectories: true)
        try "leftover from old extraction".write(to: remnant.appendingPathComponent("partial.txt"), atomically: true, encoding: .utf8)
        try makeEPUB(at: url, title: "Repaired", body: "repaired-body")
        let repaired = try await parser().parse(fileURL: url)
        XCTAssertEqual(repaired.id, legacyID)
        XCTAssertEqual(repaired.title, "Repaired")
        XCTAssertTrue(try body(of: repaired).contains("repaired-body"))
        try assertComplete(repaired, source: url)
    }

    func testCacheWithMissingOrMismatchedCompletionMarkerIsRebuilt() async throws {
        let url = shelfRoot.appendingPathComponent(fileName)
        try makeEPUB(at: url, title: "Complete", body: "fresh-body")
        let book = try await parser().parse(fileURL: url)
        let chapter = try XCTUnwrap(book.chapters.first).fileURL
        let markerURL = book.unzippedDirectory.appendingPathComponent(EPUBIdentity.markerName)
        let marker = try Data(contentsOf: markerURL)
        try FileManager.default.removeItem(at: markerURL)
        try "stale partial body".write(to: chapter, atomically: true, encoding: .utf8)
        let rebuilt = try await parser().parse(fileURL: url)
        XCTAssertEqual(book.id, rebuilt.id)
        XCTAssertTrue(try body(of: rebuilt).contains("fresh-body"))
        var wrongMarker = try XCTUnwrap(JSONSerialization.jsonObject(with: marker) as? [String: Any])
        wrongMarker["archiveFingerprint"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: wrongMarker).write(to: markerURL, options: .atomic)
        try "wrong-version body".write(to: chapter, atomically: true, encoding: .utf8)
        let rebuiltAgain = try await parser().parse(fileURL: url)
        XCTAssertTrue(try body(of: rebuiltAgain).contains("fresh-body"))
        try assertComplete(rebuiltAgain, source: url)
    }

    func testActualMCPReadsLargeMembersAndUsesMatchingGUICache() async throws {
        let first = shelfRoot.appendingPathComponent(fileName)
        let second = shelfRoot.appendingPathComponent("Variants/second/\(fileName!)")
        let largeBody = "RAW_B_START " + String(repeating: "large chapter payload ", count: 100_000)
        try makeEPUB(at: first, title: "MCP Alpha", body: "RAW_A_START", metadataPadding: 100_000)
        try makeEPUB(at: second, title: "MCP Beta", body: largeBody, metadataPadding: 100_000)
        let a = try await parser().parse(fileURL: first)
        let b = try await parser().parse(fileURL: second)
        try "<p>GUI_CACHE_ALPHA</p>".write(to: XCTUnwrap(a.chapters.first).fileURL, atomically: true, encoding: .utf8)
        try "<p>GUI_CACHE_BETA</p>".write(to: XCTUnwrap(b.chapters.first).fileURL, atomically: true, encoding: .utf8)
        let responses = try runMCP(requests: [
            ["id": 1, "method": "tools/call", "params": ["name": "list_books", "arguments": [:]]],
            ["id": 2, "method": "tools/call", "params": ["name": "get_chapter_text", "arguments": ["book_title": "MCP Alpha", "chapter_index": 0]]],
            ["id": 3, "method": "tools/call", "params": ["name": "get_chapter_text", "arguments": ["book_title": "MCP Beta", "chapter_index": 0]]],
            ["id": 4, "method": "ping"]
        ])
        XCTAssertEqual(responses.count, 4)
        let listing = try resultText(responses, id: 1)
        XCTAssertTrue(listing.contains("MCP Alpha"))
        XCTAssertTrue(listing.contains("MCP Beta"))
        XCTAssertTrue(try resultText(responses, id: 2).contains("GUI_CACHE_ALPHA"))
        XCTAssertFalse(try resultText(responses, id: 2).contains("GUI_CACHE_BETA"))
        XCTAssertTrue(try resultText(responses, id: 3).contains("GUI_CACHE_BETA"))
        XCTAssertNotNil(responses.first { ($0["id"] as? Int) == 4 }?["result"])
        // Incomplete GUI caches must be ignored, and the multi-MB raw chapter
        // must drain successfully before unzip exits. Ping proves no pipe stall.
        try FileManager.default.removeItem(at: b.unzippedDirectory.appendingPathComponent(EPUBIdentity.markerName))
        let fallback = try runMCP(requests: [
            ["id": 5, "method": "tools/call", "params": ["name": "get_chapter_text", "arguments": ["book_title": "MCP Beta", "chapter_index": 0]]],
            ["id": 6, "method": "ping"]
        ])
        XCTAssertEqual(fallback.count, 2)
        XCTAssertTrue(try resultText(fallback, id: 5).contains("RAW_B_START"))
        XCTAssertFalse(try resultText(fallback, id: 5).contains("GUI_CACHE_BETA"))
        XCTAssertNotNil(fallback.first { ($0["id"] as? Int) == 6 }?["result"])
    }

    func testActualMCPAndGUIChooseNewestVariantWithSameTitle() async throws {
        let fm = FileManager.default
        let support = directory.appendingPathComponent("support", isDirectory: true)
        shelfRoot = support.appendingPathComponent("DownloadedBooks", isDirectory: true)
        let first = shelfRoot.appendingPathComponent(fileName)
        let second = shelfRoot.appendingPathComponent("Variants/newer/\(fileName!)")
        let title = "MCP Shared Edition"
        try makeEPUB(at: first, title: title, body: "OLDER_TOP_LEVEL_BODY", author: "Older Edition Author")
        try makeEPUB(at: second, title: title, body: "NEWER_VARIANT_BODY", author: "Newer Edition Author")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: first.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)], ofItemAtPath: second.path)
        let sources = ReaderViewModel.persistedLibraryEPUBs(baseDirectory: support)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(try EPUBIdentity.fingerprint(of: XCTUnwrap(sources.first)), try EPUBIdentity.fingerprint(of: second))
        // Restore parses the enumerated source URLs; use those same canonical
        // URLs here while deliberately supplying candidates in reverse order.
        let oldBook = try await parser().parse(fileURL: XCTUnwrap(sources.last))
        let newerBook = try await parser().parse(fileURL: XCTUnwrap(sources.first))
        XCTAssertNotEqual(oldBook.id, newerBook.id)
        let guiBooks = ReaderViewModel.orderedRestoredBooks([oldBook, newerBook], sourceURLs: sources)
        XCTAssertEqual(guiBooks.map(\.id), [newerBook.id])
        XCTAssertTrue(try body(of: XCTUnwrap(guiBooks.first)).contains("NEWER_VARIANT_BODY"))

        let responses = try runMCP(requests: [
            ["id": 10, "method": "tools/call", "params": ["name": "list_books", "arguments": [:]]],
            ["id": 11, "method": "tools/call", "params": ["name": "get_chapter_text", "arguments": ["book_title": title, "chapter_index": 0]]],
            ["id": 12, "method": "ping"]
        ])
        XCTAssertEqual(responses.count, 3)
        let listing = try resultText(responses, id: 10)
        XCTAssertTrue(listing.contains("共 1 本"))
        XCTAssertEqual(listing.components(separatedBy: title).count - 1, 1)
        XCTAssertTrue(listing.contains("Newer Edition Author"))
        XCTAssertFalse(listing.contains("Older Edition Author"))
        let chapter = try resultText(responses, id: 11)
        XCTAssertTrue(chapter.contains("NEWER_VARIANT_BODY"))
        XCTAssertFalse(chapter.contains("OLDER_TOP_LEVEL_BODY"))
        XCTAssertNotNil(responses.first { ($0["id"] as? Int) == 12 }?["result"])
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        let finished = DispatchSemaphore(value: 0)
        func store(_ data: Data) {
            lock.lock()
            bytes = data
            lock.unlock()
            finished.signal()
        }
        func data() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return bytes
        }
    }

    private func runMCP(requests: [[String: Any]]) throws -> [[String: Any]] {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = project.appendingPathComponent(".build/debug/dreader-mcp")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("Build dreader-mcp before running the executable integration regression")
        }
        let process = Process()
        process.executableURL = binary
        // Explicit roots keep shelf, caches, identity records and SQLite away
        // from the user's HOME; only synthetic books can be observed.
        var environment = ProcessInfo.processInfo.environment
        environment["DREADER_APP_SUPPORT_ROOT"] = directory.appendingPathComponent("support").path
        environment["DREADER_EPUB_ROOT"] = shelfRoot.path
        environment["DREADER_CACHE_ROOT"] = cacheRoot.path
        environment["DREADER_IDENTITY_ROOT"] = identityRoot.path
        process.environment = environment
        process.currentDirectoryURL = project
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let capture = Capture()
        DispatchQueue.global().async {
            capture.store(output.fileHandleForReading.readDataToEndOfFile())
        }
        for request in requests {
            var message = request
            message["jsonrpc"] = "2.0"
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data([0x0a]))
        }
        try input.fileHandleForWriting.close()
        guard exited.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw NSError(domain: "EPUBCacheRegression", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "dreader-mcp timed out reading a large ZIP member"])
        }
        XCTAssertEqual(process.terminationStatus, 0)
        guard capture.finished.wait(timeout: .now() + 2) == .success else {
            throw NSError(domain: "EPUBCacheRegression", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "dreader-mcp stdout did not close"])
        }
        return try capture.data().split(separator: 0x0a).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }

    private func resultText(_ responses: [[String: Any]], id: Int) throws -> String {
        let response = try XCTUnwrap(responses.first { ($0["id"] as? Int) == id })
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }
}
