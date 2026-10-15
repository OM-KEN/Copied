import Foundation

private func expectDefinition(_ word: String, raw: String, expected: String?) {
    let actual = DictionaryLookupService.lookup(word, rawLookup: { _ in raw })
    guard actual == expected else {
        fputs("FAIL: \(word) definition\nexpected: \(expected ?? "<nil>")\nactual: \(actual ?? "<nil>")\n", stderr)
        exit(1)
    }
}

private func expectLookup(_ word: String, entries: [String: String], expected: String?, requests: [String]) {
    var queried: [String] = []
    let actual = DictionaryLookupService.lookup(word, rawLookup: { target in
        queried.append(target)
        return entries[target]
    })
    guard actual == expected, queried == requests else {
        fputs("FAIL: \(word) alias lookup\nexpected: \(expected ?? "<nil>") / \(requests)\nactual: \(actual ?? "<nil>") / \(queried)\n", stderr)
        exit(1)
    }
}

@main
struct DictionaryLookupTests {
    static func main() {
        pronunciationMayShareAFieldWithMeanings()
        grammaticalReferencesAndMultiwordTargetsAreSupported()
        negationAndExampleReferencesAreNotFlattened()
        adjacentLettersAndDigitsStayWithChinese()
        plainEntriesRequireTheQueriedEnglishHeadword()
        phrasalVerbsAndGrammarSubentriesHaveExplicitBoundaries()
        longDefinitionsAreNotMistakenForExamples()
        examplesDoNotConsumeDefinitionSlots()
        laterSensesAndPartsOfSpeechSurviveExamples()
        chinesePunctuationAndPlaceholdersStayTogether()
        pronunciationIsOptionalAndRequiresAMeaning()
        explicitAliasesKeepTheOriginalWordAndPronunciation()
        aliasResolutionIsBoundedAndConservative()
        print("DictionaryLookupTests: PASS")
    }

    private static func pronunciationMayShareAFieldWithMeanings() {
        expectDefinition("supposed", raw: "supposed adjective ① | BrE səˈpəʊzd, AmE səˈpoʊzd/; attributive (alleged) 误以为的 wù yǐwéi de▸ a supposed accident 所谓的事故 ② | BrE səˈpəʊzd, AmE səˈpoʊzd/; predicative (expected) 应当的 yīngdāng de▸ to be supposed to do sth 应当做某事", expected: "supposed  səˈpəʊzd\n误以为的，应当的")
        expectDefinition("beloved", raw: "beloved A. adjective ① | BrE bɪˈlʌvɪd, AmE bəˈləvəd/; attributive 钟爱的 zhōng'ài de ② | BrE bɪˈlʌvd, AmE bəˈləvd/; predicative ▸ to be beloved by sb 深受某人喜爱 B. noun | BrE bɪˈlʌvɪd, AmE bəˈləvəd | 心爱的人 xīn'ài de rén", expected: "beloved  bɪˈlʌvɪd\n钟爱的，心爱的人")
        expectDefinition("sample", raw: "sample | AmE ˈsæmpəl/; noun 样本 yàngběn", expected: "sample  ˈsæmpəl\n样本")
    }

