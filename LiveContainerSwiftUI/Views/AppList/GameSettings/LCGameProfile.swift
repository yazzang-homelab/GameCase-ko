//
//  LCGameProfile.swift
//  LiveContainerSwiftUI
//
//  每游戏设置页的数据真源有且仅有一处：客体包内自带的 dm/launcher.json（引擎
//  settings.py 在打包时按该游戏的档案生成，键名 / 选项 / 默认值 / 分组 / 标签都以
//  它为准），与游戏自带启动器逐项一致；不做任何外部增补或内置兜底表，解析不到
//  时返回 nil，设置页只给通用提示。LCKnownGame 只服务按键布局入口（容器功能）。
//  偏好读写走 LCGamePrefs：目标游戏默认容器的 Library/Preferences/<bundleId>.plist，
//  与游戏内启动器（LauncherSettings.swift）共用同一份：键 "launcher.<ENV>"、字符串值，
//  等于默认值的选择按引擎惯例不落键（删键），其余键（DmPadCustom 等）原样保留。
//

import Foundation

// MARK: - 已知游戏（有按键布局档案的两款）

enum LCKnownGame: String {
    case silksong = "010013C00E930000"
    case hades2 = "0100A00019DE0000"

    /// bundle id 形如 org.nxnative.<小写标题 ID>，取末段大写后匹配
    static func from(bundleIdentifier: String) -> LCKnownGame? {
        guard let last = bundleIdentifier.split(separator: ".").last else {
            return nil
        }
        return LCKnownGame(rawValue: last.uppercased())
    }

    var shortName: String {
        switch self {
        case .silksong: return "lc.gameSettings.gameSilksong".loc
        case .hades2: return "lc.gameSettings.gameHades2".loc
        }
    }

    /// 按键布局在偏好里的存储键（与 NX2Apple 壳设置页编辑器、游戏内编辑器同一份）
    var padStoreKey: String {
        switch self {
        case .silksong: return "DmPadCustom"
        case .hades2: return "DmPadCustomHades"
        }
    }

    var skinEnv: String {
        switch self {
        case .silksong: return "DM_SILK_SKIN"
        case .hades2: return "DM_HADES_SKIN"
        }
    }

    var padLayoutGame: LCPadLayoutGame {
        switch self {
        case .silksong: return .silksong
        case .hades2: return .hades2
        }
    }
}

// MARK: - 一条启动器设置（launcher.json 的一行）

struct LCLauncherSetting: Identifiable {
    var env: String
    var kind: String // choice / toggle / range
    var section: String // Game / Controls / Performance
    var label: String
    var note: String = ""
    var defaultValue: String
    var options: [(value: String, label: String)] = []
    var minValue: Double = 0
    var maxValue: Double = 0
    var stepValue: Double = 0
    var onValue: String = "1"
    var offValue: String = "0"
    var needs: String? = nil // "DM_RUMBLE=1"：仅当该变量取该值时才显示

    var id: String { env }

    func accepts(_ v: String) -> Bool {
        switch kind {
        case "choice":
            return options.contains { $0.value == v }
        case "toggle":
            return v == onValue || v == offValue
        case "range":
            guard let n = Double(v), n.isFinite else { return false }
            return n >= minValue && n <= maxValue
        default:
            return true
        }
    }

    /// 与引擎 LauncherSetting.isDefault 一致：range 按数值比，其余按字符串比
    func isDefault(_ v: String) -> Bool {
        if kind == "range" {
            guard let a = Double(v), let b = Double(defaultValue) else { return false }
            return abs(a - b) < 1e-6
        }
        return v == defaultValue
    }

    func optionLabel(for value: String) -> String {
        options.first { $0.value == value }?.label ?? value
    }

    /// range 的显示 / 落盘格式：最多两位小数，去掉尾随的 0（1.0 写 "1.0"，0.25 写 "0.25"）
    static func formatRange(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        if s.hasSuffix("0") { s.removeLast() }
        return s
    }
}

// MARK: - 档案加载

enum LCGameProfile {
    /// 设置页的设置清单：只解析客体自带的 dm/launcher.json 原文，解析不到返回 nil
    static func loadSettings(app: LCAppModel) -> [LCLauncherSetting]? {
        if let bundlePath = app.appInfo.bundlePath() {
            let url = URL(fileURLWithPath: bundlePath).appendingPathComponent("dm/launcher.json")
            if let data = try? Data(contentsOf: url), let parsed = parseLauncherJSON(data) {
                return parsed
            }
        }
        return nil
    }

