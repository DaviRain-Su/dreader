import Foundation
import AppKit

/// Curated authentic text corpus and masterpiece EPUB builders for public domain Chinese literature
enum ClassicsMasterpieceCorpus {

    // MARK: - 1. 《红楼梦》传世典藏精校本
    static func buildHongLouMengEPUB(targetURL: URL) async -> URL? {
        let coverData = SampleBookGenerator.renderCoverImage(
            mainTitle: "红楼梦",
            subTitle: "脂砚斋重评石头记精校本",
            author: "［清］曹雪芹 著",
            badge: "中国古典小说巅峰之作 · 百科全书式典藏",
            colorHex1: "#3D171C",
            colorHex2: "#19080A",
            goldHex: "#E5A93C"
        )

        return await SampleBookGenerator.shared.buildEPUB(
            targetURL: targetURL,
            bookId: "classic-hongloumeng-masterpiece",
            title: "红楼梦 (脂砚斋重评精校典藏本)",
            author: "［清］曹雪芹",
            description: "中国古代长篇章回体小说天花板，四大名著之首。摹画大观园与荣宁二府兴衰，词采精绝，字字泣血。",
            coverImageData: coverData,
            chapters: hongLouMengChapters
        )
    }

    // MARK: - 2. 《三国演义》传世典藏精校本
    static func buildSanGuoYanYiEPUB(targetURL: URL) async -> URL? {
        let coverData = SampleBookGenerator.renderCoverImage(
            mainTitle: "三国演义",
            subTitle: "毛宗岗评本·通俗演义",
            author: "［元末明初］罗贯中 著",
            badge: "中国历史演义小说开山巅峰 · 传世善本",
            colorHex1: "#261914",
            colorHex2: "#0F0806",
            goldHex: "#D49B42"
        )

        return await SampleBookGenerator.shared.buildEPUB(
            targetURL: targetURL,
            bookId: "classic-sanguoyanyi-masterpiece",
            title: "三国演义 (毛宗岗评本精校典藏)",
            author: "［元末明初］罗贯中",
            description: "描写东汉末年至西晋初年近百年的历史风云，英雄辈出，智谋交锋，气吞山河。",
            coverImageData: coverData,
            chapters: sanGuoChapters
        )
    }

    // MARK: - 3. 《西游记》传世典藏精校本
    static func buildXiYouJiEPUB(targetURL: URL) async -> URL? {
        let coverData = SampleBookGenerator.renderCoverImage(
            mainTitle: "西游记",
            subTitle: "李卓吾批评本·长篇神魔史诗",
            author: "［明］吴承恩 著",
            badge: "中国浪漫主义神魔长篇巅峰 · 传世善本",
            colorHex1: "#2B1D38",
            colorHex2: "#110A18",
            goldHex: "#F2B84B"
        )

        return await SampleBookGenerator.shared.buildEPUB(
            targetURL: targetURL,
            bookId: "classic-xiyouji-masterpiece",
            title: "西游记 (李卓吾批评精校典藏)",
            author: "［明］吴承恩",
            description: "讲述唐僧师徒四人西天取经，历经九九八十一难，终成正果的恢弘奇幻史诗。",
            coverImageData: coverData,
            chapters: xiYouJiChapters
        )
    }