    private static func grammaticalReferencesAndMultiwordTargetsAreSupported() {
        expectLookup("hemoglobin", entries: [
            "hemoglobin": "hemoglobin | BrE ˌhiːməˈɡləʊbɪn | noun uncountable US = haemoglobin",
            "haemoglobin": "haemoglobin | noun uncountable British 血红蛋白 xuèhóng dànbái"
        ], expected: "hemoglobin  ˌhiːməˈɡləʊbɪn\n血红蛋白", requests: ["hemoglobin", "haemoglobin"])
        expectLookup("diarrhea", entries: [
            "diarrhea": "diarrhea | noun uncountable US = diarrhoea",
            "diarrhoea": "diarrhoea | noun ① 腹泻 fùxiè▸ chronic diarrhoea 慢性腹泻 ② 水样粪便 shuǐyàng fènbiàn"
        ], expected: "diarrhea\n腹泻，水样粪便", requests: ["diarrhea", "diarrhoea"])
        expectLookup("made", entries: [
            "made": "made | BrE meɪd, AmE meɪd | past tense, past participle → make",
            "make": "make | BrE meɪk | transitive verb 制造 zhìzào"
        ], expected: "made  meɪd\n制造", requests: ["made", "make"])
        expectLookup("been", entries: [
            "been": "been | BrE biːn, bɪn, AmE bɪn | past participle → be",
            "be": "be | BrE biː | verb 是 shì"
        ], expected: "been  biːn\n是", requests: ["been", "be"])
        expectLookup("RNA", entries: [
            "RNA": "RNA | BrE ˌɑːrɛnˈeɪ, AmE ˌɑrˌɛnˈeɪ | abbreviation = ribonucleic acid",
            "ribonucleic acid": "ribonucleic acid | noun uncountable 核糖核酸 hétáng hésuān"
        ], expected: "RNA  ˌɑːrɛnˈeɪ\n核糖核酸", requests: ["RNA", "ribonucleic acid"])
        expectLookup("sample", entries: ["sample": "sample | noun 中文 zhōngwén; past participle → example"], expected: "sample\n中文", requests: ["sample"])
    }

    private static func negationAndExampleReferencesAreNotFlattened() {
        expectLookup("don't", entries: [
            "don't": "don't | BrE dəʊnt | informal = do not → do1 C",
            "do": "do | verb 做 zuò"
        ], expected: nil, requests: ["don't"])
        expectLookup("cannot", entries: [
            "cannot": "cannot | negative present tense → can1",
            "can": "can | verb 能 néng"
        ], expected: nil, requests: ["cannot"])
        expectLookup("won't", entries: ["won't": "won't | informal = will not"], expected: nil, requests: ["won't"])
        expectLookup("sample", entries: ["sample": "sample | noun▸ an equation = example"], expected: nil, requests: ["sample"])
        expectLookup("sample", entries: ["sample": "sample | noun▸ see the result → example"], expected: nil, requests: ["sample"])
        expectLookup("sample", entries: ["sample": "sample | noun a representative part → example"], expected: nil, requests: ["sample"])
        expectLookup("made", entries: [
            "made": "made | past tense, past participle → make",
            "make": "马克 mǎkè （馬克）①名 货币单位。"
        ], expected: nil, requests: ["made", "make"])
    }

    private static func adjacentLettersAndDigitsStayWithChinese() {
        expectLookup("pH", entries: ["pH": "pH | BrE ˌpiːˈeɪtʃ, AmE ˌpiˈeɪtʃ | abbreviation = potential of hydrogen pH值 p H zhí"], expected: "pH  ˌpiːˈeɪtʃ\npH值", requests: ["pH"])
        let tshirt = "T-shirt | BrE ˈtiːʃəːt, AmE ˈtiˌʃərt | noun T恤衫 T xùshān"
        expectDefinition("tshirt", raw: tshirt, expected: "tshirt  ˈtiːʃəːt\nT恤衫")
        expectDefinition("teeshirt", raw: tshirt, expected: "teeshirt  ˈtiːʃəːt\nT恤衫")
        expectDefinition("vitamin", raw: "vitamin | noun 维生素A wéishēngsù A; 维生素B12 wéishēngsù B12", expected: "vitamin\n维生素A，维生素B12")
        expectDefinition("printing", raw: "printing | noun 3D打印 dǎyìn; 2种印刷法 yìnshuāfǎ", expected: "printing\n3D打印，2种印刷法")
    }

    private static func plainEntriesRequireTheQueriedEnglishHeadword() {
        expectDefinition("DNA", raw: "DNA 脱氧核糖核酸(英 Deoxyribonucleic Acid 的缩写)。", expected: "DNA\n脱氧核糖核酸")
        expectDefinition("HIV", raw: "HIV 人体免疫缺陷病毒；艾滋病病毒(英 Human Immunodeficiency Virus 的缩写)。", expected: "HIV\n人体免疫缺陷病毒；艾滋病病毒")
        expectDefinition("TV", raw: "TV 电视(英 Television 的缩写)。", expected: "TV\n电视")
        expectDefinition("CD", raw: "CD 光碟；光盘；激光唱片(英 Compact Disc 的缩写)。", expected: "CD\n光碟；光盘；激光唱片")
        expectDefinition("IQ", raw: "IQ 智商(英 Intelligence Quotient 的缩写)。", expected: "IQ\n智商")
        expectDefinition("tv", raw: "TV 电视(英 Television 的缩写)。", expected: "tv\n电视")
        expectDefinition("TV", raw: "TVs 电视机", expected: nil)
        expectDefinition("sample", raw: "another 中文释义", expected: nil)
        expectDefinition("can", raw: "参 1 cān ①动 加入；参与。", expected: nil)
    }

