import Foundation
import AppKit

/// Generates compliant sample EPUB books with high-resolution artistic covers on first launch
final class SampleBookGenerator: Sendable {
    static let shared = SampleBookGenerator()

    private init() {}

    func generateAllSampleBooksIfNeeded() async -> [URL] {
        var results: [URL] = []
        if let u1 = await generateWalden() { results.append(u1) }
        if let u2 = await generateLittlePrince() { results.append(u2) }
        if let u3 = await generateLuXun() { results.append(u3) }
        return results
    }

    func generateSampleBookIfNeeded() async -> URL? {
        let all = await generateAllSampleBooksIfNeeded()
        return all.first
    }

    // MARK: - 1. Walden
    private func generateWalden() async -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dreaderDir = appSupport.appendingPathComponent("DReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dreaderDir, withIntermediateDirectories: true)

        let target = dreaderDir.appendingPathComponent("Walden_v2.epub")
        if FileManager.default.fileExists(atPath: target.path) {
            return target
        }

        let chapters = [
            ("第一章：生活的必需品与极简之思", """
            <h1>第一章：生活的必需品与极简之思</h1>
            <p>大部分过着沉静绝望生活的人，其实是在自寻烦恼。所谓的顺从与忍耐，不过是积习已久的无可奈何。</p>
            <p>我们被过多的琐碎之物所绑架。一个人如果能把自己的生活必需品缩减到最基本的一日三餐、御寒之衣与庇风之所，他便能赢回最宝贵的一样东西——属于自己的时间与思想自由。</p>
            <blockquote>“多余的财富只能买来多余的东西。至于灵魂所必需之物，绝不需要用金钱去购买。”</blockquote>
            <p>在这个匆忙奔走的世界上，人们渴望拥有更多的房屋、田地与机械，却很少驻足思考：我们究竟是在占有财产，还是反过来被财产所占有？当清晨的微风拂过湖面，那份无拘无束的清明，胜过一切尘世的虚妄繁荣。</p>
            """),
            ("第二章：黎明、时间与全然的清醒", """
            <h1>第二章：黎明、时间与全然的清醒</h1>
            <p>每一个黎明都是一次重新诞生自我的请柬。大自然从未催促过任何一朵花的开放，而我们却总在追赶着钟表的刻度。</p>
            <p>我走向森林，是因为我想要从容不迫地生活，只去面对生命最根本的事实，看看我能否学到它所教诲的真理，以免在将死之时，才骤然发觉自己从未真正活过。</p>
            <blockquote>“时间不过是我在其中垂钓的小溪。我啜饮它；但当我饮水时，我看见沙质的溪底，发觉它是多么浅薄。它的涓涓细流流逝了，但永恒依然留存。”</blockquote>
            <p>所谓的‘清醒’，不仅是睁开双眼，更是保持心智的高敏度与灵性觉察。</p>
            """),
            ("第三章：古典阅读与崇高心智", """
            <h1>第三章：古典阅读与崇高心智</h1>
            <p>阅读崇高的文字，应当如同勇士面对决斗一般，全神贯注且心怀敬畏。伟大的作者所写下的句子，绝非为了消遣漫长的午后，而是为了唤醒沉睡的灵魂。</p>
            <blockquote>“一本真正的好书，是向我们展示了更高维度的生命形式。它不仅回答我们的困惑，更重塑我们提问的方式。”</blockquote>
            <p>重拾深度的阅读吧。在字句之间，不仅有作者的思想，更有你正在被照亮的心灵。</p>
            """),
            ("第四章：瓦尔登湖——大自然的明眸", """
            <h1>第四章：瓦尔登湖——大自然的明眸</h1>
            <p>湖泊是风景中最美丽、最具表情的姿容。它是大地的眼睛，凝视其中，人们得以测量自身天性的深度。</p>
            <blockquote>“你在湖边所感到的宁静，不是冷清与荒芜，而是大千世界归于和谐之后的纯然自足。”</blockquote>
            <p>即便风暴来临，掀起层层涟漪，湖底的砂石依然安详静卧。我们的心灵亦应当如这汪湖水一般，外显波澜以应万物，内蓄定力以守澄澈。</p>
            """)
        ]

        let coverData = Self.renderCoverImage(
            mainTitle: "瓦尔登湖",
            subTitle: "沉思与极简生活精萃",
            author: "［美］亨利·戴维·梭罗 著",
            badge: "世界自然文学沉思录 · 极简主义传世经典",
            colorHex1: "#1B382B",
            colorHex2: "#0A1710",
            goldHex: "#ECC376"
        )

        return await buildEPUB(
            targetURL: target,
            bookId: "walden-001",
            title: "瓦尔登湖·沉思与极简精萃",
            author: "亨利·戴维·梭罗",
            description: "梭罗隐居瓦尔登湖畔的经典哲学思辨之作，探讨极简生活与自然美学。",
            coverImageData: coverData,
            chapters: chapters
        )
    }