    // MARK: - 《红楼梦》正本章节内容
    private static var hongLouMengChapters: [(String, String)] {
        [
            ("第一回：甄士隐梦幻识通灵 贾雨村风尘怀闺秀", """
            <div class="classic-chapter-wrapper">
                <div class="classic-chapter-header">
                    <div class="classic-dynasty-badge">清 · 乾隆年间</div>
                    <h1 class="classic-chapter-title">第一回 甄士隐梦幻识通灵 贾雨村风尘怀闺秀</h1>
                    <div class="classic-author-line">曹雪芹 披阅十载 · 增删五次</div>
                    <div class="classic-ornament-divider">❦ ❦ ❦</div>
                </div>

                <div class="dreader-poem-block">
                    <p>满纸荒唐言，一把辛酸泪！</p>
                    <p>都云作者痴，谁解其中味？</p>
                </div>

                <p>此开卷第一回也。作者自云：因曾历过一番梦幻之后，故将真事隐去，而借“通灵”之说，撰此《石头记》一书也。故曰“甄士隐”云云。</p>
                <p>但书中所记何事何人？自又云：“今风尘碌碌，一事无成，忽念及当日所有之女子，一一细考较去，觉其行止见识，皆出于我之上。何我堂堂须眉，诚不若彼裙钗哉？实愧则有余，悔又无益之大无可如何之日也！</p>
                <p>当此，则自欲将已往所赖天恩祖德，锦衣纨绔之时，饫甘餍肥之日，背父兄教育之恩，负师友规谈之德，以至今日一技无成，半生潦倒之罪，编述一集，以告天下人：我之罪固不免，然闺阁中本自历历有人，万不可因我之不肖，自护己短，一并使其泯灭也。虽今日之茅椽蓬牖，瓦灶绳床，其晨夕风露，阶柳庭花，亦未有妨我之襟怀笔墨者。虽我未学，下笔无文，又何妨用假语村言，敷演出一段故事来，亦可使闺阁昭传，复可悦世之目，破人愁闷，不亦宜乎？”故曰“贾雨村”云云。</p>
                <p>原来女娲氏炼石补天之时，于大荒山无稽崖练成高经十二丈、方经二十四丈顽石三万六千五百零一块。娲皇氏只用了三万六千五百块，只单单剩了一块未用，便弃在此山青埂峰下。谁知此石自经锻炼之后，灵性已通，因见众石俱得补天，独自己无材不堪入选，遂自怨自叹，日夜悲号惭愧。</p>
                <p>一日，正当嗟悼之际，俄见一僧一道远远而来，生得骨骼不凡，丰神迥异，说说笑笑来至峰下，坐于石边高谈快论。先是说些云山雾海神仙玄幻之事，后便说到红尘中荣华富贵。此石听了，不觉打动凡心，也想要到人间去享一享这荣华富贵。</p>

                <div class="dreader-poem-block">
                    <p class="poem-title">【好了歌】</p>
                    <p>世人都晓神仙好，惟有功名忘不了！</p>
                    <p>古来将相在何方？荒冢一堆草没了。</p>
                    <p>世人都晓神仙好，只有金银忘不了！</p>
                    <p>终朝只恨聚无多，及到多时眼闭了。</p>
                    <p>世人都晓神仙好，只有娇妻忘不了！</p>
                    <p>君生日日说恩情，君死又随人去了。</p>
                    <p>世人都晓神仙好，只有儿孙忘不了！</p>
                    <p>痴心父母古来多，孝顺子孙谁见了？</p>
                </div>

                <div class="dreader-poem-block">
                    <p class="poem-title">【甄士隐解《好了歌》】</p>
                    <p>陋室空堂，当年笏满床；衰草枯杨，曾为歌舞场。</p>
                    <p>蛛丝儿结满雕梁，绿纱今又糊在蓬窗上。</p>
                    <p>说什么脂正浓、粉正香，如何两鬓又成霜？</p>
                    <p>昨日黄土陇头送白骨，今宵红灯帐底卧鸳鸯。</p>
                    <p>金满箱，银满箱，展眼乞丐人皆谤。</p>
                    <p>正叹他人命不长，那知自己归来丧！</p>
                    <p>训有方，保不定日后作强梁；择膏粱，谁承望流落在烟花巷！</p>
                    <p>因嫌纱帽小，致使锁枷扛；昨怜破袄寒，今嫌紫蟒长。</p>
                    <p>乱烘烘你方唱罢我登场，反认他乡是故乡。</p>
                    <p>甚荒唐，到头来都是为他人作嫁衣裳！</p>
                </div>
            </div>
            """),

            ("第二回：贾夫人仙逝扬州城 冷子兴演说荣国府", """
            <div class="classic-chapter-wrapper">
                <div class="classic-chapter-header">
                    <div class="classic-dynasty-badge">清 · 曹雪芹</div>
                    <h1 class="classic-chapter-title">第二回 贾夫人仙逝扬州城 冷子兴演说荣国府</h1>
                    <div class="classic-author-line">正邪两赋论 · 金陵世族脉络</div>
                    <div class="classic-ornament-divider">❦ ❦ ❦</div>
                </div>

                <p>一夕凉风，池沼荷香。雨村信步出城，偶至一村肆，正值古董商人冷子兴自都中来，二人把酒言欢，促膝长谈。</p>
                <p>雨村便问：“近日都中可有甚新事？”子兴笑道：“倒没有什么新事，唯有一家赫赫扬扬、名闻遐迩的荣国府，如今生了个衔玉而诞的神奇哥儿。”</p>
                <p>雨村听了，便道：“这倒罕见。此子如何性情？”子兴叹道：“此子生得面若中秋之月，色如春晓之花，鬓若刀裁，眉如墨画。周岁抓周时，抓了脂粉钗环，政老便道将来必是色鬼无疑！后来这哥儿常说出一句惊世骇俗的话来：‘女儿是水做的骨肉，男人是泥做的骨肉。我见了女儿，我便清爽；见了男子，便觉浊臭逼人！’你说荒唐不荒唐？”</p>
                <p>雨村敛容正色道：“非也！大仁者修治天下，大恶者扰乱天下。若夫大仁大恶之间，天地秀气与残忍乘戾之气相值相聚，则生异人。若生于公侯富贵之家，则为情痴情种；若生于诗书清贫之族，则为逸士高人；纵生于薄祚微贱之家，亦断不为奴犬附庸，必为奇优名倡！如许由、陶潜、阮籍、嵇康之流，皆是也。此贾政之子，恐亦是此类人耳。”</p>
                <p>二人谈古论今，历数宁荣二府世系，方知天下百年望族，生齿日繁，事务日盛，安富尊荣者尽多，运筹谋画者无一，其日暮穷途之象，已现端倪。</p>
            </div>
            """),

            ("第三回：金陵城起复贾雨村 荣国府收养林黛玉", """
            <div class="classic-chapter-wrapper">
                <div class="classic-chapter-header">
                    <div class="classic-dynasty-badge">清 · 曹雪芹</div>
                    <h1 class="classic-chapter-title">第三回 金陵城起复贾雨村 荣国府收养林黛玉</h1>
                    <div class="classic-author-line">凤姐登场 · 宝黛初会奇缘</div>
                    <div class="classic-ornament-divider">❦ ❦ ❦</div>
                </div>

                <p>却说林黛玉自幼丧母，体弱多病，其父林如海因思念幼女孤苦，托雨村护送进京，投奔外祖母荣国府。</p>
                <p>黛玉常听得母亲说，他外祖母家与别家不同。他今日到此，步步留心，时时在意，不肯轻易多说一句话，多行一步路，惟恐被人耻笑了去。</p>
                <p>进入荣国府正堂，只见金玉交辉，珠围翠绕。正当宾主落座、悲喜交集之际，只听后院中有人笑声，说：“我来迟了，不曾迎接远客！”</p>
                <p>黛玉纳罕道：“这些人个个皆敛声屏气，恭肃严整如此，这来者系谁，这样放诞无礼？”心下想时，只见一群媳妇丫鬟围拥着一个人从后房门进来。这个人打扮与众姑娘不同，彩绣辉煌，恍若神妃仙子：</p>

                <div class="dreader-poem-block">
                    <p>头上戴着金丝八宝攒珠髻，绾着朝阳五凤挂珠钗；</p>
                    <p>项上戴着赤金盘螭螭缨圈；裙边系着豆绿宫绦，双衡比目玫瑰佩；</p>
                    <p>身上穿着缕金百蝶穿花大红洋缎窄裉袄，外罩五彩刻丝石青银鼠褂；</p>
                    <p>下着翡翠撒花洋绉裙。一双丹凤三角眼，两弯柳叶吊梢眉，</p>
                    <p>身量苗条，体格风骚，粉面含春威不露，丹唇未启笑先闻。</p>
                </div>

                <p>贾母笑道：“你不认得他，他是我们这里有名的一个泼皮破落户儿，南省俗谓作‘辣子’，你只叫他‘凤辣子’就是了。”</p>
                <p>至晚，宝玉自外学归来。一见黛玉，便吃一大惊，笑道：“这个妹妹我曾见过的。”贾母笑道：“又胡说了！你何曾见过他？”宝玉笑道：“虽然未曾见过，看着面善，心里就算是旧相识，今日只作远别重逢，亦未为不可。”</p>
                <p>细看黛玉：两弯似蹙非蹙罥烟眉，一双似喜非喜含情目。态生两靥之愁，娇袭一身之病。泪光点点，娇喘微微。闲静时如姣花照水，行动处似弱柳扶风。心较比干多一窍，病如西子胜三分。</p>
                <p>宝玉因问黛玉：“妹妹可曾读书？可有玉没有？”黛玉道：“我没有玉。想来那是件罕物，岂能人人有的。”宝玉听了，登时发作起狂病来，摘下那块‘通灵宝玉’，狠命摔向地下，骂道：“什么罕物，连人之高低不择，还说通灵不通灵呢！我也不要这劳什子了！”吓得众人慌忙拾玉哄劝，此正是“木石前盟”红尘初度。</p>
            </div>
            """),

            ("第五回：开生面梦演红楼梦 立新意智通太虚境", """
            <div class="classic-chapter-wrapper">
                <div class="classic-chapter-header">
                    <div class="classic-dynasty-badge">清 · 曹雪芹</div>
                    <h1 class="classic-chapter-title">第五回 开生面梦演红楼梦 立新意智通太虚境</h1>
                    <div class="classic-author-line">太虚幻境判词 · 红楼梦十二支曲全本</div>
                    <div class="classic-ornament-divider">❦ ❦ ❦</div>
                </div>

                <p>一日，宁府花园梅花盛开，尤氏治酒请贾母等人赏花。宝玉倦怠欲歇，秦氏便引宝玉至上房安歇。入室只见唐伯虎画之《海棠春睡图》，两边挂着宋学士秦太虚写的一副对联：</p>

                <div class="dreader-poem-block">
                    <p class="poem-title">【太虚对联】</p>
                    <p>嫩寒锁梦因春冷，芳气袭人是酒香。</p>
                </div>

                <p>宝玉含笑合目，便恍恍惚惚入了梦乡。只见警幻仙子领至太虚幻境，入“薄命司”，遍览金陵十二钗正副册判词。</p>

                <div class="dreader-poem-block">
                    <p class="poem-title">【钗黛合一判词】</p>
                    <p>可叹停分德，堪怜咏絮才。</p>
                    <p>玉带林中挂，金簪雪里埋。</p>
                </div>

                <div class="dreader-poem-block">
                    <p class="poem-title">【王熙凤判词】</p>
                    <p>凡鸟偏从宿处来，池塘水涸鸳鸯拆。</p>
                    <p>一从二令三人木，哭向金陵事更哀。</p>
                </div>

                <div class="dreader-poem-block">
                    <p class="poem-title">【终身误】</p>
                    <p>都道是金玉良姻，俺只念木石前盟。</p>
                    <p>空对着，山中高士晶莹雪；终不忘，世外仙姝寂寞林。</p>
                    <p>叹人间，美中不足今方信。</p>
                    <p>纵然是齐眉举案，到底意难平！</p>
                </div>

                <div class="dreader-poem-block">
                    <p class="poem-title">【枉凝眉】</p>
                    <p>一个是阆苑仙葩，一个是美玉无瑕。</p>
                    <p>若说没奇缘，今生偏又遇着他；若说有奇缘，如何心事终虚化？</p>
                    <p>一个枉自嗟呀，一个空劳牵挂。</p>
                    <p>一个是水中月，一个是镜中花。</p>
                    <p>想眼中能有多少泪珠儿，怎禁得秋流到冬尽，春流到夏！</p>
                </div>

                <div class="dreader-poem-block">
                    <p class="poem-title">【飞鸟各投林 · 尾声】</p>
                    <p>为官的，家业凋零；富贵的，金银散尽；</p>
                    <p>有恩的，死里逃生；无情的，分明报应。</p>
                    <p>欠命的，命已还；欠泪的，泪已尽。</p>
                    <p>冤冤相报实非轻，分离聚合皆前定。</p>
                    <p>欲知命短问前生，老来富贵也真侥幸。</p>
                    <p>看破的，遁入空门；痴迷的，枉送了性命。</p>
                    <p>好一似食尽鸟投林，落了片白茫茫大地真干净！</p>
                </div>
            </div>
            """),

            ("第二十七回：滴翠亭杨妃戏彩蝶 埋香冢飞燕泣残红", """
            <div class="classic-chapter-wrapper">
                <div class="classic-chapter-header">
                    <div class="classic-dynasty-badge">清 · 曹雪芹</div>
                    <h1 class="classic-chapter-title">第二十七回 滴翠亭杨妃戏彩蝶 埋香冢飞燕泣残红</h1>
                    <div class="classic-author-line">千古绝唱 · 《葬花吟》全篇典藏</div>
                    <div class="classic-ornament-divider">❦ ❦ ❦</div>
                </div>

                <p>至次日芒种节，尚古风俗：凡交芒种节的这日，都要设摆各色礼物祭饯花神。言芒种一过，便是夏日了，众花皆卸，花神退位，须要辞谢饯行。</p>
                <p>黛玉因昨夜误会宝玉闭门不纳，又感身世凄凉，一清早独步至沁芳闸边山坡之上，见落花堆积，遂荷花锄、携花囊，悲恸抽泣，作下感天动地之《葬花吟》：</p>

                <div class="dreader-poem-block">
                    <p class="poem-title">【葬花吟 · 全文】</p>
                    <p>花谢花飞花满天，红消香断有谁怜？</p>
                    <p>游丝软系飘春榭，落絮轻沾扑绣帘。</p>
                    <p>闺中女儿惜春暮，愁绪满怀无释处。</p>
                    <p>手把花锄出绣帘，忍踏落花来复去。</p>
                    <p>柳丝榆荚自芳菲，不管桃飘与李飞。</p>
                    <p>桃李明年能再发，明年闺中知有谁？</p>
                    <p>三月香巢已垒成，梁间燕子太无情！</p>
                    <p>明年花发虽可啄，却不道人去梁空巢也倾。</p>
                    <p>一年三百六十日，风刀霜剑严相逼。</p>
                    <p>明媚鲜妍能几时，一朝漂泊难寻觅。</p>
                    <p>花开易见落难寻，阶前愁杀葬花人。</p>
                    <p>独倚花锄泪暗洒，洒上空枝见血痕。</p>
                    <p>杜鹃无语正黄昏，荷锄归去掩重门。</p>
                    <p>青灯照壁人初睡，冷雨敲窗被未温。</p>
                    <p>怪奴底事倍伤神？半为怜春半恼春。</p>
                    <p>怜春忽至恼忽去，至又无言去不闻。</p>
                    <p>昨宵庭外悲歌发，知是花魂与鸟魂？</p>
                    <p>花魂鸟魂总难留，鸟自无言花自羞。</p>
                    <p>愿奴胁下生双翼，随花飞到天尽头。</p>
                    <p>天尽头，何处有香丘？</p>
                    <p>未若锦囊收艳骨，一抔净土掩风流。</p>
                    <p>质本洁来还洁去，强于污淖陷渠沟。</p>
                    <p>尔今死去侬收葬，未卜侬身何日丧？</p>
                    <p>侬今葬花人笑痴，他年葬侬知是谁？</p>
                    <p>试看春残花渐落，便是红颜老死时。</p>
                    <p>一朝春尽红颜老，花落人亡两不知！</p>
                </div>

                <p>宝玉恰从山坡后走来，听得那诗痛彻心扉，不觉滚落泪珠，滚在山坡花冢之上，两人相对凄然，叹尽人生浮世飘萍之悲。</p>
            </div>
            """)
        ]
    }