    static func parseLauncherJSON(_ data: Data) -> [LCLauncherSetting]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["settings"] as? [[String: Any]] else {
            return nil
        }
        var out: [LCLauncherSetting] = []
        for row in rows {
            guard let env = row["env"] as? String, let kind = row["kind"] as? String else { continue }
            var s = LCLauncherSetting(
                env: env,
                kind: kind,
                section: (row["section"] as? String) ?? "Game",
                label: (row["label"] as? String) ?? env,
                note: (row["note"] as? String) ?? "",
                defaultValue: (row["default"] as? String) ?? ""
            )
            if let opts = row["options"] as? [[Any]] {
                s.options = opts.compactMap { pair in
                    guard pair.count >= 2, let v = pair[0] as? String, let l = pair[1] as? String else { return nil }
                    return (value: v, label: l)
                }
            }
            if let v = row["min"] as? NSNumber { s.minValue = v.doubleValue }
            if let v = row["max"] as? NSNumber { s.maxValue = v.doubleValue }
            if let v = row["step"] as? NSNumber { s.stepValue = v.doubleValue }
            if let v = row["on"] as? String { s.onValue = v }
            if let v = row["off"] as? String { s.offValue = v }
            if let v = row["needs"] as? String { s.needs = v }
            out.append(s)
        }
        return out.isEmpty ? nil : out
    }

    /// 被 env 文件固定的变量（包内 dm/env.txt、容器 Documents/env.txt）：启动器里只显示不改，这里同样锁定
    static func envLockedValues(app: LCAppModel, container: LCContainer?) -> [String: String] {
        var out: [String: String] = [:]
        func absorb(_ url: URL?) {
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { continue }
                let parts = t.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    out[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                        String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if let bundlePath = app.appInfo.bundlePath() {
            absorb(URL(fileURLWithPath: bundlePath).appendingPathComponent("dm/env.txt"))
        }
        if let container {
            absorb(container.containerURL.appendingPathComponent("Documents/env.txt"))
        }
        return out
    }
}

// MARK: - 客体容器偏好 plist 的读写（保留原格式与其余键）

final class LCGamePrefs {
    let container: LCContainer
    let bundleIdentifier: String

    var prefsURL: URL {
        container.containerURL
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(bundleIdentifier).plist")
    }

    private(set) var values: [String: Any] = [:]
    private var format: PropertyListSerialization.PropertyListFormat = .binary
    /// 文件存在但解析失败：保留旧值且禁止落盘，避免按残缺内容回写清掉客体全部偏好
    private var loadFailed = false

    init(container: LCContainer, bundleIdentifier: String) {
        self.container = container
        self.bundleIdentifier = bundleIdentifier
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: prefsURL) else {
            // 文件还不存在（客体没跑过）：空档案是正常起点
            values = [:]
            format = .binary
            loadFailed = false
            return
        }
        var fmt: PropertyListSerialization.PropertyListFormat = .binary
        if let dict = (try? PropertyListSerialization.propertyList(from: data, format: &fmt)) as? [String: Any] {
            values = dict
            format = fmt
            loadFailed = false
        } else {
            loadFailed = true
        }
    }

    @discardableResult
    func save() -> Bool {
        guard !loadFailed else { return false }
        do {
            try FileManager.default.createDirectory(
                at: prefsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: values, format: format, options: 0)
            // 原地写（同一文件截断重写），不要 .atomic 的改名替换：客体启动器经
            // UserDefaults/CFPreferences 读这份 plist，偏好系统按文件跟踪域内容，
            // 换文件会让它继续按旧内容生效；而客体每次启动时 LauncherModel.apply()
            // 又会拿它读到的值回写整个域——库内改动就是这样被「改回去」的，
            // 读通写不通。原地写保证跟踪方看到的是同一文件的原地变更；写后再
            // 读回逐键校验，不一致就重写一次，落盘内容必须与内存一致才算成功。
            for _ in 0..<2 {
                if FileManager.default.fileExists(atPath: prefsURL.path) {
                    let handle = try FileHandle(forWritingTo: prefsURL)
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: data)
                    try handle.synchronize()
                    try? handle.close()
                } else {
                    try data.write(to: prefsURL)
                }
                if diskMatchesValues() { return true }
            }
            return false
        } catch {
            return false
        }
    }

    /// 落盘内容是否与内存中的 values 逐键一致（写路径自检）
    private func diskMatchesValues() -> Bool {
        guard let data = try? Data(contentsOf: prefsURL) else { return false }
        var fmt: PropertyListSerialization.PropertyListFormat = .binary
        guard let parsed = (try? PropertyListSerialization.propertyList(from: data, format: &fmt)) as? [String: Any] else {
            return false
        }
        return NSDictionary(dictionary: parsed) == NSDictionary(dictionary: values)
    }

    /// 启动器已保存的选择（字符串；数字按字符串读，与 LauncherSettings 的读法一致）
    func launcherValue(_ env: String) -> String? {
        guard let raw = values["launcher.\(env)"] else { return nil }
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    /// 写一条启动器选择：等于档案默认值时按引擎惯例删键，其余时候写字符串
    func setLauncherValue(_ setting: LCLauncherSetting, to value: String) {
        if setting.isDefault(value) {
            values.removeValue(forKey: "launcher.\(setting.env)")
        } else {
            values["launcher.\(setting.env)"] = value
        }
        save()
    }

    /// 写 / 删一个任意键（云存档把书签 Data 同步进客体的
    /// cloudSavesBookmark 键用）：值与现存一致时不落盘，避免每次
    /// 启动维护都重写整份 plist。
    func setRawValue(_ value: Any?, forKey key: String) {
        let old = values[key]
        let unchanged: Bool
        switch (old, value) {
        case (nil, nil):
            unchanged = true
        case let (o as Data, v as Data):
            unchanged = o == v
        case let (o as NSObject, v as NSObject):
            unchanged = o == v
        default:
            unchanged = false
        }
        if unchanged { return }
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        save()
    }

    /// 恢复默认：清掉档案内全部变量的已保存选择
    func resetLauncherValues(_ settings: [LCLauncherSetting]) {
        for s in settings {
            values.removeValue(forKey: "launcher.\(s.env)")
        }
        save()
    }

    func hasLauncherValues(_ settings: [LCLauncherSetting]) -> Bool {
        settings.contains { values["launcher.\($0.env)"] != nil }
    }

    // MARK: 按键布局（DmPadCustom / DmPadCustomHades，与启动器键同文件共存）

    func padCustomDictionary(_ storeKey: String) -> [String: Any] {
        values[storeKey] as? [String: Any] ?? [:]
    }

    func setPadCustomDictionary(_ storeKey: String, _ dict: [String: [String: Double]]) {
        if dict.isEmpty {
            values.removeValue(forKey: storeKey)
        } else {
            values[storeKey] = dict
        }
        save()
    }
}