    private static func phrasalVerbsAndGrammarSubentriesHaveExplicitBoundaries() {
        let tee = "tee | BrE tiː | A. noun ① 球座 qiúzuò ② 发球区 fāqiúqū▸ a tee shot 开球 B. transitive verb 把…置于球座上 bǎ… zhì yú qiúzuò shang PHRASAL VERB tee off A. intransitive verb ① 开球 kāiqiú ② 开始 kāishǐ B. transitive verb 惹烦 rěfán"
        expectDefinition("tee", raw: tee, expected: "tee  tiː\n球座，发球区，把…置于球座上")
        expectDefinition("tee", raw: tee.replacingOccurrences(of: "PHRASAL VERB ", with: "PHRASAL VERBS "), expected: "tee  tiː\n球座，发球区，把…置于球座上")
        expectDefinition("running", raw: "running | noun ① 跑步 pǎobù▸ to make the running 领跑 (in activity) 带头 dàitóubefore noun 赛跑用的 sàipǎo yòng de ‹shorts›② 管理 guǎnlǐ", expected: "running\n跑步，赛跑用的，管理")
        expectDefinition("centre", raw: "centre | noun 正中 zhèngzhōng▸ the centre of a circle 圆心before noun 中间的 zhōngjiān de ‹lane›▸ centre seats 当中的座位", expected: "centre\n正中，中间的")
        expectDefinition("sample", raw: "sample | adjective 原来的 yuánlái de▸ an example 例句after noun 后置的 hòuzhì de", expected: "sample\n原来的，后置的")
    }

    private static func longDefinitionsAreNotMistakenForExamples() {
        // 固定合成输入来自系统词典诊断，不依赖测试机器启用的词典。
        let thermostat = "thermostat | BrE ˈθəːmə(ʊ)stat, AmE ˈθərməˌstæt | noun 温度自动调节器 wēndù zìdòng tiáojiéqì "
        expectDefinition("thermostat", raw: thermostat, expected: "thermostat  ˈθəːmə(ʊ)stat\n温度自动调节器")
        expectDefinition("thermostats", raw: thermostat, expected: "thermostats  ˈθəːmə(ʊ)stat\n温度自动调节器")
        expectDefinition("thermostatic", raw: "thermostatic | BrE ˌθəːmə(ʊ)ˈstatɪk, AmE ˌθərməˈstædɪk | adjective 温度自动调节器的 wēndù zìdòng tiáojiéqì de ", expected: "thermostatic  ˌθəːmə(ʊ)ˈstatɪk\n温度自动调节器的")
    }

