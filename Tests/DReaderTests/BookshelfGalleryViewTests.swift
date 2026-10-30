import AppKit
import SwiftUI
import XCTest
@testable import DReader

@MainActor
final class BookshelfGalleryViewTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dreader-gallery-view-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeBook(title: String = "漫长的中文书籍标题用于检查长廊中央与详情的完整显示", cover: URL? = nil) -> EPUBBook {
        let chapter = EPUBChapter(id: "chapter", title: "第一章",
                                  fileURL: directory.appendingPathComponent("chapter.xhtml"), orderIndex: 0)
        return EPUBBook(title: title, author: "测试作者", bookDescription: "这是一段用于原生详情视图的中文简介。",
                        coverImageURL: cover, fileURL: directory.appendingPathComponent("book.epub"),
                        unzippedDirectory: directory, opfDirectory: directory, chapters: [chapter])
    }

    private func makeCover() async throws -> URL {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 360,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedRed: 31.0 / 255.0, green: 63.0 / 255.0, blue: 176.0 / 255.0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 240, height: 360).fill()
        NSGraphicsContext.restoreGraphicsState()
        let url = directory.appendingPathComponent("cover.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        let loaded = await withCheckedContinuation { continuation in
            CoverImageCache.shared.loadImage(for: url) { image in
                continuation.resume(returning: image)
            }
        }
        XCTAssertNotNil(loaded)
        return url
    }

    private func render<V: View>(_ view: V, width: CGFloat = 800, height: CGFloat = 600,
                                 label: String = "view") throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let color = try XCTUnwrap(image.colorAt(x: Int(width / 2), y: Int(height / 2)))
        XCTAssertGreaterThan(color.alphaComponent, 0, "原生视图不应渲染为空白")
        if let output = ProcessInfo.processInfo.environment["DREADER_GALLERY_PREVIEW_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try image.representation(using: .png, properties: [:])?.write(
                to: directory.appendingPathComponent("\(label).png"))
        }
        return image
    }

    func testRealCoverAndFallbackRenderOffscreen() async throws {
        let coverURL = try await makeCover()
        _ = try render(BookshelfGalleryBookView(
            book: makeBook(cover: coverURL), openness: 1, isHovered: false,
            spineWidth: 32, coverWidth: 160, height: 280, reduceMotion: true,
            onOpen: {}
        ), width: 220, height: 320, label: "real-cover")
        _ = try render(BookshelfGalleryBookView(
            book: makeBook(), openness: 1, isHovered: false,
            spineWidth: 32, coverWidth: 160, height: 280, reduceMotion: true,
            onOpen: {}
        ), width: 220, height: 320, label: "fallback-cover")
        _ = try render(BookshelfGalleryBookView(
            book: makeBook(title: "书脊检查"), openness: 0, isHovered: false,
            spineWidth: 32, coverWidth: 160, height: 280, reduceMotion: false,
            onOpen: {}
        ), width: 220, height: 320, label: "spine-only")
    }

    func testSingleBookGalleryAndEmptySearchRenderOffscreen() async throws {
        _ = try render(BookshelfGalleryView(books: [makeBook()], onSelectBook: { _ in }),
                       width: 900, height: 620, label: "gallery-single")
        _ = try render(BookshelfGalleryView(books: [], onSelectBook: { _ in }, emptyMessage: "没有匹配的书籍"),
                       width: 900, height: 620, label: "gallery-empty")
    }

    func testMultipleBookGalleryShowsSpinesAndCover() async throws {
        let books = (0..<12).map { makeBook(title: "第 \($0) 本藏书") }
        _ = try render(BookshelfGalleryView(books: books, onSelectBook: { _ in }),
                       width: 1200, height: 720, label: "gallery-many")
    }

    func testDetailRendersAndKeepsRealReadingAction() throws {
        let book = makeBook()
        var continued: UUID?
        let detail = BookshelfBookDetailView(book: book, onContinue: { continued = book.id })
        _ = try render(detail, label: "book-detail")
        detail.onContinue()
        XCTAssertEqual(continued, book.id)
    }
}
