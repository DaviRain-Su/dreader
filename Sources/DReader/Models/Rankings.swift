//
//  Rankings.swift
//  DReader
//
//  书单与榜单目录的数据模型：来源/语言枚举、榜单目录（RankingCatalog）、书目条目（RankingBook）。
//  全部纯 Foundation + Sendable；静态数据在 RankingStaticCatalogs / RankingDoubanSnapshot，
//  在线拉取与缓存在 RankingService。
//

import Foundation

/// 榜单来源。v1：微信读书（网页榜单，实时拉取）、豆瓣 Top250（内置快照）、国际奖项（内置快照）。
enum RankingSource: String, CaseIterable, Codable, Sendable {
    case weread
    case douban
    case curated

    /// 书卡底行来源徽章文字
    var badgeText: String {
        switch self {
        case .weread: return "微信读书"
        case .douban: return "豆瓣"
        case .curated: return "奖项书单"
        }
    }

    /// 左栏分节名（Registry 的分节顺序即展示序）
    var sectionLabel: String {
        switch self {
        case .weread: return "微信读书 · 直连"
        case .douban: return "榜单快照"
        case .curated: return "国际奖项"
        }
    }
}

/// 榜单条目主要语言（详情 chips 用）
enum RankingLanguage: String, Codable, Sendable {
    case zh, en, mixed

    var badgeText: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        case .mixed: return "多语"
        }
    }
}

/// 一个榜单目录（左栏一行）。id 兼作缓存 key。
struct RankingCatalog: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String                   // e.g. "微信读书 · 飙升榜"
    let subtitle: String?               // 左栏行的短副题
    let source: RankingSource
    let isLive: Bool
    let refreshInterval: TimeInterval?  // live 的失效 TTL；静态快照为 nil
    let language: RankingLanguage
}

/// 榜单里的一本书。
struct RankingBook: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let catalogID: String
    let rank: Int
    let title: String
    let author: String
    let rating: Double?                 // 统一 0...10；奖项名单类为 nil
    var readersCount: Int? = nil        // weread 人在读人数
    var language: RankingLanguage = .zh
    var coverURL: URL? = nil
    var summary: String? = nil
    var year: String? = nil
    var externalURL: URL? = nil         // 豆瓣 subject / 微信书页 / 奖项官网 / Gutenberg 页
    var wereadBookId: String? = nil
    var gutenbergID: String? = nil      // 非 nil → 可走 Gutenberg 下载「加入书架」
    var honor: String? = nil            // 奖项信息，e.g. "诺贝尔文学奖 1958"
    var tag: String? = nil              // 短标签，e.g. "长篇小说"
    var tintColors: [String]? = nil     // 无封面字牌渐变色对（hex）

    /// 微信 CDN 的 s_ 缩略封面换 t9_ 高清
    var displayCoverURL: URL? {
        guard let url = coverURL else { return nil }
        var s = url.absoluteString
        if s.contains("weread.qq.com"), let range = s.range(of: "s_") {
            s.replaceSubrange(range, with: "t9_")
        }
        return URL(string: s)
    }

    /// 人数缩写：12345 → 1.2万
    var readersText: String? {
        guard let readersCount else { return nil }
        if readersCount >= 10_000 {
            let v = Double(readersCount) / 10_000
            return String(format: "%.1f万", v) + "人在读"
        }
        return "\(readersCount)人在读"
    }
}