    // MARK: - 《三国演义》正本章节内容
    private static var sanGuoChapters: [(String, String)] {
        [
            ("第一回：宴桃园豪杰三结义 斩黄巾英雄首立功", """
            <div class="classic-chapter-wrapper">
                <div class="classic-chapter-header">
                    <div class="classic-dynasty-badge">元末明初 · 罗贯中</div>
                    <h1 class="classic-chapter-title">第一回 宴桃园豪杰三结义 斩黄巾英雄首立功</h1>
                    <div class="classic-author-line">天下大势 分久必合 合久必分</div>
                    <div class="classic-ornament-divider">❦ ❦ ❦</div>
                </div>

                <div class="dreader-poem-block">
                    <p class="poem-title">【临江仙 · 开篇词】</p>
                    <p>滚滚长江东逝水，浪花淘尽英雄。</p>
                    <p>是非成败转头空。</p>
                    <p>青山依旧在，几度夕阳红。</p>
                    <p>白发渔樵江渚上，惯看秋月春风。</p>
                    <p>一壶浊酒喜相逢。</p>
                    <p>古今多少事，都付笑谈中。</p>
                </div>

                <p>话说天下大势，分久必合，合久必分。周末七国分争，并入于秦。及秦灭之后，楚、汉分争，又并入于汉。汉朝自高祖斩白蛇而起义，一统天下，后来光武中兴，传至献帝，遂分为三国。</p>
                <p>东汉末年，政治腐败，张角三兄弟借“太平道”起事，号称“黄巾军”，四方扰动。幽州太守刘焉出榜招军。榜文行到涿县，引出涿县中一个英雄：</p>
                <p>那人不甚好读书；性宽和，言语少，喜怒不形于色；素有大志，专好结交天下豪杰；生得身长七尺五寸，两耳垂肩，双手过膝，目能自顾其耳，面如冠玉，唇若涂脂；中山靖王刘胜之后，汉景帝阁下玄孙，姓刘名备，字玄德。</p>
                <p>忽见一人，身长八尺，豹头环眼，燕颔虎须，声若巨雷，势如奔马。玄德见他形貌异常，问其姓名。其人曰：“某姓张名飞，字翼德。世居涿郡，颇有庄田，卖酒屠猪，专好结交天下豪杰。”</p>
                <p>二人同入村店饮酒，正饮间，见一大汉，推着一辆车子，到店门首歇了，入店坐下，便唤酒保：“快斟酒来吃，我待赶入城去投军！”玄德看其人：身长九尺，髯长二尺；面如重枣，唇若涂脂；丹凤眼，卧蚕眉，相貌堂堂，威风凛凛。玄德就邀他同坐，叩其姓名。其人曰：“吾姓关名羽，字云长，因本处势豪倚势凌人，被吾杀了，逃难江湖，五六年矣。”</p>
                <p>玄德遂以己志告之，关、张大喜。次日，于张飞庄后桃园中，树上桃花盛开，备下乌牛白马祭礼等项，三人焚香再拜而说誓曰：</p>

                <div class="dreader-poem-block">
                    <p class="poem-title">【桃园结义誓词】</p>
                    <p>“念刘备、关羽、张飞，虽然异姓，既结为兄弟，</p>
                    <p>则同心协力，救困扶危；上报国家，下安黎庶。</p>
                    <p>不求同年同月同日生，但愿同年同月同日死。</p>
                    <p>皇天后土，实鉴此心，背义忘恩，天人共戮！”</p>
                </div>

                <p>誓毕，拜刘备为兄，关羽次之，张飞为弟。收拾兵甲，自此名垂青史，开创三国百年波澜壮阔之雄伟纪元。</p>
            </div>
            """),

            ("第五回：发矫诏诸镇应曹公 破关兵三英战吕布", """
            <div class="classic-chapter-wrapper">
                <div class="classic-chapter-header">
                    <div class="classic-dynasty-badge">元末明初 · 罗贯中</div>
                    <h1 class="classic-chapter-title">第五回 发矫诏诸镇应曹公 破关兵三英战吕布</h1>
                    <div class="classic-author-line">虎牢关前 · 绝世神威</div>
                    <div class="classic-ornament-divider">❦ ❦ ❦</div>
                </div>

                <p>却说董卓作乱，曹操发矫诏会集十八路诸侯共讨董卓，公推袁绍为盟主。董卓闻知，遣心腹骁将华雄守汜水关，吕布守虎牢关。</p>
                <p>汜水关前，华雄斩鲍忠、杀祖茂、斩俞涉、搦潘凤，联军震恐。关云长以马弓手之微职出列，豪言“如不胜，请斩某头！”曹操教酾热酒一杯与关公饮了上马。关公曰：“酒且斟下，某便去也！”出帐提刀飞身上马。须臾，鸾铃响处，马到中军，云长提华雄之头掷于地上。其酒尚温！此即天下闻名之“温酒斩华雄”。</p>
                <p>及至虎牢关前，吕布头戴三叉束发紫金冠，体挂西川红锦百花袍，身披兽面吞天铠，腰系勒甲玲珑狮蛮带，弓箭随身，手持方天画戟，坐下嘶风赤兔马，天下无双！公孙瓒战吕布不下，败走。吕布纵马赶来，方天画戟正要刺下，张飞圆睁环眼，倒竖虎须，挺丈八蛇矛，飞马大叫：“俺燕人张翼德在此！”</p>
                <p>吕布见了，弃了公孙瓒，便战张飞。连斗五十余合，不分胜负。关云长见了，把马一拍，舞八十二斤青龙偃月刀，来夹攻吕布。三匹马丁字儿厮杀，战到三十合，战不倒吕布。刘玄德掣双股剑，骤黄鬃马，刺斜里也来助战。这三个围住吕布，转灯儿般厮杀。八路人马，都看得呆了！</p>

                <div class="dreader-poem-block">
                    <p>虎牢关上声如雷，三英奋发威名播。</p>
                    <p>画戟金戈耀日精，真乃千古豪杰会！</p>
                </div>
            </div>
            """)
        ]
    }