    private static func examplesDoNotConsumeDefinitionSlots() {
        expectDefinition("apple", raw: "apple | BrE ˈapl, AmE ˈæp(ə)l | noun (fruit) 苹果 píngguǒ; (tree) 苹果树 píngguǒ shù▸ the apple of sb's eye figurative 掌上明珠▸ there's a bad apple in every bunch 哪儿都有害群之马▸ to upset the apple cart 打乱计划▸ an apple a day keeps the doctor away proverb 天天吃苹果，医生远离我 ", expected: "apple  ˈapl\n苹果，苹果树")
        expectDefinition("computer", raw: "computer | BrE kəmˈpjuːtə, AmE kəmˈpjudər | noun 计算机 jìsuànjī▸ to do sth by computer or on a computer 用计算机做某事▸ to have/put sth on computer 将某资料存入计算机▸ the computer is up/down 这台计算机在运行/无法运行▸ a personal/home/laptop computer 个人/家用/笔记本电脑▸ to be or work in computers 在计算机行业工作 ", expected: "computer  kəmˈpjuːtə\n计算机")
        expectDefinition("sample", raw: "sample | noun 样本 yàngběn▸ a U.S. example 美国例句", expected: "sample\n样本")
        expectDefinition("sample", raw: "sample | noun 样本 yàngběn▸ a U.S. noun example 美国名词例句", expected: "sample\n样本")

        let bank = "bank 1 | BrE baŋk, AmE bæŋk | A. noun ① 岸 àn ② 堆 duī▸ a bank of snow 一堆雪 ③ (hill) 斜坡 xiépō; (road) 边坡 biānpō ④ 浅滩 qiǎntān▸ a sand bank 沙洲 ⑤ 大量 dàliàng▸ a bank of cloud 厚厚的云层 ⑥ 路堤 lùdī ⑦ （拐弯时的）向内侧倾斜 (guǎiwān shí de)xiàng nèicè qīngxié ⑧ 组 zǔ B. transitive verb 堆积 duījī"
        expectDefinition("bank", raw: bank, expected: "bank  baŋk\n岸，堆，斜坡，边坡，浅滩，大量，路堤，（拐弯时的）向内侧倾斜")
    }

    private static func laterSensesAndPartsOfSpeechSurviveExamples() {
        expectDefinition("beautiful", raw: "beautiful | BrE ˈbjuːtɪf(ʊ)l, AmE ˈbjudəfəl | adjective ① (attractive) 美丽的 měilì de▸ she is the most beautiful woman I know 她是我认识的女人中最漂亮的▸ a beautiful Beethoven sonata 一首优美的贝多芬奏鸣曲 ② (wonderful) 令人愉悦的 lìng rén yúyuè de ‹weather, holiday, feeling›③ (skilful) 出色的 chūsè de▸ he's a beautiful writer 他写得一手好文章 ④ (superb) 完美的 wánměi de ‹specimen›▸ a beautiful example of sth 某事物的完美体现 ", expected: "beautiful  ˈbjuːtɪf(ʊ)l\n美丽的，令人愉悦的，出色的，完美的")
        expectDefinition("resume", raw: "resume | BrE rɪˈzjuːm, AmE rəˈzum | A. transitive verb ① (continue) 继续 jìxù ‹voyage, work›▸ to resume doing sth; 接着做某事▸ to resume negotiations 重启谈判▸ normal service will be resumed as soon as possible 正常的服务会尽快恢复 ② (use again) 重新得到 chóngxīn dédào ‹title, seat›B. intransitive verb «discussion, lecture» 继续 jìxù; «service, hostilities» 恢复 huīfù C. noun → résumé 2", expected: "resume  rɪˈzjuːm\n继续，重新得到，恢复")
        expectDefinition("neither", raw: "neither | BrE ˈnʌɪðə, ˈniːðə, AmE ˈniðər, ˈnaɪðər | A. conjunction 都不 dōu bù▸ neither … nor … 既不…也不…▸ neither Peter nor I was there 彼得和我都不在那里→ here A1B. adverb 也不 yě bù▸ I don't like him — neither do I 我不喜欢他──我也不喜欢他 C. determiner 两者都不 liǎngzhě dōu bù▸ neither answer is correct 两个答案都不对 D. pronoun 两者都不 liǎngzhě dōu bù▸ neither is suitable 两个都不合适 ", expected: "neither  ˈnʌɪðə\n都不，也不，两者都不")
        expectDefinition("sample", raw: "sample | noun 样本 yàngběn▸ an example 例句 PHRASAL VERBS sample out transitive verb ① 另一个意思 lìng yī ge yìsi", expected: "sample\n样本")
        expectDefinition("sample", raw: "sample | A. noun 样本 yàngběn▸ an example 例句 B. samples plural noun 样品 yàngpǐn", expected: "sample\n样本，样品")
    }

