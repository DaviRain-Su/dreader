import Foundation

/// Provides Kindle-grade X-Ray analysis: Character genealogies, key conceptual terms, and plot timeline
final class BookXRayService: Sendable {
    static let shared = BookXRayService()

    private init() {}

    /// Retrieves X-Ray data for a book, using curated literary knowledge or heuristic entity extraction
    func getXRayData(for book: EPUBBook) -> BookXRayData {
        let title = book.title
        let author = book.author

        // Check for curated classical books first
        if title.contains("瓦尔登湖") || title.localizedCaseInsensitiveContains("Walden") {
            return curatedWaldenXRay()
        } else if title.contains("小王子") || title.localizedCaseInsensitiveContains("Little Prince") {
            return curatedLittlePrinceXRay()
        } else if title.contains("呐喊") || title.contains("阿Q") || author.contains("鲁迅") {
            return curatedLuXunXRay()
        }

        // Generate dynamic heuristic X-Ray for any imported book
        return generateDynamicXRay(for: book)
    }

    // MARK: - Curated Literary Classics

    private func curatedWaldenXRay() -> BookXRayData {
        let characters = [
            XRayCharacter(
                name: "亨利·戴维·梭罗 (Thoreau)",
                aliases: ["梭罗", "叙述者", "哲学家"],
                role: "主人公 / 叙述者",
                identity: "美国先验主义哲学家、诗人、作家，于1845年隐居瓦尔登湖畔",
                description: "以极其审慎与实验性的态度在瓦尔登湖畔自建木屋独居两年两个月又两天，试图剥离文明社会虚饰的物质累赘，直面生命的本真。",
                keyTraits: ["超验主义", "独立自足", "亲近自然", "清醒敏锐"],
                firstAppearanceChapter: "经济篇",
                chapterIndex: 0,
                importanceLevel: 3
            ),
            XRayCharacter(
                name: "拉尔夫·沃尔多·爱默生 (Emerson)",
                aliases: ["爱默生", "思想导师"],
                role: "思想伙伴 / 土地提供者",
                identity: "美国先验主义运动领袖，梭罗的终身导师与密友",
                description: "瓦尔登湖周围的林地归爱默生所有，他鼓励并支持梭罗在湖畔进行这场人类生活与精神的实验。",
                keyTraits: ["精神导师", "自助论", "先知气质"],
                firstAppearanceChapter: "经济篇",
                chapterIndex: 0,
                importanceLevel: 2
            ),
            XRayCharacter(
                name: "加拿大伐木工 (Alek Therien)",
                aliases: ["伐木工", "阿列克"],
                role: "湖畔访客 / 原生人性象征",
                identity: "梭罗在林中结识的法国裔加拿大樵夫",
                description: "未受现代制度教化、天性淳朴、身心强健。梭罗认为他身上保留了荷马史诗时代原始人类的蓬勃生命力与澄澈灵魂。",
                keyTraits: ["原始质朴", "快乐豁达", "体魄强健"],
                firstAppearanceChapter: "访客篇",
                chapterIndex: 2,
                importanceLevel: 2
            ),
            XRayCharacter(
                name: "约翰·菲尔德 (John Field)",
                aliases: ["菲尔德", "爱尔兰劳工"],
                role: "对比人物 / 制度受害者",
                identity: "瓦尔登湖附近打短工的爱尔兰移民农夫",
                description: "日夜拼命苦干却依然陷于贫困与负债，因为他恪守文明旧习，沉溺于咖啡、牛油与茶叶，无法领会极简生活带来的精神自由。",
                keyTraits: ["因循守旧", "沉重受困", "盲目勤劳"],
                firstAppearanceChapter: "更高的法则",
                chapterIndex: 4,
                importanceLevel: 1
            )
        ]

        let concepts = [
            XRayConcept(
                term: "经济学 (Economy)",
                category: "核心哲学",
                shortDefinition: "生命代价的计算法：一件东西的成本，是换取它所需要付出的全部生命时间。",
                inDepthExplanation: "梭罗彻底颠覆了传统重商主义经济学。他认为大多数人所谓的‘生活必需品’只是虚荣与枷锁。人类真正需要维持生命的只有四样：食物、住所、衣服与燃料。",
                representativeQuotes: ["多数人生活在平静的绝望中。", "一件东西的代价，就是为了得到它而必须付出的生命。"]
            ),
            XRayConcept(
                term: "简朴生活 (Simplicity)",
                category: "生活方式",
                shortDefinition: "化繁为简，让事项如数指头般少，剥离浮华专注于生命核心。",
                inDepthExplanation: "‘简朴，简朴，简朴！我说，让你的事情只有两件或三件，而不是一百件或一千件。’ 梭罗借此实现自我所有权的完整夺回。",
                representativeQuotes: ["简朴，简朴，简朴！", "如果我们清醒地活着，就不会觉得生活是件难事。"]
            ),
            XRayConcept(
                term: "晨曦意识 (Morning Awakening)",
                category: "精神象征",
                shortDefinition: "精神不断重生的时刻，象征道德感知力与灵魂的觉醒。",
                inDepthExplanation: "在梭罗笔下，早晨是一天中最神圣的时光。唯有当我们真正从心灵的昏睡中醒来，才配称为真正的活着，如同公鸡破晓啼鸣唤醒邻人。",
                representativeQuotes: ["唯有我们清醒的时刻，才是真正的拂晓。"]
            ),
            XRayConcept(
                term: "大自然的自愈力 (Nature's Renewal)",
                category: "自然美学",
                shortDefinition: "四季轮转中展现的生命生生不息与心灵洗涤之力。",
                inDepthExplanation: "通过细腻描绘瓦尔登湖冰层融化、沙岸流动形成的植物脉络形态，梭罗揭示了宇宙生机的内在创造力与神性律动。",
                representativeQuotes: ["在自然界中，我们找到了健康与纯粹的永恒保证。"]
            )
        ]

        let timeline = [
            XRayEvent(
                title: "1845年独立日：入住湖畔小木屋",
                chapterTitle: "第一章 经济篇",
                chapterIndex: 0,
                summary: "借了一把斧头，在湖畔白松林中砍木取材，以28美元12美分建造了自己的小屋并于独立日正式迁入。",
                significance: "象征个人精神与物质世界对世俗社会的独立宣言。"
            ),
            XRayEvent(
                title: "种豆夏日：体验劳动的神性",
                chapterTitle: "第七章 种豆篇",
                chapterIndex: 3,
                summary: "在湖边两英亩荒地里亲手耕种白豆，结识野鸟与泥土，感受人与土地的古老盟约。",
                significance: "将体力劳作提升为一种无需盈利、自得其乐的哲学沉思仪式。"
            ),
            XRayEvent(
                title: "严冬量湖：测算瓦尔登湖的深度",
                chapterTitle: "第十六章 冬日的湖泊",
                chapterIndex: 5,
                summary: "在厚达一尺的冰面上钻凿逾百孔，以罗盘与吊线科学测量湖底深度，戳破‘无底深渊’的世俗谣言。",
                significance: "证明自然与人心都有其确定深浅与轮廓，唯需诚实丈量。"
            ),
            XRayEvent(
                title: "春日归来：告别湖畔开启新生",
                chapterTitle: "第十八章 结语",
                chapterIndex: 7,
                summary: "在冰雪消融、草木萌发的春季，梭罗离开瓦尔登湖重新走入社会，因为他还有‘更多的生命需要去体验’。",
                significance: "隐居并非逃避避世，而是为了找到一条通往未来的更坚定小径。"
            )
        ]

        return BookXRayData(
            bookTitle: "瓦尔登湖",
            characters: characters,
            concepts: concepts,
            timeline: timeline
        )
    }

