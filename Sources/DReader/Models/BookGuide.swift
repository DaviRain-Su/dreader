import Foundation

/// AI 全书导读(读伴式):生成一次、落库复用,可重新生成覆盖。
/// 结构对齐读伴三段式——这本书解决什么问题 / 全书地图 / 怎么读。
struct BookGuide: Codable, Sendable, Equatable {
    /// 这本书在解决什么问题(~200 字)
    var whatProblem: String
    /// 全书地图:各部分/章群的一句话脉络
    var mapEntries: [GuideMapEntry]
    /// 目标读者与阅读建议
    var readingAdvice: String
    /// 关键概念速览(术语 → 一句话解释)
    var keyTerms: [GuideTerm]

    struct GuideMapEntry: Codable, Sendable, Equatable {
        /// 如 "Chapter 0–2" 或 "第一部分"
        var range: String
        var summary: String
    }

    struct GuideTerm: Codable, Sendable, Equatable {
        var term: String
        var definition: String
    }
}

/// AI 章节导读(替换静态 ChapterBriefingService 的 AI 生成版)
struct ChapterGuide: Codable, Sendable, Equatable {
    var chapterTitle: String
    /// 本章核心摘要(~100 字)
    var overview: String
    /// 3 个背景/概念要点
    var backgroundPoints: [String]
    /// 1–2 个苏格拉底式反思问题
    var socraticQuestions: [String]
}