    private static func chinesePunctuationAndPlaceholdersStayTogether() {
        let abstract = "abstract A. adjective | BrE ˈabstrakt, AmE ˈæbˌstræk(t) | ① 抽象的 chōuxiàng de; 理论上的 lǐlùn shang de ‹argument›② Art 抽象（派）的 chōuxiàng(pài) de ③ 抽象的 chōuxiàng de ‹noun›B. noun | BrE ˈabstrakt, AmE ˈæbˌstræk(t) | ① 抽象 chōuxiàng▸ in the abstract 在抽象意义上 ② 摘要 zhāiyào ③ 抽象派作品 chōuxiàngpài zuòpǐn C. transitive verb | BrE əbˈstrakt, AmE əbˈstræk(t) | ① 写…的摘要 xiě… de zhāiyào ② 提取 tíqǔ▸ abstract facts 摘取事实 D. to abstract oneself reflexive verb | BrE əbˈstrakt | ▸ to abstract oneself from sth 使自己脱离某事物"
        expectDefinition("abstract", raw: abstract, expected: "abstract  ˈabstrakt\n抽象的，理论上的，抽象（派）的，抽象，摘要，抽象派作品，写…的摘要，提取")
        expectDefinition("organize", raw: "organize | BrE ˈɔːɡənʌɪz, AmE ˈɔrɡəˌnaɪz | transitive verb ① (arrange) 安排 ānpái ‹course, meeting›; 组织 zǔzhī ‹visit, expedition›; 使…有条理 shǐ… yǒu tiáolǐ ‹facts, thoughts›▸ to organize sth into groups/chapters 把某物编成小组/章节 ② (unionize) 把…组成工会 bǎ… zǔchéng gōnghuì ‹group, workforce›", expected: "organize  ˈɔːɡənʌɪz\n安排，组织，使…有条理，把…组成工会")
        expectDefinition("fungus", raw: "fungus | BrE ˈfʌŋɡəs, AmE ˈfəŋɡəs | noun ① countable (plant) 真菌类植物 zhēnjūnlèi zhíwù ② countable (mould) 真菌 zhēnjūn ③ uncountable (infection) [尤指鱼的] 真菌病 zhēnjūnbìng ④ figurative 冒出来的丑陋东西 mào chulai de chǒulòu dōngxi▸ a fungus of outbuildings 房子后面冒出来的一批丑陋附属建筑物 ⑤ slang 胡须 húxū", expected: "fungus  ˈfʌŋɡəs\n真菌类植物，真菌，[尤指鱼的] 真菌病，冒出来的丑陋东西，胡须")
        expectDefinition("sample", raw: "sample | noun （中文，带标点） cí; (中文括号) cí; 使…成为某物 cí", expected: "sample\n（中文，带标点），(中文括号)，使…成为某物")
        expectDefinition("sample", raw: "sample | noun [English note] 样本 yàngběn", expected: "sample\n样本")
    }

    private static func pronunciationIsOptionalAndRequiresAMeaning() {
        expectDefinition("sample", raw: "sample | AmE ˈsæmpəl | noun 样本 yàngběn", expected: "sample  ˈsæmpəl\n样本")
        expectDefinition("sample", raw: "sample|BrE ˈsɑːmpəl, AmE ˈsæmpəl|noun 样本 yàngběn", expected: "sample  ˈsɑːmpəl\n样本")
        expectDefinition("sample", raw: "sample | noun 样本 yàngběn", expected: "sample\n样本")
        expectDefinition("sample", raw: "sample | BrE ˈsɑːmpəl, AmE ˈsæmpəl | noun", expected: nil)
        expectDefinition("sample", raw: "sample | AmE ˈsæmpəl | noun a representative part", expected: nil)
        expectDefinition("sample", raw: "sample | noun a representative part▸ an example 例句", expected: nil)
        expectDefinition("sample", raw: "sample | noun 样本 yàngběn▸ an example\n例句翻译 ② 标准 biāozhǔn", expected: "sample\n样本，标准")
        expectDefinition("sample", raw: "sample | noun （中文）\n释义 shìyì", expected: "sample\n（中文） 释义")
        expectDefinition("run", raw: "瞤 rún （瞤）〈文〉①动 眼皮跳动。 ②动 肌肉抽搐。", expected: nil)
        expectDefinition("fan", raw: "帆 fān ①名 布篷。一帆风顺 | 扬帆 | 帆船 ②名 指船。", expected: nil)
        expectDefinition("sample", raw: "", expected: nil)
        expectDefinition("sample", raw: "sample", expected: nil)
        expectDefinition("sample", raw: "sample | | ", expected: nil)
    }

