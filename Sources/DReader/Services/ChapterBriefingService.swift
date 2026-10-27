import Foundation

/// Model for smart pre-reading chapter briefing
struct ChapterBriefing: Codable, Sendable {
    var chapterTitle: String
    var overview: String                // ~100 words core summary
    var backgroundPoints: [String]      // 3 key historical / conceptual bullet points
    var socraticQuestions: [String]     // 1-2 deep philosophical reflection questions

    init(
        chapterTitle: String,
        overview: String,
        backgroundPoints: [String],
        socraticQuestions: [String]
    ) {
        self.chapterTitle = chapterTitle
        self.overview = overview
        self.backgroundPoints = backgroundPoints
        self.socraticQuestions = socraticQuestions
    }
}

/// Service that provides chapter briefings and Socratic reflection questions
final class ChapterBriefingService: Sendable {
    static let shared = ChapterBriefingService()

    private init() {}

    /// Gets or synthesizes a briefing for the given chapter of a book
    func getBriefing(bookTitle: String, chapterTitle: String, chapterIndex: Int, plainText: String = "") -> ChapterBriefing {
        // 1. Classical curated briefings for Walden
        if bookTitle.contains("瓦尔登湖") || bookTitle.localizedCaseInsensitiveContains("Walden") {
            if let curated = waldenBriefings[chapterIndex] ?? waldenBriefingByTitle(chapterTitle) {
                return curated
            }
        }

        // 2. Classical curated briefings for The Little Prince
        if bookTitle.contains("小王子") || bookTitle.localizedCaseInsensitiveContains("Little Prince") {
            if let curated = littlePrinceBriefings[chapterIndex] ?? littlePrinceBriefingByTitle(chapterTitle) {
                return curated
            }
        }

        // 3. Classical curated briefings for Lu Xun
        if bookTitle.contains("呐喊") || bookTitle.contains("阿Q") {
            if let curated = luXunBriefings[chapterIndex] ?? luXunBriefingByTitle(chapterTitle) {
                return curated
            }
        }

        // 4. Dynamic heuristic briefing for any custom imported EPUB
        return generateDynamicBriefing(chapterTitle: chapterTitle, chapterIndex: chapterIndex, plainText: plainText)
    }

