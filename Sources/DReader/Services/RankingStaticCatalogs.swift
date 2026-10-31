//
//  RankingStaticCatalogs.swift
//  DReader
//
//  榜单目录注册表 + 国际奖项书单（诺贝尔文学奖/布克奖/普利策小说奖）的内置静态数据。
//  照 ChineseClassicsRegistry 先例：数据以 Swift 字面量内嵌（dreader target 无 Bundle resources，
//  build-app.sh 也不拷 SwiftPM bundle）。gutenbergID 只填经核实确实存在的公版条目——
//  未核实的一律 nil，避免「加入书架」下到 404。
//

import Foundation

// MARK: - 目录注册表（数组顺序即左栏展示序）

enum RankingsRegistry {
    static let allCatalogs: [RankingCatalog] = [
        // 微信读书 · 直连（RankingService 在线拉取）
        RankingCatalog(id: "weread.rising", title: "飙升榜", subtitle: "网页直连 · 6h 刷新",
                       source: .weread, isLive: true, refreshInterval: 21_600, language: .zh),
        RankingCatalog(id: "weread.newbook", title: "新书榜", subtitle: "网页直连 · 6h 刷新",
                       source: .weread, isLive: true, refreshInterval: 21_600, language: .zh),
        RankingCatalog(id: "weread.all", title: "总榜", subtitle: "网页直连 · 6h 刷新",
                       source: .weread, isLive: true, refreshInterval: 21_600, language: .zh),
        // 榜单快照（内置静态数据）
        RankingCatalog(id: "douban.top250", title: "豆瓣 Top250", subtitle: "内置快照 · 仅浏览",
                       source: .douban, isLive: false, refreshInterval: nil, language: .zh),
        // 国际奖项（内置静态数据）
        RankingCatalog(id: "nobel.literature", title: "诺贝尔文学奖", subtitle: "1901 至今 · 精选",
                       source: .curated, isLive: false, refreshInterval: nil, language: .mixed),
        RankingCatalog(id: "booker.prize", title: "布克奖", subtitle: "1969 至今",
                       source: .curated, isLive: false, refreshInterval: nil, language: .en),
        RankingCatalog(id: "pulitzer.fiction", title: "普利策小说奖", subtitle: "1918 至今",
                       source: .curated, isLive: false, refreshInterval: nil, language: .en)
    ]

    /// catalogID → 静态书目（live 榜走 RankingService）
    static func staticBooks(catalogID: String) -> [RankingBook]? {
        switch catalogID {
        case "douban.top250": return doubanTop250
        case "nobel.literature": return nobelWorldClassics
        case "booker.prize": return bookerWinners
        case "pulitzer.fiction": return pulitzerFictionWinners
        default: return nil
        }
    }
}

// MARK: - 构造辅助

private func curatedBook(
    id: String, catalogID: String, rank: Int, title: String, author: String,
    year: String, language: RankingLanguage, honor: String, externalURL: URL?,
    gutenbergID: String?
) -> RankingBook {
    RankingBook(
        id: id, catalogID: catalogID, rank: rank, title: title, author: author,
        rating: nil, readersCount: nil, language: language,
        coverURL: gutenbergID.map { gid in
            URL(string: "https://www.gutenberg.org/cache/epub/\(gid)/pg\(gid).cover.medium.jpg")
        } ?? nil,
        summary: nil, year: year, externalURL: externalURL,
        wereadBookId: nil, gutenbergID: gutenbergID,
        honor: honor, tag: nil, tintColors: nil
    )
}

// MARK: - 诺贝尔文学奖 · 获奖作家精选