    private static func explicitAliasesKeepTheOriginalWordAndPronunciation() {
        expectLookup("color", entries: [
            "color": "color | BrE ˈkʌlə, AmE ˈkələr | noun, transitive or intransitive verb US = colour",
            "colour": "colour | BrE ˈkʌlə, AmE ˈkələr | British A. noun ① uncountable and countable (hue) 颜色 yánsè▸ a bright/dark colour 亮色/深色 ② uncountable (not black-and-white) 彩色 cǎisè"
        ], expected: "color  ˈkʌlə\n颜色，彩色", requests: ["color", "colour"])
        expectLookup("center", entries: [
            "center": "center | BrE ˈsɛntə, AmE ˈsɛn(t)ər | noun, transitive verb US = centre",
            "centre": "centre | BrE ˈsɛntə, AmE ˈsɛn(t)ər | British A. noun ① (middle) 正中 zhèngzhōng▸ the centre of the circle 圆心 ② (of town, city) 中心区 zhōngxīnqū"
        ], expected: "center  ˈsɛntə\n正中，中心区", requests: ["center", "centre"])
        expectLookup("airplane", entries: [
            "airplane": "airplane | BrE ˈɛːpleɪn, AmE ˈɛrˌpleɪn | noun US = aeroplane",
            "aeroplane": "aeroplane | BrE ˈɛːrəpleɪn, AmE ˈɛrəˌpleɪn | noun (mainly British) 飞机 fēijī "
        ], expected: "airplane  ˈɛːpleɪn\n飞机", requests: ["airplane", "aeroplane"])
        expectLookup("okay", entries: [
            "okay": "okay | BrE əʊˈkeɪ, AmE ˌoʊˈkeɪ | exclamation, adjective, adverb, transitive verb, noun = OK1",
            "OK": "OK 1 | BrE ˌəʊˈkeɪ, AmE ˌoʊˈkeɪ | informal A. exclamation ① (in agreement) [表示同意或接受]▸ let's go! — OK 我们走吧！──好的 ② (seeking consensus) [表示征求同意]"
        ], expected: "okay  əʊˈkeɪ\n[表示同意或接受]，[表示征求同意]", requests: ["okay", "OK"])
        expectLookup("sample", entries: [
            "sample": "sample | noun US = example",
            "example": "example | BrE ɪɡˈzɑːmpəl | noun 样本 yàngběn"
        ], expected: "sample\n样本", requests: ["sample", "example"])
    }

    private static func aliasResolutionIsBoundedAndConservative() {
        expectLookup("alpha", entries: [
            "alpha": "alpha | noun = BETA",
            "BETA": "beta | noun = ALPHA"
        ], expected: nil, requests: ["alpha", "BETA"])
        expectLookup("alpha", entries: [
            "alpha": "alpha | noun = beta",
            "beta": "beta | noun = gamma",
            "gamma": "gamma | noun 释义 shìyì"
        ], expected: "alpha\n释义", requests: ["alpha", "beta", "gamma"])
        expectLookup("alpha", entries: [
            "alpha": "alpha | noun = beta",
            "beta": "beta | noun = gamma",
            "gamma": "gamma | noun = delta",
            "delta": "delta | noun 释义 shìyì"
        ], expected: nil, requests: ["alpha", "beta", "gamma"])
        expectLookup("color", entries: ["color": "color | noun US = colour"], expected: nil, requests: ["color", "colour"])
        expectLookup("sample", entries: [:], expected: nil, requests: ["sample"])
        expectLookup("sample", entries: ["sample": "sample | noun a representative part = example"], expected: nil, requests: ["sample"])
        expectLookup("sample", entries: ["sample": "sample | noun US = example▸ an example"], expected: nil, requests: ["sample"])
        expectLookup("sample", entries: ["sample": "sample | noun US = example text"], expected: nil, requests: ["sample", "example text"])
        expectLookup("sample", entries: ["sample": "sample | noun 中文 zhōngwén = example"], expected: "sample\n中文", requests: ["sample"])
    }
}