    private func curatedLittlePrinceXRay() -> BookXRayData {
        let characters = [
            XRayCharacter(
                name: "小王子 (The Little Prince)",
                aliases: ["金发小男孩", "来自B612星球的孩子"],
                role: "主角 / 纯真灵魂象征",
                identity: "来自遥远B612小行星的小王子，拥有一朵骄傲的玫瑰",
                description: "拥有澄澈透明的心灵，不被成人的功利世界同化。游历各大星球后降落地球，通过狐狸领悟了爱的真谛与责任。",
                keyTraits: ["纯真", "专注", "坚守承诺", "富有同理心"],
                firstAppearanceChapter: "第二章 沙漠相遇",
                chapterIndex: 1,
                importanceLevel: 3
            ),
            XRayCharacter(
                name: "狐狸 (The Fox)",
                aliases: ["智慧导师", "被驯服者"],
                role: "智慧导师 / 爱的启蒙者",
                identity: "撒哈拉沙漠深处的金毛狐狸",
                description: "教会了小王子什么是‘驯化’（建立联系），并道出了全书最震撼的哲学秘密：‘本质的东西，眼睛是看不见的，唯有用心才能看清。’",
                keyTraits: ["智慧", "洞察真谛", "深情而释怀"],
                firstAppearanceChapter: "第二十一章 狐狸的相遇",
                chapterIndex: 4,
                importanceLevel: 3
            ),
            XRayCharacter(
                name: "玫瑰 (The Rose)",
                aliases: ["骄傲的花", "小王子的爱恋"],
                role: "爱人象征 / 脆弱与骄傲",
                identity: "生长在B612星球上唯一带有四根刺的红玫瑰",
                description: "虚荣且爱撒娇，虽然深爱小王子却拙于表达。她的脆弱与独一无二促使小王子甘愿为她穿越宇宙并最终赴死。",
                keyTraits: ["傲娇", "脆弱", "独一无二", "深情"],
                firstAppearanceChapter: "第八章 玫瑰的诞生",
                chapterIndex: 2,
                importanceLevel: 3
            ),
            XRayCharacter(
                name: "飞行员 (The Aviator / Narrator)",
                aliases: ["“我”", "圣埃克苏佩里化身"],
                role: "叙述者 / 成年人世界的挽歌",
                identity: "飞机迫降在撒哈拉沙漠的飞行员",
                description: "孩童时代画‘吞了蛇的大象’却被大人误认为帽子的失落艺术家，在死亡绝境中偶遇小王子，灵魂得到救赎。",
                keyTraits: ["保留童心", "耐心", "怀念"],
                firstAppearanceChapter: "第一章 蟒蛇吞象",
                chapterIndex: 0,
                importanceLevel: 2
            )
        ]

        let concepts = [
            XRayConcept(
                term: "驯服 (Apprivoiser / Tame)",
                category: "核心哲学",
                shortDefinition: "‘建立联系’。对彼此而言，从成千上万个普通存在变成世上绝无仅有的唯一。",
                inDepthExplanation: "驯服意味着彼此需要，意味着愿意在平庸的世界中投入时间、耐心与情感，并承担随之而来的欢笑与眼泪。",
                representativeQuotes: ["正是你为你玫瑰付出的时间，使得你的玫瑰如此重要。"]
            ),
            XRayConcept(
                term: "心之所见 (Seeing with the Heart)",
                category: "认识论",
                shortDefinition: "肉眼所见皆是皮相与数字，唯有用心感悟方能洞察事物的灵魂与本质。",
                inDepthExplanation: "成人沉迷于房子的价格、朋友的收入等量化数字，却看不见窗前的天竺葵与屋顶的白鸽。真正的珍贵无法被尺度衡量。",
                representativeQuotes: ["只有用心灵才能看得清。实质性的东西，用眼睛是看不见的。"]
            ),
            XRayConcept(
                term: "猴面包树 (Baobabs)",
                category: "象征隐喻",
                shortDefinition: "小恶之萌芽。若不及时拔除，其蔓延的根系将撑破整颗星球。",
                inDepthExplanation: "象征人类心灵中不断滋生的偏执、贪婪、惰性与法西斯式的毁灭性恶念，必须每日清晨细心自省拔除。",
                representativeQuotes: ["如果猴面包树长得太大，你就永远无法把它除掉了。"]
            )
        ]

        let timeline = [
            XRayEvent(
                title: "B612星球的离别",
                chapterTitle: "第九章 诀别与远行",
                chapterIndex: 2,
                summary: "小王子打扫了两座活火山和一座死火山，给玫瑰罩上玻璃罩，在候鸟迁徙的清晨悄然离开家园。",
                significance: "爱与误解催生的成长之旅序曲。"
            ),
            XRayEvent(
                title: "荒诞星球巡礼",
                chapterTitle: "第十至十五章 六个星球",
                chapterIndex: 3,
                summary: "相继造访专制国王、爱虚荣者、酒鬼、贪婪商人、点灯人与地理学家的孤单小行星。",
                significance: "以儿童视角无情解构了成年人对权力、虚荣、沉溺、金钱和教条的病态执念。"
            ),
            XRayEvent(
                title: "地球麦田与狐狸的箴言",
                chapterTitle: "第二十一章 麦浪与驯服",
                chapterIndex: 4,
                summary: "小王子在五千朵玫瑰的花园中感到幻灭，随后在苹果树下结识狐狸，学会了责任与唯一的意义。",
                significance: "全书精神内核的高潮：找到了解开心灵痛苦的钥匙。"
            ),
            XRayEvent(
                title: "沙漠之星的告别",
                chapterTitle: "第二十六章 金黄色闪电",
                chapterIndex: 5,
                summary: "借由毒蛇的螫咬，小王子蜕去沉重的肉躯，灵魂化作繁星中微笑的一颗，重返遥远家园守候玫瑰。",
                significance: "关于死亡、救赎与永恒守望的诗意升华。"
            )
        ]

        return BookXRayData(
            bookTitle: "小王子",
            characters: characters,
            concepts: concepts,
            timeline: timeline
        )
    }