    // MARK: - Curated Walden Briefings
    private var waldenBriefings: [Int: ChapterBriefing] {
        [
            0: ChapterBriefing(
                chapterTitle: "第一章 经济篇",
                overview: "梭罗奠定全书哲学基调的最长篇章。他以精确的账本明细计算自己的建房与生存开销，向康科德镇以及整个现代资本主义社会的物质消费主义发起猛烈抨击。他认为人为了追求多余的物质，出卖了本不可替代的生命时间，最终陷入‘平静的绝望’之中。",
                backgroundPoints: [
                    "先验主义背景：爱默生与梭罗提倡‘自立’（Self-Reliance），试图打破教会与工业革命对人性的异化。",
                    "历史坐标：1845年美国正经历第一次工业革命与西进运动，人们沉迷于铁路股票、华服与商业扩张。",
                    "生命经济学：梭罗重新定义‘生活必需品’为四要素：食物、衣服、住所与燃料，其余皆为虚荣累赘。"
                ],
                socraticQuestions: [
                    "梭罗说‘大多数人生活在平静的绝望中’。在我们今天高度内卷与消费主义的时代，你认为这种绝望是减轻了还是加剧了？你工作是为了生活，还是生活已被工作吞噬？",
                    "如果用梭罗的‘生命时间成本法’来衡量你拥有的某件奢侈品或数字资产，你觉得换取它的生命时间真的值得吗？"
                ]
            ),
            1: ChapterBriefing(
                chapterTitle: "第二章 我生活的地方；我为何生活",
                overview: "全书文采最为激荡、哲思最凝练的篇章。梭罗深情描绘了清晨瓦尔登湖畔的晨雾与破晓，宣告他隐居的根本目的是为了‘从容地生活’，去吮吸生命的全部骨髓，免得在死时发现自己从未真正活过。",
                backgroundPoints: [
                    "晨曦象征：梭罗认为精神的早晨是道德重生的契机，‘唯有清醒的时刻才是真正的拂晓’。",
                    "铁路隐喻：‘我们没有乘坐铁路，铁路乘坐了我们。’ 梭罗借横跨树林的新铁路线，反思技术对人性的奴役。",
                    "神性隐居：小木屋没有锁，门窗洞开，人与自然的风声、飞鸟融为一体。"
                ],
                socraticQuestions: [
                    "梭罗说‘技术只是改善了手段，却未改善目标’。在如今 AI 与智能手机无孔不入的当下，我们是否正在变成被算法驾驭的‘被乘坐者’？",
                    "如果你能拥有一个不受干扰的‘早晨’，你最想用它来唤醒自己内心深处的什么灵性？"
                ]
            ),
            2: ChapterBriefing(
                chapterTitle: "第三章 阅读篇",
                overview: "探讨经典的永恒价值。梭罗把阅读古希腊、古罗马与东方哲学原典比作最高贵的心灵操练，严厉批评当时世俗读者沉溺于毫无营养的通俗小报与廉价罗曼史，呼吁人们用敬畏之心与人类历史上最伟大的灵魂对谈。",
                backgroundPoints: [
                    "古典语汇：梭罗在小木屋中随身携带《荷马史诗》古希腊文原版与印度《奥义书》。",
                    "母语与灵语：他区分了日常喧哗的口头‘母语’与需要严谨研习的写作者‘成熟语言’（Written Language）。",
                    "精神贵族：真正的富足不是拥有金钱，而是小镇市民能够以古典英雄的宏阔心胸来思考世界。"
                ],
                socraticQuestions: [
                    "在短视频与碎片化信息狂轰滥炸的今天，深度阅读大部头经典是否正在退化为一种稀缺的‘濒危能力’？",
                    "读一本经得起千年淘洗的好书，给你带来的认知震颤与随手刷取的热点信息有何本质不同？"
                ]
            )
        ]
    }

    private func waldenBriefingByTitle(_ title: String) -> ChapterBriefing? {
        if title.contains("经济") { return waldenBriefings[0] }
        if title.contains("我生活的地方") || title.contains("我为何生活") { return waldenBriefings[1] }
        if title.contains("阅读") { return waldenBriefings[2] }
        return nil
    }

    // MARK: - Curated Little Prince Briefings
    private var littlePrinceBriefings: [Int: ChapterBriefing] {
        [
            0: ChapterBriefing(
                chapterTitle: "第一章 蟒蛇吞象",
                overview: "以儿童视角画出的‘吞了象的蟒蛇’拉开序幕。成年人却固执地认为这只是一顶平平无奇的棕色帽子。圣埃克苏佩里以幽默而辛酸的笔触，揭示了成年人世界想象力的退化、对数字量化的执念与精神平庸。",
                backgroundPoints: [
                    "二战流亡背景：圣埃克苏佩里流亡纽约期间创作此书，对被战争与机械理性碾压的现代文明深感悲悯。",
                    "量化执念：大人唯有听到‘这房子值十万法郎’才会惊呼‘多么漂亮的房子’，看不见玫瑰与飞鸟。",
                    "童年救赎：献给‘还是个小男孩时的莱昂·韦尔特’，呼唤找回被遗忘的本心。"
                ],
                socraticQuestions: [
                    "你还记得自己小时候某个不被成年人理解的狂野构想吗？我们在成长的过程中，究竟付出了多少‘童真与想象’作为进入成人世界的代价？"
                ]
            ),
            4: ChapterBriefing(
                chapterTitle: "第二十一章 麦浪与驯服",
                overview: "《小王子》全书最高潮与精神圣殿。小王子在地球苹果树下遇到了狐狸。狐狸向他揭示了‘驯服’（Apprivoiser）的真谛：在千万人中建立羁绊，使彼此成为唯一的守望。正是你为玫瑰花费的时间，让你的玫瑰变得独一无二。",
                backgroundPoints: [
                    "‘驯服’的法语原义：建立彼此需要、彼此信任的特殊爱与责任关系，而非居高临下的掌控。",
                    "心之双眼：狐狸的秘密是法国文学史上最耀眼的哲理：‘实质性的东西，用眼睛是看不见的。’",
                    "金黄麦浪：即使离别，看到金黄色的麦田便会想起金发的小王子。爱的本质超越了占有本身。"
                ],
                socraticQuestions: [
                    "你生命中是否也曾有一朵‘耗费了你无数时间、虽带刺却独一无二的玫瑰’？在快餐式社交的今天，我们是否还有耐心去‘驯服’与‘被驯服’？",
                    "狐狸说‘你必须对你驯服过的东西永远负责’。在你的理解中，这种承诺是甜蜜的依靠还是沉重的枷锁？"
                ]
            )
        ]
    }

