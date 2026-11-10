//
//  LCPlayStats.swift
//  LiveContainerSwiftUI
//
//  游玩时长统计（Phase 18）：纯容器侧计时，不依赖客体配合——开始戳由库侧
//  启动漏斗打、存活心跳与回库结清由客体进程内的快捷栏代码打（LCBootstrap.m
//  按同一文件格式直写）、闪退/被划掉没结清的局由库主页出现时按心跳补结。
//
//  存储：宿主 Documents/LCPlayStats.plist（LCPath.docPath 口径），结构：
//    {
//      "apps": { <bundleId>: {
//          "totalSeconds": <num>, "lastSessionSeconds": <num>,
//          "lastPlayedAt": <date>, "sessionCount": <num> } },
//      "openSession": { "bundleId": <str>, "start": <date>,
//                       "lastHeartbeat": <date, 可缺> }   // 至多一个：串行单开
//    }
//  本文件随 App 宿主存储，删 App 即清零，属正常语义。
//

import Foundation

enum LCPlayStats {
    struct Entry {
        var totalSeconds: TimeInterval = 0
        var lastSessionSeconds: TimeInterval = 0
        var lastPlayedAt: Date?
        var sessionCount: Int = 0
    }

    /// 单局时长钳制上限：防系统时钟跳变把一局算成几天
    private static let maxSessionDuration: TimeInterval = 24 * 3600

    static var fileURL: URL {
        LCPath.docPath.appendingPathComponent("LCPlayStats.plist")
    }

    // MARK: - 读写（整表加载/原子落盘；写入方都是串行单开语境，无并发局）

    private static func loadRoot() -> NSMutableDictionary {
        if let dict = NSDictionary(contentsOf: fileURL) as? [String: Any] {
            return NSMutableDictionary(dictionary: dict)
        }
        return NSMutableDictionary()
    }

    private static func saveRoot(_ root: NSDictionary) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        (root as NSDictionary).write(to: fileURL, atomically: true)
    }

    private static func appsDict(in root: NSMutableDictionary) -> NSMutableDictionary {
        if let apps = root["apps"] as? [String: Any] {
            let mutable = NSMutableDictionary(dictionary: apps)
            root["apps"] = mutable
            return mutable
        }
        let mutable = NSMutableDictionary()
        root["apps"] = mutable
        return mutable
    }

    private static func entryDict(in apps: NSMutableDictionary, for bundleId: String) -> NSMutableDictionary {
        if let entry = apps[bundleId] as? [String: Any] {
            let mutable = NSMutableDictionary(dictionary: entry)
            apps[bundleId] = mutable
            return mutable
        }
        let mutable = NSMutableDictionary()
        apps[bundleId] = mutable
        return mutable
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    // MARK: - 结清一局（回库结清与主页补结共用同一套入账规则）

    /// 把时长入账到 apps[bundleId] 并清掉 openSession。duration<=0 只关局不入账
    /// （刚启动就闪退的局不产生「上次 0 分钟」噪声）。
    private static func closeOpenSession(in root: NSMutableDictionary, duration: TimeInterval, end: Date) {
        guard let open = root["openSession"] as? [String: Any],
              let bundleId = open["bundleId"] as? String else {
            root.removeObject(forKey: "openSession")
            return
        }
        root.removeObject(forKey: "openSession")
        guard duration > 0 else { return }
        let entry = entryDict(in: appsDict(in: root), for: bundleId)
        entry["totalSeconds"] = number(entry["totalSeconds"]) + duration
        entry["lastSessionSeconds"] = duration
        entry["lastPlayedAt"] = end
        entry["sessionCount"] = Int(number(entry["sessionCount"])) + 1
    }

    static func clampedDuration(from start: Date, to end: Date) -> TimeInterval {
        min(max(end.timeIntervalSince(start), 0), maxSessionDuration)
    }

    // MARK: - 库侧：启动打戳

    /// runApp 漏斗在真正派发启动前调用。残留的未结清局先按心跳规则补结，
    /// 再开新局（openSession 只写 start，心跳由客体侧首拍补上——补结时
    /// 「无心跳」与「有心跳」的区分就靠这个键在不在）。
    static func beginSession(bundleId: String, at now: Date = Date()) {
        let root = loadRoot()
        if root["openSession"] != nil {
            settleOpenSession(in: root)
        }
        root["openSession"] = [
            "bundleId": bundleId,
            "start": now,
        ] as [String: Any]
        saveRoot(root)
    }

    // MARK: - 库侧：主页出现时补结

    /// 按 openSession 现状结清：有心跳 → 按 lastHeartbeat 结清累加（误差在
    /// 一个心跳周期内）；无心跳 → 客体根本没跑起来，按 0 时长关闭。
    private static func settleOpenSession(in root: NSMutableDictionary) {
        guard let open = root["openSession"] as? [String: Any],
              let start = open["start"] as? Date else {
            root.removeObject(forKey: "openSession")
            return
        }
        if let heartbeat = open["lastHeartbeat"] as? Date {
            closeOpenSession(in: root, duration: clampedDuration(from: start, to: heartbeat), end: heartbeat)
        } else {
            closeOpenSession(in: root, duration: 0, end: start)
        }
    }

    static func reconcileOpenSession() {
        let root = loadRoot()
        guard root["openSession"] != nil else { return }
        settleOpenSession(in: root)
        saveRoot(root)
    }

    // MARK: - 读给 UI

    static func allEntries() -> [String: Entry] {
        let root = loadRoot()
        guard let apps = root["apps"] as? [String: Any] else { return [:] }
        var out: [String: Entry] = [:]
        for (bundleId, value) in apps {
            guard let dict = value as? [String: Any] else { continue }
            out[bundleId] = Entry(
                totalSeconds: number(dict["totalSeconds"]),
                lastSessionSeconds: number(dict["lastSessionSeconds"]),
                lastPlayedAt: dict["lastPlayedAt"] as? Date,
                sessionCount: Int(number(dict["sessionCount"])))
        }
        return out
    }

    // MARK: - 文案

    /// <60 分钟「X 分钟」、否则「X 小时 Y 分钟」（分钟按四舍五入取整，>0 至少 1 分钟）
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int((seconds + 30) / 60))
        if totalMinutes < 60 {
            return "lc.playStats.minutes %lld".localizeWithFormat(totalMinutes)
        }
        return "lc.playStats.hoursMinutes %lld %lld".localizeWithFormat(totalMinutes / 60, totalMinutes % 60)
    }

    /// 「最近游玩」行时长文案：累计 +（≥2 局且有上次记录时）上次。无记录返回 nil 不显示。
    static func summaryText(for entry: Entry?) -> String? {
        guard let entry, entry.totalSeconds > 0 else { return nil }
        var text = "lc.playStats.total %@".localizeWithFormat(formatDuration(entry.totalSeconds))
        if entry.sessionCount >= 2, entry.lastSessionSeconds > 0 {
            text += " · " + "lc.playStats.last %@".localizeWithFormat(formatDuration(entry.lastSessionSeconds))
        }
        return text
    }
}