    // MARK: - 《西游记》正本章节内容
    private static var xiYouJiChapters: [(String, String)] {
        [
            ("第一回：灵根育孕源流出 心性修持大道生", """
            <div class="classic-chapter-wrapper">
                <div class="classic-chapter-header">
                    <div class="classic-dynasty-badge">明 · 吴承恩</div>
                    <h1 class="classic-chapter-title">第一回 灵根育孕源流出 心性修持大道生</h1>
                    <div class="classic-author-line">仙石孕化 · 美猴王拜师悟道</div>
                    <div class="classic-ornament-divider">❦ ❦ ❦</div>
                </div>

                <div class="dreader-poem-block">
                    <p class="poem-title">【开篇诗】</p>
                    <p>混沌未分天地乱，茫茫渺渺无人见。</p>
                    <p>自从盘古破鸿蒙，开辟从兹清浊辨。</p>
                    <p>覆载群生仰至德，发明万物皆成善。</p>
                    <p>预知造化会元功，须看西游释厄传。</p>
                </div>

                <p>感盘古开辟，三皇治世，五帝分伦，世界之间，遂分为四大部洲：曰东胜神洲，曰西牛贺洲，曰南赡部洲，曰北俱芦洲。这部书单表东胜神洲。海外有一国土，名曰傲来国。国碰大海，海中有一座名山，唤为花果山。此山乃十洲之祖脉，三岛之来龙，自开清浊而立，鸿蒙判后而成。</p>
                <p>那座山正当顶上，有一块仙石。其石有三丈六尺五寸高，按周天三百六十五度；二丈四尺围圆，按政历二十四气。上有九窍八孔，按九宫八卦。四面更无树木遮阴，左右倒有芝兰相衬。盖自开辟以来，蒙受天真地秀，日精月华，感之既久，遂有灵通之意。内育仙胞。一日迸裂，产一石卵，似圆球样大。因见风，化作一个石猴。五官俱备，四肢皆全。便就学爬学走，拜了四方。目运两道金光，射冲斗府。</p>
                <p>石猴在山中游玩，见瀑布飞泉，纵身一跃跳入水帘洞，寻得安身立命之洞天福地，群猴拜为“美猴王”。欢乐数百载，忽一日垂泪忧虑生死无常，遂决志漂洋过海，寻仙访道，求长生不老之术。</p>
                <p>历经南赡部洲数载，终至西牛贺洲灵台方寸山，斜月三星洞。见菩提祖师端坐瑶台，石猴叩头捣蒜，求传长生不老仙法。祖师见其通灵，赐其法姓为“孙”，法名为“悟空”，由此开启震古烁今之齐天大圣传奇！</p>
            </div>
            """),

            ("第二回：悟彻菩提真妙理 断魔归本合元神", """
            <div class="classic-chapter-wrapper">
                <div class="classic-chapter-header">
                    <div class="classic-dynasty-badge">明 · 吴承恩</div>
                    <h1 class="classic-chapter-title">第二回 悟彻菩提真妙理 断魔归本合元神</h1>
                    <div class="classic-author-line">地煞七十二变 · 筋斗云腾挪万里</div>
                    <div class="classic-ornament-divider">❦ ❦ ❦</div>
                </div>

                <p>话表美猴王得了姓名，怡然踊跃，对菩提祖师作礼启谢。祖师夜半三更传道，悟空识破祖师三戒尺扣背手之哑谜，跪伏榻前，虔诚领授金丹妙诀。</p>
                <p>祖师传口诀曰：“显密圆通真妙诀，惜修生命无他说。都来总是精气神，谨固牢藏休漏泄。休漏泄，体中藏，汝受吾传道自昌。口诀记来多有益，屏除邪欲得清凉。得清凉，光皎洁，好向丹台赏明月。月藏玉兔日藏乌，自有龟蛇相盘结。相盘结，性命坚，却能火里种金莲。攒簇五行颠倒用，功完劫毕成佛仙。”</p>
                <p>悟空默记口诀，勤修不辍，三年功成。祖师又传地煞七十二般变化，防备天降三灾利害；复传筋斗云，捻着诀，念动真言，攒紧了拳，将身一抖，跳将起来，一窍通，百窍通，一个筋斗便能腾挪十万八千里！神通广大，造化玄奇，自此天地难拘，神魔莫测。</p>
            </div>
            """)
        ]
    }
}
