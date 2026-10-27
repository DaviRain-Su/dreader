import Foundation
import SwiftUI

/// 把全套划线与书签 JSON 化，自动镜像到 iCloud Drive 的「DReader」文件夹。
/// 用户在 Finder / iPhone「文件」App / 任何其他设备上都能直接取到最新快照与历史版本。
///
/// LibraryDatabase 的每个写事务（划线/书签增删改、备份导入、旧数据迁移）完成后
/// 都会调用 `scheduleBackup()`，4 秒去抖后合并成一次快照写入，避免高频拖慢 iCloud。
final class ICloudBackupService: @unchecked Sendable {
    static let shared = ICloudBackupService()

    /// iCloud Drive 落地目录（应用未启用沙盒，直接文件路径即可读写）
    private let iCloudRoot: URL
    private var historyDir: URL { iCloudRoot.appendingPathComponent("历史快照", isDirectory: true) }
    private var latestURL: URL { iCloudRoot.appendingPathComponent("划线与思考-latest.json") }

    private let work = DispatchQueue(label: "com.dreader.icloudbackup")
    private var debounce: DispatchWorkItem?
    private var lastFailureLog: Date?
    /// UI 展示用：最近一次成功备份时间
    private(set) var lastBackupAt: Date?

    /// 历史快照保留份数（超过后从最旧开始清理）
    private static let historyKeep = 20
    /// 去抖秒数
    private static let debounceSeconds: TimeInterval = 4

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        iCloudRoot = home.appendingPathComponent("Library/Mobile Documents/iCloud~com~apple~CloudDocs/DReader", isDirectory: true)
    }

    /// 任何库写入之后调用（线程安全，自动去抖合并）
    func scheduleBackup() {
        work.async { [weak self] in
            guard let self else { return }
            let item = DispatchWorkItem { [weak self] in self?.performBackup() }
            self.debounce?.cancel()
            self.debounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceSeconds, execute: item)
        }
    }

    /// 立即写一次快照（用于手动触发 / 导入完成后）
    func backupNow() {
        debounce?.cancel()
        DispatchQueue.main.async { [weak self] in self?.performBackup() }
    }

    private func performBackup() {
        do {
            let fm = FileManager.default
            // iCloud Drive 目录不存在（未登录）也能安全退出——绝不打扰用户
            if !fm.fileExists(atPath: iCloudRoot.path) {
                try fm.createDirectory(at: iCloudRoot, withIntermediateDirectories: true)
            }
            try fm.createDirectory(at: historyDir, withIntermediateDirectories: true)

            let data = try LibraryDatabase.shared.exportBackup()

            try data.write(to: latestURL, options: .atomic)
            let stamp = Self.backupStamp(for: Date())
            try data.write(to: historyDir.appendingPathComponent("划线与思考-\(stamp).json"), options: .atomic)

            // 只保留最近 N 份历史
            let snapshots = (try? fm.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: [.creationDateKey]))?
                .filter { $0.pathExtension.lowercased() == "json" } ?? []
            if snapshots.count > Self.historyKeep {
                let ordered = snapshots.sorted(by: { (a: URL, b: URL) in a.lastPathComponent < b.lastPathComponent })
                for excess in ordered.prefix(snapshots.count - Self.historyKeep) {
                    try? fm.removeItem(at: excess)
                }
            }

            lastBackupAt = Date()
        } catch {
            // iCloud 未开启 / 目录只读等情况：低频记录一次即可，别刷屏
            if lastFailureLog == nil || Date().timeIntervalSince(lastFailureLog!) > 60 {
                NSLog("DReader iCloud 备份失败（不影响本地数据）：\(error.localizedDescription)")
                lastFailureLog = Date()
            }
        }
    }

    /// 「2026-10-27 1530」格式的时间戳文件名段
    private static func backupStamp(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HHmm"
        return fmt.string(from: date).replacingOccurrences(of: " ", with: " ")
    }
}