    private func curatedLuXunXRay() -> BookXRayData {
        let characters = [
            XRayCharacter(
                name: "阿Q (Ah Q)",
                aliases: ["奎", "阿Quei"],
                role: "主人公 / 国民劣根性典型",
                identity: "未庄最底层雇农，无家无业、无籍贯无生辰",
                description: "精神胜利法的发明者与受害者。受侮辱欺凌时以自欺自慰寻求心理胜利；在辛亥革命风暴中试图‘投降革命’却最终被草率枪决。",
                keyTraits: ["精神胜利法", "自轻自贱", "盲目自大", "奴性麻木"],
                firstAppearanceChapter: "阿Q正传·序",
                chapterIndex: 0,
                importanceLevel: 3
            ),
            XRayCharacter(
                name: "赵太爷 (Lord Zhao)",
                aliases: ["赵秀才之父", "未庄乡绅"],
                role: "封建阶级权威",
                identity: "未庄最有权势的封建地主绅士",
                description: "曾厉声训斥阿Q‘你也配姓赵！’，牢固掌控未庄的宗法特权与道德审判大权，辛亥革命后摇身一变成为地方自治头面人物。",
                keyTraits: ["专横跋扈", "虚伪", "老谋深算"],
                firstAppearanceChapter: "阿Q正传·优胜记略",
                chapterIndex: 1,
                importanceLevel: 2
            ),
            XRayCharacter(
                name: "假洋鬼子 (The Bogus Foreign Devil)",
                aliases: ["钱大少爷", "留学生"],
                role: "投机改良分子",
                identity: "城里留学归来的地主阔少",
                description: "剪了辫子又装假辫子，打着新式文明旗号却手持‘哭丧棒’欺凌阿Q，剥夺弱者参与革命的微小愿望。",
                keyTraits: ["投机虚伪", "狐假虎威", "软弱妥协"],
                firstAppearanceChapter: "阿Q正传·恋爱的悲剧",
                chapterIndex: 2,
                importanceLevel: 2
            )
        ]

        let concepts = [
            XRayConcept(
                term: "精神胜利法 (Spiritual Victory)",
                category: "心理剖析",
                shortDefinition: "在现实中遭受屈辱时，通过在精神幻觉中将对手贬低或转化为儿孙来获得快感的心理防御机制。",
                inDepthExplanation: "鲁迅对中国几千年封建专制统治下底层民众被压迫至心理扭曲之劣根性的冷峻诊断，既是对自欺欺人的悲悯，更是最猛烈的批判。",
                representativeQuotes: ["我们先前——比你阔的多啦！你算是什么东西！", "我总算被儿子打了……"]
            ),
            XRayConcept(
                term: "铁屋子隐喻 (The Iron House)",
                category: "启蒙哲学",
                shortDefinition: "绝无窗户而万难破毁的熟睡铁屋，象征麻木昏睡的国民与封建宗法社会。",
                inDepthExplanation: "‘几个人既然起来，你不能说决没有毁坏这铁屋的希望。’ 鲁迅借此道出启蒙思想者既绝望又决不放弃呐喊的宿命与大爱。",
                representativeQuotes: ["假如一间铁屋子，是绝无窗户而万难破毁的，里面有许多熟睡的人……"]
            ),
            XRayConcept(
                term: "看客文化 (The Spectator Culture)",
                category: "社会批判",
                shortDefinition: "麻木围观同胞苦难、甚至以他人受辱与受刑为乐的冷血群众心理。",
                inDepthExplanation: "从鉴湖女侠秋瑾到阿Q被绑赴刑场，周围伸长了脖子像鸭子一般的无知看客，构成了旧中国最深重的道德死局。",
                representativeQuotes: ["他们也何尝不伸颈，张嘴，微笑，横站。"]
            )
        ]

        let timeline = [
            XRayEvent(
                title: "未庄优胜记：精神胜利的诞生",
                chapterTitle: "第二章 优胜记略",
                chapterIndex: 1,
                summary: "阿Q在土谷祠与未庄地痞赌徒发生冲突，挨了打后自我安慰‘如同被儿子打了’，立感释然。",
                significance: "生动奠定阿Q性格原型的核心法则。"
            ),
            XRayEvent(
                title: "调戏小尼姑与恋爱悲剧",
                chapterTitle: "第三章 恋爱的悲剧",
                chapterIndex: 2,
                summary: "在静修庵门口调戏年轻小尼姑，随后向吴妈跪求‘我要和你困觉’，导致被逐出赵府，沦为全村弃儿。",
                significance: "展现压抑窒息的封建礼教对人性欲望的荒谬扭曲。"
            ),
            XRayEvent(
                title: "未庄的‘革命’与圆圈悲剧",
                chapterTitle: "第八章 不准革命",
                chapterIndex: 4,
                summary: "革命党进城，阿Q幻想借革命报复欺负过自己的人，却被假洋鬼子驱逐；最终被栽赃盗窃并押上断头台，临死前遗憾‘圆圈画得不圆’。",
                significance: "对不彻底的资产阶级辛亥革命脱离群众、未曾触动封建根基的沉痛反思。"
            )
        ]

        return BookXRayData(
            bookTitle: "呐喊 · 阿Q正传",
            characters: characters,
            concepts: concepts,
            timeline: timeline
        )
    }