private let nobelLaureates: [(year: Int, laureate: String, work: String, gutenbergID: String?)] = [
    (1905, "亨利克·显克维支", "你往何处去", "2853"),
    (1912, "盖哈特·霍普特曼", "织工", nil),
    (1913, "泰戈尔", "吉檀迦利", "7164"),
    (1915, "罗曼·罗兰", "约翰·克利斯朵夫", nil),
    (1919, "卡尔·施皮特勒", "奥林匹斯的春天", nil),
    (1920, "克努特·哈姆生", "大地的成长", "10984"),
    (1921, "阿纳托尔·法朗士", "苔依丝", nil),
    (1924, "符瓦迪斯瓦夫·莱蒙特", "农民", nil),
    (1925, "萧伯纳", "皮格马利翁", "3825"),
    (1929, "托马斯·曼", "布登勃洛克一家", nil),
    (1930, "辛克莱·刘易斯", "巴比特", nil),
    (1932, "约翰·高尔斯华绥", "福尔赛世家", nil),
    (1933, "伊凡·蒲宁", "阿尔谢尼耶夫的一生", nil),
    (1934, "路易吉·皮兰德娄", "六个寻找剧作家的角色", nil),
    (1936, "尤金·奥尼尔", "天边外", nil),
    (1937, "罗杰·马丁·杜·加尔", "蒂博一家", nil),
    (1938, "赛珍珠", "大地", nil),
    (1946, "赫尔曼·黑塞", "荒原狼", nil),
    (1947, "安德烈·纪德", "窄门", nil),
    (1949, "威廉·福克纳", "喧哗与骚动", nil),
    (1952, "弗朗索瓦·莫里亚克", "蝮蛇结", nil),
    (1953, "温斯顿·丘吉尔", "第二次世界大战回忆录", nil),
    (1954, "欧内斯特·海明威", "老人与海", nil),
    (1956, "胡安·拉蒙·希梅内斯", "小银和我", nil),
    (1957, "阿尔贝·加缪", "局外人", nil),
    (1958, "鲍里斯·帕斯捷尔纳克", "日瓦戈医生", nil),
    (1961, "伊沃·安德里奇", "德里纳河上的桥", nil),
    (1962, "约翰·斯坦贝克", "愤怒的葡萄", nil),
    (1964, "让-保罗·萨特", "恶心", nil),
    (1965, "米哈伊尔·肖洛霍夫", "静静的顿河", nil),
    (1967, "米格尔·阿斯图里亚斯", "玉米人", nil),
    (1968, "川端康成", "雪国", nil),
    (1969, "塞缪尔·贝克特", "等待戈多", nil),
    (1970, "亚历山大·索尔仁尼琴", "伊凡·杰尼索维奇的一天", nil),
    (1973, "帕特里克·怀特", "人树", nil),
    (1976, "索尔·贝娄", "洪堡的礼物", nil),
    (1978, "艾萨克·巴希维斯·辛格", "卢布林的魔术师", nil),
    (1981, "埃利亚斯·卡内蒂", "迷惘", nil),
    (1982, "加西亚·马尔克斯", "百年孤独", nil),
    (1983, "威廉·戈尔丁", "蝇王", nil),
    (1985, "克洛德·西蒙", "弗兰德公路", nil),
    (1986, "沃莱·索因卡", "死亡与国王的侍从", nil),
    (1987, "约瑟夫·布罗茨基", "小于一", nil),
    (1988, "纳吉布·马哈福兹", "宫间街", nil),
    (1990, "奥克塔维奥·帕斯", "太阳石", nil),
    (1991, "纳丁·戈迪默", "七月的人民", nil),
    (1992, "德里克·沃尔科特", "奥梅罗斯", nil),
    (1993, "托妮·莫里森", "宠儿", nil),
    (1994, "大江健三郎", "个人的体验", nil),
    (1997, "达里奥·福", "一个无政府主义者的意外死亡", nil),
    (1998, "若泽·萨拉马戈", "失明症漫记", nil),
    (1999, "君特·格拉斯", "铁皮鼓", nil),
    (2000, "高行健", "灵山", nil),
    (2001, "V.S. 奈保尔", "大河湾", nil),
    (2002, "凯尔泰斯·伊姆雷", "无命运的人生", nil),
    (2003, "J.M. 库切", "耻", nil),
    (2004, "埃尔弗里德·耶利内克", "钢琴教师", nil),
    (2006, "奥尔罕·帕慕克", "我的名字叫红", nil),
    (2007, "多丽丝·莱辛", "金色笔记", nil),
    (2008, "勒克莱齐奥", "流浪的星星", nil),
    (2010, "马里奥·巴尔加斯·略萨", "城市与狗", nil),
    (2012, "莫言", "红高粱家族", nil),
    (2013, "爱丽丝·门罗", "逃离", nil),
    (2014, "帕特里克·莫迪亚诺", "暗铺街", nil),
    (2015, "斯韦特兰娜·阿列克谢耶维奇", "二手时间", nil),
    (2017, "石黑一雄", "长日将尽", nil),
    (2018, "奥尔加·托卡尔丘克", "云游", nil),
    (2022, "安妮·埃尔诺", "悠悠岁月", nil),
    (2024, "韩江", "素食者", nil)
]