    private func littlePrinceBriefingByTitle(_ title: String) -> ChapterBriefing? {
        if title.contains("蟒蛇") || title.contains("帽子") { return littlePrinceBriefings[0] }
        if title.contains("狐狸") || title.contains("驯服") { return littlePrinceBriefings[4] }
        return nil
    }

    // MARK: - Curated Lu Xun Briefings
    private var luXunBriefings: [Int: ChapterBriefing] {
        [
            0: ChapterBriefing(
                chapterTitle: "阿Q正传 · 序",
                overview: "鲁迅以史家笔法反讽作序，探讨为何难以给阿Q立传：阿Q无姓氏、无籍贯、无生辰，因为阿Q并不是具体的单个人物，而是旧中国千千万万处于专制统治下麻木、奴化、精神变形的底层灵魂总写照。",
                backgroundPoints: [
                    "时代背景：发表于1921年《晨报副刊》，当时五四运动刚过，新文化运动正深刻反思国民劣根性。",
                    "正史体例的解构：仿效二十四史‘列传’体，却冠以卑微底层无名游民，反讽宗法士大夫虚伪的谱牒文化。",
                    "文学使命：‘画出沉默的国民的魂灵来’，使人警醒，促人思索治疗与觉醒之方。"
                ],
                socraticQuestions: [
                    "阿Q没有名字和固定身份，鲁迅意在说明每个人身上或多或少都潜藏着‘阿Q的影子’。在今天的生活或网络互动中，你何时察觉到过阿Q式的心理机制？"
                ]
            )
        ]
    }

    private func luXunBriefingByTitle(_ title: String) -> ChapterBriefing? {
        if title.contains("序") { return luXunBriefings[0] }
        return nil
    }

    // MARK: - Dynamic Synthesis for Imported EPUBs
    private func generateDynamicBriefing(chapterTitle: String, chapterIndex: Int, plainText: String) -> ChapterBriefing {
        let title = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.isEmpty ? "第 \(chapterIndex + 1) 章" : title

        let snippet = String(plainText.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        let overview = snippet.isEmpty
            ? "本章承接上文脉络，展开核心主旨的深度论述与情节演进。读者可重点把握作者所构建的逻辑框架与时代情境。"
            : "本章开篇阐述：“\(snippet)……”，展开了对于相关核心议题的细致剖析与探索。"

        return ChapterBriefing(
            chapterTitle: displayTitle,
            overview: overview,
            backgroundPoints: [
                "核心线索：围绕《\(displayTitle)》展开叙述与思辨展开，具有承前启后的结构作用。",
                "阅读建议：关注段落间所运用的关键论据、意象隐喻与修辞转折。",
                "时代语境：结合该作品的创作年代与作者思想流派，体会字里行间的潜台词。"
            ],
            socraticQuestions: [
                "作者在《\(displayTitle)》中所持有的核心前设与主张，在当今现实社会情境中是否依然成立？如果站在对立视角，你将如何提出质询？",
                "本章的内容对你个人的认知模型、生活方式或价值判断带来了怎样的新启迪？"
            ]
        )
    }
}