    // MARK: - 2. Little Prince
    private func generateLittlePrince() async -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dreaderDir = appSupport.appendingPathComponent("DReader", isDirectory: true)
        let target = dreaderDir.appendingPathComponent("Little_Prince_v2.epub")
        if FileManager.default.fileExists(atPath: target.path) {
            return target
        }

        let chapters = [
            ("第一章：沙漠降落与绵羊的画像", """
            <h1>第一章：沙漠降落与绵羊的画像</h1>
            <p>六岁那年，我曾在一本描写原始森林的名叫《真实的故事》的书中，看到过一幅精彩的插画。画中是一条大蟒蛇正吞食一头野兽。</p>
            <p>大人们总是需要解释。他们从来不能自己理解任何事情，对孩子们来说，总要没完没了地给他们解释，真是太累人了。</p>
            <blockquote>“所有成年人都曾经是个孩子，只是很少有人还记得这一点。”</blockquote>
            """),
            ("第二章：B-612小行星与傲慢的玫瑰", """
            <h1>第二章：B-612小行星与傲慢的玫瑰</h1>
            <p>在小王子的星球上，一朵奇特的花儿在清晨绽放了。她极其爱美，且带着一点儿虚荣的骄傲。</p>
            <p>“我想现在是吃早点的时候了，”她风情万种地补充道，“请别忘了照顾我……”</p>
            <blockquote>“我那时什么都不懂！我应该根据她的行为，而不是她的言语来评判她。她照亮了我的生命，散发着芬芳。我真不该离开她逃跑的！”</blockquote>
            """),
            ("第三章：狐狸的秘密与驯服的真谛", """
            <h1>第三章：狐狸的秘密与驯服的真谛</h1>
            <p>就在这时，狐狸出现了。“你好，”狐狸说，“如果你驯服了我，我们就会彼此需要。对我来说，你将是世界上独一无二的；对你来说，我也将是世界上独一无二的……”</p>
            <blockquote>“这就是我的秘密。它很简单：只有用心去看，才能看得真切。重要的东西，肉眼是看不见的。”</blockquote>
            <p>“正是你为你玫瑰付出的时间，让你的玫瑰变得如此重要。你必须对你驯服的一切负责到底。”</p>
            """)
        ]

        let coverData = Self.renderCoverImage(
            mainTitle: "小 王 子",
            subTitle: "星际漫游与玫瑰之约",
            author: "［法］安托万·德·圣-埃克苏佩里 著",
            badge: "献给所有曾是孩子的大人 · 纯真之眼与爱的责任",
            colorHex1: "#14213D",
            colorHex2: "#080E1B",
            goldHex: "#F3D084"
        )