/// 诺贝尔文学奖精选书目（按获奖年份排序）
let nobelWorldClassics: [RankingBook] = nobelLaureates.enumerated().map { idx, e in
    curatedBook(
        id: "curated:nobel-\(e.year)", catalogID: "nobel.literature", rank: idx + 1,
        title: e.work, author: e.laureate, year: String(e.year),
        language: .mixed, honor: "诺贝尔文学奖 \(e.year)",
        externalURL: URL(string: "https://www.nobelprize.org/prizes/literature/\(e.year)/"),
        gutenbergID: e.gutenbergID
    )
}

// MARK: - 布克奖（1969 年至今获奖名单）

private let bookerWinnersRaw: [(year: Int, title: String, author: String)] = [
    (1969, "Something to Answer For", "P. H. Newby"),
    (1970, "The Elected Member", "Bernice Rubens"),
    (1971, "In a Free State", "V. S. Naipaul"),
    (1972, "G.", "John Berger"),
    (1973, "The Siege of Krishnapur", "J. G. Farrell"),
    (1974, "The Conservationist", "Nadine Gordimer"),
    (1975, "Heat and Dust", "Ruth Prawer Jhabvala"),
    (1976, "Saville", "David Storey"),
    (1977, "Staying On", "Paul Scott"),
    (1978, "The Sea, The Sea", "Iris Murdoch"),
    (1979, "Offshore", "Penelope Fitzgerald"),
    (1980, "Rites of Passage", "William Golding"),
    (1981, "Midnight's Children", "Salman Rushdie"),
    (1982, "Schindler's Ark", "Thomas Keneally"),
    (1983, "The Life & Times of Michael K", "J. M. Coetzee"),
    (1984, "Hotel du Lac", "Anita Brookner"),
    (1985, "The Bone People", "Keri Hulme"),
    (1986, "The Old Devils", "Kingsley Amis"),
    (1987, "Moon Tiger", "Penelope Lively"),
    (1988, "Oscar and Lucinda", "Peter Carey"),
    (1989, "The Remains of the Day", "Kazuo Ishiguro"),
    (1990, "Possession", "A. S. Byatt"),
    (1991, "The Famished Road", "Ben Okri"),
    (1992, "The English Patient", "Michael Ondaatje"),
    (1992, "Sacred Hunger", "Barry Unsworth"),
    (1993, "Paddy Clarke Ha Ha Ha", "Roddy Doyle"),
    (1994, "How Late It Was, How Late", "James Kelman"),
    (1995, "The Ghost Road", "Pat Barker"),
    (1996, "Last Orders", "Graham Swift"),
    (1997, "The God of Small Things", "Arundhati Roy"),
    (1998, "Amsterdam", "Ian McEwan"),
    (1999, "Disgrace", "J. M. Coetzee"),
    (2000, "The Blind Assassin", "Margaret Atwood"),
    (2001, "True History of the Kelly Gang", "Peter Carey"),
    (2002, "Life of Pi", "Yann Martel"),
    (2003, "Vernon God Little", "DBC Pierre"),
    (2004, "The Line of Beauty", "Alan Hollinghurst"),
    (2005, "The Sea", "John Banville"),
    (2006, "The Inheritance of Loss", "Kiran Desai"),
    (2007, "The Gathering", "Anne Enright"),
    (2008, "The White Tiger", "Aravind Adiga"),
    (2009, "Wolf Hall", "Hilary Mantel"),
    (2010, "The Finkler Question", "Howard Jacobson"),
    (2011, "The Sense of an Ending", "Julian Barnes"),
    (2012, "Bring Up the Bodies", "Hilary Mantel"),
    (2013, "The Luminaries", "Eleanor Catton"),
    (2014, "The Narrow Road to the Deep North", "Richard Flanagan"),
    (2015, "A Brief History of Seven Killings", "Marlon James"),
    (2016, "The Sellout", "Paul Beatty"),
    (2017, "Flights", "Olga Tokarczuk"),
    (2018, "Milkman", "Anna Burns"),
    (2019, "Girl, Woman, Other", "Bernardine Evaristo"),
    (2020, "Shuggie Bain", "Douglas Stuart"),
    (2021, "The Promise", "Damon Galgut"),
    (2022, "The Seven Moons of Maali Almeida", "Shehan Karunatilaka"),
    (2023, "Prophet Song", "Paul Lynch"),
    (2024, "Orbital", "Samantha Harvey"),
    (2025, "Flesh", "David Szalay")
]