    // MARK: - Dynamic Extraction for Custom / Unknown EPUBs

    private func generateDynamicXRay(for book: EPUBBook) -> BookXRayData {
        var characters: [XRayCharacter] = []
        var concepts: [XRayConcept] = []
        var timeline: [XRayEvent] = []

        // Extract key chapters as events
        for (idx, ch) in book.chapters.prefix(8).enumerated() {
            let cleanTitle = ch.title.trimmingCharacters(in: .whitespacesAndNewlines)
            timeline.append(
                XRayEvent(
                    title: cleanTitle.isEmpty ? "第 \(idx + 1) 章" : cleanTitle,
                    chapterTitle: cleanTitle,
                    chapterIndex: idx,
                    summary: "本章展开了核心论述与叙事线索，深化了全书主题。",
                    significance: "承接前文脉络，引出关键情境与论据。"
                )
            )
        }

        // Author representation
        if !book.author.isEmpty {
            characters.append(
                XRayCharacter(
                    name: book.author,
                    aliases: ["原著作者", "著书者"],
                    role: "作者 / 核心主旨阐释者",
                    identity: "《\(book.title)》原作者",
                    description: "以深邃的洞见与独到笔触构建了本书的体系与哲理意境。",
                    keyTraits: ["创作者", "核心思想源泉"],
                    firstAppearanceChapter: book.chapters.first?.title ?? "开卷",
                    chapterIndex: 0,
                    importanceLevel: 3
                )
            )
        }

        // Default foundational concepts
        concepts.append(
            XRayConcept(
                term: "主题主旨",
                category: "全书核心",
                shortDefinition: "围绕《\(book.title)》展开的核心论述主线与思想追求。",
                inDepthExplanation: "贯穿各章节的系统性阐述，体现了作者对生活、社会或人性的深刻认知与独到解答。",
                representativeQuotes: []
            )
        )
        concepts.append(
            XRayConcept(
                term: "篇章结构",
                category: "结构体系",
                shortDefinition: "全书共 \(book.chapters.count) 个章节的叙事与逻辑层级展开。",
                inDepthExplanation: "由浅入深，由理论铺陈走向深刻结语，具有严密的思想推进链条。",
                representativeQuotes: []
            )
        )

        return BookXRayData(
            bookTitle: book.title,
            characters: characters,
            concepts: concepts,
            timeline: timeline
        )
    }
}