        return await buildEPUB(
            targetURL: target,
            bookId: "little-prince-002",
            title: "小王子·星际漫游与玫瑰",
            author: "安托万·德·圣-埃克苏佩里",
            description: "献给所有曾经是孩子的大人，关于爱、责任与纯真眼眸的传世寓言。",
            coverImageData: coverData,
            chapters: chapters
        )
    }

    // MARK: - 3. Lu Xun
    private func generateLuXun() async -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dreaderDir = appSupport.appendingPathComponent("DReader", isDirectory: true)
        let target = dreaderDir.appendingPathComponent("LuXun_v2.epub")
        if FileManager.default.fileExists(atPath: target.path) {
            return target
        }

        let chapters = [
            ("第一章：从百草园到三味书屋", """
            <h1>第一章：从百草园到三味书屋</h1>
            <p>我家的后面有一个很大的园，相传叫作百草园。现在是早已并屋子一起卖给朱姓的子孙了，连最后的相质也已经隔成了别家的墙。</p>
            <p>不必说碧绿的菜畦，光滑的石井栏，高大的皂荚树，紫红的桑椹；也不必说鸣蝉在树叶里长吟，肥胖的黄蜂伏在菜花上，轻捷的叫天子忽然从草间直窜向云霄里去了。</p>
            <blockquote>“单是周围的短短的泥墙根一带，就有无限趣味。”</blockquote>
            """),
            ("第二章：藤野先生与觉醒之光", """
            <h1>第二章：藤野先生与觉醒之光</h1>
            <p>东京也无非是这样。上野的樱花烂熳的时节，望去确也像绯红的轻云，但花下也缺不了成群结队的‘清国留学生’的速成班。</p>
            <p>每当夜间疲倦，正想偷懒时，仰面在灯光中瞥见他黑瘦的面貌，似乎正要说出抑扬顿挫的话来，便闭了目，复又硬着头皮，继续写下去。</p>
            <blockquote>“他的性格，在我的眼里和心里是伟大的，虽然他的姓名并不为许多人所知道。”</blockquote>
            """)
        ]

        let coverData = Self.renderCoverImage(
            mainTitle: "朝花夕拾",
            subTitle: "记忆与觉醒的沉思录",
            author: "鲁 迅 著",
            badge: "现代文学经典的温情怀恋 · 觉醒年代的心智写照",
            colorHex1: "#44141E",
            colorHex2: "#1C060B",
            goldHex: "#E8C27E"
        )

        return await buildEPUB(
            targetURL: target,
            bookId: "luxun-003",
            title: "朝花夕拾·记忆与觉醒",
            author: "鲁迅",
            description: "鲁迅回忆童年与青年求学时期的经典散文集，平淡中见真切与深邃。",
            coverImageData: coverData,
            chapters: chapters
        )
    }

    // MARK: - Cover Image Renderer
    static func renderCoverImage(
        mainTitle: String,
        subTitle: String,
        author: String,
        badge: String,
        colorHex1: String,
        colorHex2: String,
        goldHex: String
    ) -> Data? {
        let size = NSSize(width: 600, height: 900)
        let image = NSImage(size: size)
        image.lockFocus()

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }

        // 1. Rich Background Gradient
        let c1 = NSColor(hex: colorHex1).cgColor
        let c2 = NSColor(hex: colorHex2).cgColor
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let grad = CGGradient(colorsSpace: colorSpace, colors: [c1, c2] as CFArray, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 900), end: CGPoint(x: 0, y: 0), options: [])
        }

        // 2. Leather/Grain Highlights
        let goldColor = NSColor(hex: goldHex)
        ctx.setStrokeColor(goldColor.withAlphaComponent(0.65).cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(CGRect(x: 32, y: 32, width: 536, height: 836))

        ctx.setStrokeColor(goldColor.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 44, y: 44, width: 512, height: 812))

        // Text Drawing Styles
        let paraCenter = NSMutableParagraphStyle()
        paraCenter.alignment = .center

        // Top Ornament
        let crestAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28),
            .foregroundColor: goldColor.withAlphaComponent(0.85),
            .paragraphStyle: paraCenter
        ]
        NSAttributedString(string: "✦ ❦ ✦", attributes: crestAttrs).draw(in: CGRect(x: 50, y: 760, width: 500, height: 40))

        // Main Title
        let titleFont = NSFont(name: "Songti SC", size: 48) ?? NSFont.boldSystemFont(ofSize: 48)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: goldColor,
            .paragraphStyle: paraCenter
        ]
        NSAttributedString(string: mainTitle, attributes: titleAttrs).draw(in: CGRect(x: 50, y: 560, width: 500, height: 140))

        // Divider
        ctx.setStrokeColor(goldColor.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeLineSegments(between: [CGPoint(x: 220, y: 535), CGPoint(x: 380, y: 535)])

        // Subtitle
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .light),
            .foregroundColor: goldColor.withAlphaComponent(0.85),
            .paragraphStyle: paraCenter
        ]
        NSAttributedString(string: subTitle, attributes: subAttrs).draw(in: CGRect(x: 50, y: 480, width: 500, height: 35))

        // Author
        let authorFont = NSFont(name: "Kaiti SC", size: 26) ?? NSFont.systemFont(ofSize: 26, weight: .medium)
        let authorAttrs: [NSAttributedString.Key: Any] = [
            .font: authorFont,
            .foregroundColor: goldColor.withAlphaComponent(0.95),
            .paragraphStyle: paraCenter
        ]
        NSAttributedString(string: author, attributes: authorAttrs).draw(in: CGRect(x: 50, y: 340, width: 500, height: 40))

        // Bottom Badge
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: goldColor.withAlphaComponent(0.7),
            .paragraphStyle: paraCenter
        ]
        NSAttributedString(string: badge, attributes: badgeAttrs).draw(in: CGRect(x: 50, y: 100, width: 500, height: 30))

        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            return nil
        }
        return jpegData
    }

    // MARK: - Builder
    func buildEPUB(
        targetURL: URL,
        bookId: String,
        title: String,
        author: String,
        description: String,
        coverImageData: Data? = nil,
        chapters: [(String, String)]
    ) async -> URL? {
        let tempDir = targetURL.deletingLastPathComponent().appendingPathComponent("temp_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let metaInf = tempDir.appendingPathComponent("META-INF")
            let oebps = tempDir.appendingPathComponent("OEBPS")
            let chapDir = oebps.appendingPathComponent("chapters")
            let imagesDir = oebps.appendingPathComponent("images")

            try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: chapDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

            // mimetype
            try "application/epub+zip".write(to: tempDir.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)

            // container.xml
            let container = """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                <rootfiles>
                    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                </rootfiles>
            </container>
            """
            try container.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

            var manifestItems = ""
            var spineItems = ""
            var navPoints = ""

            // Write cover image if present
            if let coverData = coverImageData {
                let coverPath = imagesDir.appendingPathComponent("cover.jpg")
                try coverData.write(to: coverPath)
                manifestItems += "<item id=\"cover-image\" href=\"images/cover.jpg\" media-type=\"image/jpeg\" properties=\"cover-image\"/>\n"
            }

            for (idx, item) in chapters.enumerated() {
                let id = "ch\(idx + 1)"
                let file = "ch\(idx + 1).xhtml"
                let html = """
                <?xml version="1.0" encoding="utf-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml">
                <head><title>\(item.0)</title></head>
                <body>\(item.1)</body>
                </html>
                """
                try html.write(to: chapDir.appendingPathComponent(file), atomically: true, encoding: .utf8)

                manifestItems += "<item id=\"\(id)\" href=\"chapters/\(file)\" media-type=\"application/xhtml+xml\"/>\n"
                spineItems += "<itemref idref=\"\(id)\"/>\n"
                navPoints += """
                <navPoint id="np\(idx + 1)" playOrder="\(idx + 1)">
                    <navLabel><text>\(item.0)</text></navLabel>
                    <content src="chapters/\(file)"/>
                </navPoint>
                """
            }

            // toc.ncx
            let ncx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
                <head><meta name="dtb:uid" content="urn:uuid:\(bookId)"/></head>
                <docTitle><text>\(title)</text></docTitle>
                <navMap>\(navPoints)</navMap>
            </ncx>
            """
            try ncx.write(to: oebps.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

            // content.opf
            let coverMeta = coverImageData != nil ? "<meta name=\"cover\" content=\"cover-image\"/>" : ""
            let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:title>\(title)</dc:title>
                    <dc:creator>\(author)</dc:creator>
                    <dc:language>zh</dc:language>
                    <dc:description>\(description)</dc:description>
                    <dc:identifier id="BookID">urn:uuid:\(bookId)</dc:identifier>
                    \(coverMeta)
                </metadata>
                <manifest>
                    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                    \(manifestItems)
                </manifest>
                <spine toc="ncx">
                    \(spineItems)
                </spine>
            </package>
            """
            try opf.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

            // zip
            let p1 = Process()
            p1.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p1.currentDirectoryURL = tempDir
            p1.arguments = ["-q", "-0", "-X", targetURL.path, "mimetype"]
            try p1.run()
            p1.waitUntilExit()

            let p2 = Process()
            p2.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p2.currentDirectoryURL = tempDir
            p2.arguments = ["-q", "-r", "-9", targetURL.path, "META-INF", "OEBPS"]
            try p2.run()
            p2.waitUntilExit()

            if FileManager.default.fileExists(atPath: targetURL.path) {
                return targetURL
            }
        } catch {
            print("Failed to build EPUB \(title): \(error)")
        }
        return nil
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let hexClean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hexClean).scanHexInt64(&int)
        let r, g, b: CGFloat
        switch hexClean.count {
        case 6:
            r = CGFloat((int >> 16) & 0xFF) / 255.0
            g = CGFloat((int >> 8) & 0xFF) / 255.0
            b = CGFloat(int & 0xFF) / 255.0
        default:
            r = 0.5; g = 0.5; b = 0.5
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