/// 布克奖获奖书单（按年份排序）
let bookerWinners: [RankingBook] = bookerWinnersRaw.enumerated().map { idx, e in
    let query = e.title
        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    return curatedBook(
        id: "curated:booker-\(e.year)-\(idx)", catalogID: "booker.prize", rank: idx + 1,
        title: e.title, author: e.author, year: String(e.year),
        language: .en, honor: "布克奖 \(e.year)",
        externalURL: URL(string: "https://thebookerprizes.com/search?query=\(query)"),
        gutenbergID: nil
    )
}

// MARK: - 普利策小说奖（1918 年设立以来获奖名单,跳过未授奖年份）

private let pulitzerWinnersRaw: [(year: Int, title: String, author: String, gutenbergID: String?)] = [
    (1918, "His Family", "Ernest Poole", "14396"),
    (1919, "The Magnificent Ambersons", "Booth Tarkington", "8867"),
    (1921, "The Age of Innocence", "Edith Wharton", "541"),
    (1922, "Alice Adams", "Booth Tarkington", nil),
    (1923, "One of Ours", "Willa Cather", "2369"),
    (1924, "So Big", "Edna Ferber", "61686"),
    (1925, "Arrowsmith", "Sinclair Lewis", nil),
    (1926, "Early Autumn", "Louis Bromfield", nil),
    (1928, "The Bridge of San Luis Rey", "Thornton Wilder", "69768"),
    (1929, "Scarlet Sister Mary", "Julia Peterkin", nil),
    (1930, "Years of Grace", "Margaret Ayer Barnes", nil),
    (1931, "The Store", "T. S. Stribling", nil),
    (1932, "The Good Earth", "Pearl S. Buck", nil),
    (1934, "Lamb in His Bosom", "Caroline Miller", nil),
    (1935, "Now in November", "Josephine Winslow Johnson", nil),
    (1936, "Honey in the Horn", "H. L. Davis", nil),
    (1937, "Gone with the Wind", "Margaret Mitchell", nil),
    (1938, "The Late George Apley", "John P. Marquand", nil),
    (1939, "The Yearling", "Marjorie Kinnan Rawlings", nil),
    (1940, "The Grapes of Wrath", "John Steinbeck", nil),
    (1942, "In This Our Life", "Ellen Glasgow", nil),
    (1943, "Dragon's Teeth", "Upton Sinclair", nil),
    (1945, "A Bell for Adano", "John Hersey", nil),
    (1947, "All the King's Men", "Robert Penn Warren", nil),
    (1948, "Tales of the South Pacific", "James A. Michener", nil),
    (1949, "Guard of Honor", "James Gould Cozzens", nil),
    (1950, "The Way West", "A. B. Guthrie Jr.", nil),
    (1951, "The Caine Mutiny", "Herman Wouk", nil),
    (1953, "The Old Man and the Sea", "Ernest Hemingway", nil),
    (1955, "A Fable", "William Faulkner", nil),
    (1956, "Andersonville", "MacKinlay Kantor", nil),
    (1958, "A Death in the Family", "James Agee", nil),
    (1959, "The Travels of Jaimie McPheeters", "Robert Lewis Taylor", nil),
    (1960, "Advise and Consent", "Allen Drury", nil),
    (1961, "The Edge of Sadness", "Edwin O'Connor", nil),
    (1962, "To Kill a Mockingbird", "Harper Lee", nil),
    (1963, "The Reivers", "William Faulkner", nil),
    (1965, "The Keepers of the House", "Shirley Ann Grau", nil),
    (1966, "The Fixer", "Bernard Malamud", nil),
    (1968, "The Confessions of Nat Turner", "William Styron", nil),
    (1969, "House Made of Dawn", "N. Scott Momaday", nil),
    (1971, "Angle of Repose", "Wallace Stegner", nil),
    (1972, "The Complete Stories of Flannery O'Connor", "Flannery O'Connor", nil),
    (1973, "The Optimist's Daughter", "Eudora Welty", nil),
    (1975, "The Killer Angels", "Michael Shaara", nil),
    (1976, "Humboldt's Gift", "Saul Bellow", nil),
    (1978, "Elbow Room", "James Alan McPherson", nil),
    (1979, "The Stories of John Cheever", "John Cheever", nil),
    (1980, "The Executioner's Song", "Norman Mailer", nil),
    (1981, "A Confederacy of Dunces", "John Kennedy Toole", nil),
    (1982, "Rabbit Is Rich", "John Updike", nil),
    (1983, "The Color Purple", "Alice Walker", nil),
    (1984, "Ironweed", "William Kennedy", nil),
    (1985, "Foreign Affairs", "Alison Lurie", nil),
    (1986, "Lonesome Dove", "Larry McMurtry", nil),
    (1987, "A Summons to Memphis", "Peter Taylor", nil),
    (1988, "Beloved", "Toni Morrison", nil),
    (1989, "Breathing Lessons", "Anne Tyler", nil),
    (1990, "The Mambo Kings Play Songs of Love", "Oscar Hijuelos", nil),
    (1991, "A Good Scent from a Strange Mountain", "Robert Olen Butler", nil),
    (1992, "A Thousand Acres", "Jane Smiley", nil),
    (1994, "The Shipping News", "Annie Proulx", nil),
    (1995, "The Stone Diaries", "Carol Shields", nil),
    (1996, "Independence Day", "Richard Ford", nil),
    (1997, "Martin Dressler", "Steven Millhauser", nil),
    (1998, "American Pastoral", "Philip Roth", nil),
    (1999, "The Hours", "Michael Cunningham", nil),
    (2000, "Interpreter of Maladies", "Jhumpa Lahiri", nil),
    (2001, "The Amazing Adventures of Kavalier & Clay", "Michael Chabon", nil),
    (2002, "Empire Falls", "Richard Russo", nil),
    (2003, "Middlesex", "Jeffrey Eugenides", nil),
    (2004, "The Known World", "Edward P. Jones", nil),
    (2005, "Gilead", "Marilynne Robinson", nil),
    (2006, "March", "Geraldine Brooks", nil),
    (2007, "The Road", "Cormac McCarthy", nil),
    (2008, "The Brief Wondrous Life of Oscar Wao", "Junot Diaz", nil),
    (2009, "Olive Kitteridge", "Elizabeth Strout", nil),
    (2010, "Tinkers", "Paul Harding", nil),
    (2011, "A Visit from the Goon Squad", "Jennifer Egan", nil),
    (2013, "The Orphan Master's Son", "Adam Johnson", nil),
    (2014, "The Goldfinch", "Donna Tartt", nil),
    (2015, "All the Light We Cannot See", "Anthony Doerr", nil),
    (2016, "The Sympathizer", "Viet Thanh Nguyen", nil),
    (2017, "The Underground Railroad", "Colson Whitehead", nil),
    (2018, "Less", "Andrew Sean Greer", nil),
    (2019, "The Overstory", "Richard Powers", nil),
    (2020, "The Nickel Boys", "Colson Whitehead", nil),
    (2021, "The Night Watchman", "Louise Erdrich", nil),
    (2022, "The Netanyahus", "Joshua Cohen", nil),
    (2023, "Demon Copperhead", "Barbara Kingsolver", nil),
    (2023, "Trust", "Hernan Diaz", nil),
    (2024, "Night Watch", "Jayne Anne Phillips", nil)
]

/// 普利策小说奖获奖书单（按年份排序）
let pulitzerFictionWinners: [RankingBook] = pulitzerWinnersRaw.enumerated().map { idx, e in
    curatedBook(
        id: "curated:pulitzer-\(e.year)-\(idx)", catalogID: "pulitzer.fiction", rank: idx + 1,
        title: e.title, author: e.author, year: String(e.year),
        language: .en, honor: "普利策小说奖 \(e.year)",
        externalURL: URL(string: "https://www.pulitzer.org/prizes/fiction/\(e.year)"),
        gutenbergID: e.gutenbergID
    )
}
